#!/usr/bin/env bash
# openclaw heal.sh — auto-fix common gateway issues
# Run: bash heal.sh
# Fixes: gateway down, auth mode, exec approval (both layers), auto-disabled crons, stuck sessions

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

FIXED=()
BROKEN=()
MANUAL=()
RESTARTED=false
STATE_FILE="$OPENCLAW_DIR/watchdog-state.json"

# ── Preflight: check required tools ──────────────────────────────────────────
# openclaw is required: many steps read/set config via `openclaw config`,
# manage approvals, enable crons, and run `openclaw doctor`. Without the host
# CLI wrapper (install-cli-wrapper.sh) installed on Docker Compose deployments,
# those calls silently fail and the script reports misleading "fixed/broken".
require_tools python3 curl openssl openclaw || exit 1
mkdir -p "$(dirname "$STATE_FILE")"

# Override log helpers to also track in arrays
log_fixed()  { echo -e "${GRN}[FIXED]${RST}  $1"; FIXED+=("$1"); }
log_broken() { echo -e "${RED}[BROKEN]${RST} $1"; BROKEN+=("$1"); }
log_manual() { echo -e "${YLW}[MANUAL]${RST} $1"; MANUAL+=("$1"); }

# Gateway lifecycle via Docker Compose (lib.sh provides gateway_running()).
gateway_do_start() {
  _docker_compose_up 2>/dev/null
}

gateway_do_restart() {
  _docker_compose_restart 2>/dev/null
}

echo ""
echo -e "${BLD}OpenClaw Self-Heal${RST}"
echo "────────────────────────────────"

# ── Step 0: Version check ─────────────────────────────────────────────────────
echo ""
echo -e "${BLD}[0] Version check${RST}"
CURRENT_VERSION="$(get_openclaw_version)"
log_info "Running: $CURRENT_VERSION"

# Minimum safe version: 2026.2.12
MIN_MAJOR=2026; MIN_MINOR=2; MIN_PATCH=12
if [[ "$CURRENT_VERSION" != "unknown" ]]; then
  V="${CURRENT_VERSION#v}"
  V_MAJOR=$(echo "$V" | cut -d. -f1)
  V_MINOR=$(echo "$V" | cut -d. -f2)
  V_PATCH=$(echo "$V" | cut -d. -f3)
  if [[ "$V_MAJOR" -lt "$MIN_MAJOR" ]] || \
     { [[ "$V_MAJOR" -eq "$MIN_MAJOR" ]] && [[ "$V_MINOR" -lt "$MIN_MINOR" ]]; } || \
     { [[ "$V_MAJOR" -eq "$MIN_MAJOR" ]] && [[ "$V_MINOR" -eq "$MIN_MINOR" ]] && [[ "$V_PATCH" -lt "$MIN_PATCH" ]]; }; then
    log_manual "Version $CURRENT_VERSION is below v2026.2.12 (has critical CVEs). Upgrade: curl -fsSL https://openclaw.ai/install.sh | bash"
  else
    log_info "Version OK"
  fi
else
  log_info "Could not determine version"
fi

# Detect version change since last run (updates can introduce breaking config changes)
VERSION_STATE="$(
  python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except:
    d = {}
print(d.get('current_version') or d.get('last_version', ''))
print(d.get('previous_version') or d.get('version_changed_from', ''))
print('1' if d.get('version_change_pending') else '0')
" "$STATE_FILE" 2>/dev/null || printf '\n\n0\n'
)"

STATE_CURRENT_VERSION="$(printf '%s\n' "$VERSION_STATE" | sed -n '1p')"
PREVIOUS_VERSION="$(printf '%s\n' "$VERSION_STATE" | sed -n '2p')"
VERSION_CHANGE_PENDING="$(printf '%s\n' "$VERSION_STATE" | sed -n '3p')"
VERSION_CHANGE_PENDING="${VERSION_CHANGE_PENDING:-0}"

if [[ "$VERSION_CHANGE_PENDING" == "1" ]] && [[ -n "$PREVIOUS_VERSION" ]] && [[ -n "$STATE_CURRENT_VERSION" ]]; then
  echo -e "${YLW}[NOTICE]${RST} Version changed: $PREVIOUS_VERSION → $STATE_CURRENT_VERSION"
  echo -e "         Updates can introduce new config requirements (e.g. exec policy layers)."
  echo -e "         If agents are broken, check exec approvals Layer 2 and review:"
  echo -e "         https://docs.openclaw.ai/changelog"
elif [[ -n "$STATE_CURRENT_VERSION" ]] && [[ -n "$CURRENT_VERSION" ]] && [[ "$CURRENT_VERSION" != "unknown" ]] && [[ "$STATE_CURRENT_VERSION" != "$CURRENT_VERSION" ]]; then
  echo -e "${YLW}[NOTICE]${RST} Version changed: $STATE_CURRENT_VERSION → $CURRENT_VERSION"
  echo -e "         Updates can introduce new config requirements (e.g. exec policy layers)."
  echo -e "         If agents are broken, check exec approvals Layer 2 and review:"
  echo -e "         https://docs.openclaw.ai/changelog"
fi

# Initialize current version in state if watchdog has not written it yet
python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except:
    d = {}
current_version = sys.argv[2]
if current_version and current_version != 'unknown':
    d.setdefault('current_version', current_version)
    d.setdefault('last_version', current_version)
with open(sys.argv[1], 'w') as out:
    json.dump(d, out)
" "$STATE_FILE" "$CURRENT_VERSION" 2>/dev/null || true

# ── Step 1: Gateway process ───────────────────────────────────────────────────
echo ""
echo -e "${BLD}[1] Gateway process${RST}"
if ! gateway_running; then
  log_info "Gateway not running — attempting start"
  if gateway_do_start; then
    sleep 3
    if gateway_running; then
      log_info "Container started — waiting for healthcheck (up to 30s)"
      _HEALTHY=false
      for _ in $(seq 1 10); do
        if gateway_healthy; then _HEALTHY=true; break; fi
        sleep 3
      done
      if [[ "$_HEALTHY" == "true" ]]; then
        log_fixed "Gateway started and healthy"
        RESTARTED=true
      else
        log_manual "Gateway container running but health check not yet passing — check: docker logs ${OPENCLAW_GATEWAY_CONTAINER}"
      fi
    else
      log_broken "Gateway failed to start — try: docker compose --project-directory ${OPENCLAW_STACK_DIR} up -d openclaw-gateway"
    fi
  else
    log_broken "Gateway start command failed"
  fi
else
  log_info "Gateway running"
fi

# ── Step 2: Auth mode ─────────────────────────────────────────────────────────
echo ""
echo -e "${BLD}[2] Auth config${RST}"
AUTH_MODE=$(openclaw config get gateway.auth.mode 2>/dev/null || echo "unknown")
if [[ "$AUTH_MODE" == "none" ]]; then
  log_info "auth.mode=none detected (removed in v2026.1.29) — fixing"
  openclaw config set gateway.auth.mode token
  NEW_TOKEN=$(openssl rand -hex 32)
  openclaw config set gateway.auth.token "$NEW_TOKEN"
  log_fixed "Auth mode set to token with new random token"
  RESTARTED=false  # will restart at end
else
  log_info "Auth mode: $AUTH_MODE"
fi

# Check for recent 401s in logs
if [[ -f ~/.openclaw/logs/gateway.err.log ]]; then
  RECENT_401=$(tail -100 ~/.openclaw/logs/gateway.err.log 2>/dev/null | grep -c "401\|auth profile failure state\|cooldown" || true)
  if [[ "$RECENT_401" -gt 0 ]]; then
    log_manual "Auth errors detected in logs ($RECENT_401 occurrences). Check API key: openclaw models auth setup-token --provider anthropic"
  fi
fi

# ── Step 3: Exec approvals ────────────────────────────────────────────────────
echo ""
echo -e "${BLD}[3] Exec approvals${RST}"
APPROVALS_FILE=~/.openclaw/exec-approvals.json
if [[ -f "$APPROVALS_FILE" ]]; then
  # Find agents with empty allowlists
  EMPTY_AGENTS=$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
agents_section = data.get('agents', data)
empty = []
for agent, cfg in agents_section.items():
    if agent == '*':
        continue
    allowlist = cfg.get('allowlist', None)
    if allowlist is not None and len(allowlist) == 0:
        empty.append(agent)
print('\n'.join(empty))
" "$APPROVALS_FILE" 2>/dev/null || echo "")

  if [[ -n "$EMPTY_AGENTS" ]]; then
    while IFS= read -r agent; do
      [[ -z "$agent" ]] && continue
      log_info "Empty allowlist for agent: $agent — adding wildcard"
      openclaw approvals allowlist add --agent "$agent" "*" 2>/dev/null && \
        log_fixed "Exec approval wildcard added for: $agent" || \
        log_broken "Failed to add exec approval for: $agent"
    done <<< "$EMPTY_AGENTS"
    RESTARTED=false  # will restart at end
  else
    log_info "Layer 1 (allowlists) OK"
  fi

  # Layer 2: exec policy settings in exec-approvals.json defaults block
  # Updates sometimes reset or introduce new defaults for these — check both files
  log_info "Checking Layer 2: exec policy settings"
  DEFAULTS_OK=$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
defaults = data.get('defaults', {})
security = defaults.get('security', '')
ask = defaults.get('ask', '')
ask_fallback = defaults.get('askFallback', '')
if security == 'full' and ask == 'off' and ask_fallback == 'full':
    print('ok')
else:
    print(f'security={security!r} ask={ask!r} askFallback={ask_fallback!r}')
" "$APPROVALS_FILE" 2>/dev/null || echo "error")

  if [[ "$DEFAULTS_OK" != "ok" ]]; then
    log_info "exec-approvals.json defaults need fixing ($DEFAULTS_OK) — patching"
    python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
if 'defaults' not in data:
    data['defaults'] = {}
data['defaults']['security'] = 'full'
data['defaults']['ask'] = 'off'
data['defaults']['askFallback'] = 'full'
with open(sys.argv[1], 'w') as f:
    json.dump(data, f, indent=2)
print('patched')
" "$APPROVALS_FILE" 2>/dev/null && log_fixed "exec-approvals.json defaults: security=full, ask=off, askFallback=full" || \
      log_broken "Failed to patch exec-approvals.json defaults"
    RESTARTED=false
  else
    log_info "Layer 2 (exec-approvals.json defaults) OK"
  fi
else
  log_info "No exec-approvals.json found — skipping"
fi

# Layer 2b: tools.exec settings in openclaw.json (removed in v2026.5.0)
# In v2026.5+, exec policy is managed entirely via exec-approvals.json.
if version_below "$CURRENT_VERSION" "v2026.5.0"; then
  EXEC_SECURITY=$(openclaw config get tools.exec.security 2>/dev/null || echo "")
  EXEC_STRICT=$(openclaw config get tools.exec.strictInlineEval 2>/dev/null || echo "")

  LAYER2B_OK=true
  if [[ "$EXEC_SECURITY" != "full" ]]; then
    log_info "tools.exec.security=$EXEC_SECURITY — setting to full"
    openclaw config set tools.exec.security full 2>/dev/null && \
      log_fixed "tools.exec.security set to full" || \
      log_broken "Failed to set tools.exec.security"
    LAYER2B_OK=false
  fi
  if [[ "$EXEC_STRICT" != "false" ]]; then
    log_info "tools.exec.strictInlineEval=true — setting to false"
    openclaw config set tools.exec.strictInlineEval false 2>/dev/null && \
      log_fixed "tools.exec.strictInlineEval set to false" || \
      log_broken "Failed to set tools.exec.strictInlineEval"
    LAYER2B_OK=false
  fi
  [[ "$LAYER2B_OK" == "true" ]] && log_info "Layer 2b (openclaw.json exec settings) OK"
else
  log_info "Layer 2b: tools.exec.* removed in v2026.5+ — exec policy via exec-approvals.json"
fi

# ── Step 4: Cron jobs ─────────────────────────────────────────────────────────
echo ""
echo -e "${BLD}[4] Cron jobs${RST}"

_reenable_disabled_crons() {
  local disabled_jobs="$1"
  if [[ -n "$disabled_jobs" ]]; then
    while IFS= read -r job_id; do
      [[ -z "$job_id" ]] && continue
      log_info "Auto-disabled cron: $job_id — re-enabling"
      openclaw cron enable "$job_id" 2>/dev/null && \
        log_fixed "Cron re-enabled: $job_id" || \
        log_broken "Failed to re-enable cron: $job_id"
    done <<< "$disabled_jobs"
  fi
}

if version_below "$CURRENT_VERSION" "v2026.6.1"; then
  # Legacy: crons stored in jobs.json (pre-v2026.6.1)
  CRON_FILE="$OPENCLAW_DIR/cron/jobs.json"
  if [[ -f "$CRON_FILE" ]]; then
    DISABLED_JOBS=$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
jobs = data if isinstance(data, list) else data.get('jobs', [])
disabled = [j.get('id', j.get('name', 'unknown')) for j in jobs if not j.get('enabled', True) and j.get('consecutiveErrors', 0) > 0]
print('\n'.join(disabled))
" "$CRON_FILE" 2>/dev/null || echo "")
    _reenable_disabled_crons "$DISABLED_JOBS"
    [[ -z "$DISABLED_JOBS" ]] && log_info "Cron jobs OK"
  else
    log_info "No cron jobs file found — skipping"
  fi
else
  # v2026.6.1+: jobs.json removed — query SQLite via CLI
  DISABLED_JOBS=$(openclaw cron list --all --json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
jobs = d.get('jobs', d) if isinstance(d, dict) else d
disabled = [j.get('id', 'unknown') for j in jobs
            if not j.get('enabled', True)
            and int((j.get('state') or {}).get('consecutiveErrors', 0)) > 0]
print('\n'.join(disabled))
" 2>/dev/null || echo "")
  _reenable_disabled_crons "$DISABLED_JOBS"
  [[ -z "$DISABLED_JOBS" ]] && log_info "Cron jobs OK (SQLite)"
fi

# ── Step 5: Stuck sessions ────────────────────────────────────────────────────
echo ""
echo -e "${BLD}[5] Agent sessions${RST}"
AGENTS_DIR=~/.openclaw/agents
if [[ -d "$AGENTS_DIR" ]]; then
  STUCK_COUNT=0
  for agent_dir in "$AGENTS_DIR"/*/; do
    agent=$(basename "$agent_dir")
    sessions_dir="$agent_dir/sessions"
    [[ -d "$sessions_dir" ]] || continue

    # Check for session files >10MB — archive them (don't delete, preserve history)
    while IFS= read -r large_file; do
      [[ -z "$large_file" ]] && continue
      SIZE=$(du -sh "$large_file" 2>/dev/null | cut -f1)
      log_info "Large session file ($SIZE): $(basename "$large_file") — archiving"
      mv "$large_file" "${large_file}.archived" 2>/dev/null && \
        log_fixed "Archived large session for $agent: $(basename "$large_file")" || \
        log_broken "Could not archive: $large_file"
      STUCK_COUNT=$((STUCK_COUNT + 1))
    done < <(find "$sessions_dir" -name "*.jsonl" -size +10M 2>/dev/null)

    # Check for rapid-fire loop (same content 10+ times).
    # Session files are JSONL (one record per line) — json.load on the whole
    # file always raises and silently returns no match. Parse line-by-line and
    # compare assistant text content from the last 20 message records.
    while IFS= read -r -d '' f; do
      [[ -f "$f" ]] || continue
      LOOP=$(python3 -c "
import json, sys
from collections import Counter
try:
    records = []
    with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except Exception:
                continue
    contents = []
    for record in records:
        if record.get('type') != 'message':
            continue
        message = record.get('message') or {}
        content = message.get('content')
        if isinstance(content, list):
            parts = [item.get('text', '') for item in content
                     if isinstance(item, dict) and item.get('type') == 'text']
            text = '\n'.join(p for p in parts if p)
        elif isinstance(content, str):
            text = content
        else:
            text = ''
        text = text.strip()
        if text:
            contents.append(text)
    contents = contents[-20:]
    if len(contents) >= 10:
        top = Counter(contents).most_common(1)
        if top and top[0][1] >= 10:
            print('loop')
except Exception:
    pass
" "$f" 2>/dev/null || echo "")
      if [[ "$LOOP" == "loop" ]]; then
        log_info "Rapid-fire loop detected for agent $agent — resetting session pointer"
        # Reset sessionId and sessionFile in sessions.json
        SESSIONS_JSON="$agent_dir/sessions.json"
        if [[ -f "$SESSIONS_JSON" ]]; then
          python3 -c "
import json, os, sys
data = json.load(open(sys.argv[1]))
target = os.path.basename(sys.argv[2])
for k, v in data.items():
    if isinstance(v, dict) and v.get('sessionFile', '').endswith(target):
        v['sessionId'] = None
        v['sessionFile'] = None
with open(sys.argv[1], 'w') as out:
    json.dump(data, out, indent=2)
print('reset')
" "$SESSIONS_JSON" "$f" 2>/dev/null && log_fixed "Session pointer reset for: $agent" || log_broken "Failed to reset session for: $agent"
          STUCK_COUNT=$((STUCK_COUNT + 1))
        fi
      fi
    done < <(find "$sessions_dir" -maxdepth 1 -name "*.jsonl" ! -name "*.trajectory.jsonl" -print0 2>/dev/null)
  done
  if [[ "$STUCK_COUNT" -eq 0 ]]; then
    log_info "Sessions OK"
  fi
else
  log_info "No agents directory found — skipping"
fi

# ── Step 6: Restart if needed ─────────────────────────────────────────────────
echo ""
echo -e "${BLD}[6] Applying changes${RST}"
if [[ ${#FIXED[@]} -gt 0 ]] && [[ "$RESTARTED" == "false" ]]; then
  log_info "Restarting gateway to apply fixes"
  gateway_do_restart && \
    log_fixed "Gateway restarted" || \
    log_broken "Gateway restart failed — try: docker compose --project-directory ${OPENCLAW_STACK_DIR} restart openclaw-gateway"
  RESTARTED=true
elif [[ "$RESTARTED" == "true" ]]; then
  log_info "Gateway already restarted"
else
  log_info "No changes made — no restart needed"
fi

# ── Run openclaw doctor ───────────────────────────────────────────────────────
echo ""
echo -e "${BLD}[7] Config validation${RST}"
openclaw doctor || log_manual "openclaw doctor reported issues — review output above"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════"
echo -e "${BLD}Summary${RST}"
echo "════════════════════════════════"

if [[ ${#FIXED[@]} -gt 0 ]]; then
  echo -e "${GRN}Fixed (${#FIXED[@]}):${RST}"
  for item in "${FIXED[@]}"; do echo "  ✓ $item"; done
fi

if [[ ${#BROKEN[@]} -gt 0 ]]; then
  echo -e "${RED}Still broken (${#BROKEN[@]}):${RST}"
  for item in "${BROKEN[@]}"; do echo "  ✗ $item"; done
fi

if [[ ${#MANUAL[@]} -gt 0 ]]; then
  echo -e "${YLW}Needs manual action (${#MANUAL[@]}):${RST}"
  for item in "${MANUAL[@]}"; do echo "  ! $item"; done
fi

if [[ ${#FIXED[@]} -eq 0 ]] && [[ ${#BROKEN[@]} -eq 0 ]] && [[ ${#MANUAL[@]} -eq 0 ]]; then
  echo -e "${GRN}All checks passed — nothing to fix${RST}"
fi

# Surface actionable outcomes via journald/notify-send so headless servers get paged.
if [[ ${#BROKEN[@]} -gt 0 ]]; then
  send_notification "OpenClaw Heal" "${#BROKEN[@]} item(s) still broken — manual intervention needed"
  _discord_send error_alerts "$(_discord_ansi '1;31m' "Heal: ${#BROKEN[@]} item(s) still broken" 'manual intervention needed')"
elif [[ ${#FIXED[@]} -gt 0 ]]; then
  send_notification "OpenClaw Heal" "Self-healed ${#FIXED[@]} item(s)"
  _discord_send audit_trail "$(_discord_ansi '1;32m' "Heal: self-healed ${#FIXED[@]} item(s)")"
fi

echo ""

# ── Incident log (JSONL) ──────────────────────────────────────────────────────
# Appends a structured record per run so patterns surface over time.
# View with: cat ~/.openclaw/logs/heal-incidents.jsonl | python3 -m json.tool
INCIDENT_LOG="$OPENCLAW_DIR/logs/heal-incidents.jsonl"
mkdir -p "$(dirname "$INCIDENT_LOG")"

OUTCOME="clean"
[[ ${#FIXED[@]} -gt 0 ]] && OUTCOME="fixed"
[[ ${#BROKEN[@]} -gt 0 ]] && OUTCOME="broken"

FIXED_FILE="$(mktemp)"
BROKEN_FILE="$(mktemp)"
MANUAL_FILE="$(mktemp)"
trap 'rm -f "$FIXED_FILE" "$BROKEN_FILE" "$MANUAL_FILE"' EXIT

printf '%s\n' "${FIXED[@]+"${FIXED[@]}"}" >"$FIXED_FILE"
printf '%s\n' "${BROKEN[@]+"${BROKEN[@]}"}" >"$BROKEN_FILE"
printf '%s\n' "${MANUAL[@]+"${MANUAL[@]}"}" >"$MANUAL_FILE"

python3 -c "
import json, sys, time
def read_lines(path):
    with open(path) as f:
        return [line.rstrip('\n') for line in f if line.rstrip('\n')]
record = {
    'ts': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'outcome': sys.argv[1],
    'fixed': read_lines(sys.argv[3]),
    'broken': read_lines(sys.argv[4]),
    'manual': read_lines(sys.argv[5]),
}
with open(sys.argv[2], 'a') as f:
    f.write(json.dumps(record) + '\n')
" "$OUTCOME" "$INCIDENT_LOG" "$FIXED_FILE" "$BROKEN_FILE" "$MANUAL_FILE" 2>/dev/null || true
