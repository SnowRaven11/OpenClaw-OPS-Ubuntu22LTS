#!/usr/bin/env bash
set -euo pipefail
# openclaw watchdog.sh — runs every 5 minutes via systemd user timer
# Cron fallback: */5 * * * * bash /path/to/watchdog.sh
# Install with: bash watchdog-install.sh

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" && source "$LIB_DIR/lib.sh"
require_tools python3

LOG_DIR="${OPENCLAW_LOG_DIR:-$HOME/.openclaw/logs}"
LOG_FILE="$LOG_DIR/watchdog.log"
HEAL_SCRIPT="$(cd "$(dirname "$0")" && pwd)/heal.sh"
SESSION_MONITOR_SCRIPT="${OPENCLAW_SESSION_MONITOR_SCRIPT:-$(cd "$(dirname "$0")" && pwd)/session-monitor.sh}"
SESSION_MONITOR_STAMP="${OPENCLAW_SESSION_MONITOR_STAMP:-$HOME/.openclaw/session-monitor/watchdog.stamp}"
SESSION_MONITOR_THROTTLE=600
MAX_RESTART_ATTEMPTS=3
RESTART_ATTEMPT_WINDOW=900  # 15 minutes
HEALTH_FAILURE_WINDOW=600    # require repeated unhealthy probes within 10 minutes
REQUIRED_HEALTH_FAILURES=2
GATEWAY_WARMUP_GRACE=120     # do not restart a young gateway during startup
STATE_FILE="$OPENCLAW_DIR/watchdog-state.json"
RUN_LOCK_DIR="$OPENCLAW_DIR/watchdog.lock"

mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$STATE_FILE")"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $1" | tee -a "$LOG_FILE"; }

# Trim log to last 500 lines
if [[ -f "$LOG_FILE" ]]; then
  tail -500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

log "── Watchdog tick ────────────────────"

acquire_run_lock() {
  local now lock_mtime

  if mkdir "$RUN_LOCK_DIR" 2>/dev/null; then
    trap 'rmdir "$RUN_LOCK_DIR" 2>/dev/null || true' EXIT
    return 0
  fi

  now="$(epoch_now)"
  lock_mtime="$(file_mtime "$RUN_LOCK_DIR" || true)"
  lock_mtime="${lock_mtime:-0}"

  if (( now - lock_mtime > 900 )); then
    log "Removing stale watchdog lock"
    rmdir "$RUN_LOCK_DIR" 2>/dev/null || true
    if mkdir "$RUN_LOCK_DIR" 2>/dev/null; then
      trap 'rmdir "$RUN_LOCK_DIR" 2>/dev/null || true' EXIT
      return 0
    fi
  fi

  log "Another watchdog run is active; skipping"
  exit 0
}

acquire_run_lock

# Track version changes — write current version to state so heal.sh and check-update.sh
# can detect when an update occurred
CURRENT_VERSION="$(get_openclaw_version)"
if [[ -n "$CURRENT_VERSION" ]]; then
  python3 -c "
import sys, json
from time import gmtime, strftime

state_file = sys.argv[1]
current_version = sys.argv[2]
try:
    d = json.load(open(state_file))
except:
    d = {}
prev = d.get('current_version') or d.get('last_version', '')
d['current_version'] = current_version
d['last_version'] = current_version
if prev and prev != current_version:
    d['previous_version'] = prev
    d['version_changed_at'] = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime())
    d['version_changed_from'] = prev
    d['version_change_pending'] = True
with open(state_file, 'w') as out:
    json.dump(d, out)
" "$STATE_FILE" "$CURRENT_VERSION" 2>/dev/null || true
fi


# OPENCLAW_BOOT_RECOVERY_START
# Ensure Docker is fully initialized and recreate the Compose stack when
# containers are absent after a host reboot.
OPENCLAW_BOOT_STACK_DIR="${OPENCLAW_STACK_DIR:-/srv/openclaw/openclaw}"

echo "[watchdog] Waiting for Docker readiness"

docker_ready=false
for attempt in $(seq 1 30); do
  if docker info >/dev/null 2>&1; then
    docker_ready=true
    break
  fi
  sleep 2
done

if [[ "$docker_ready" != "true" ]]; then
  echo "[watchdog] ERROR: Docker did not become ready within 60 seconds" >&2
  exit 1
fi

if [[ ! -f "$OPENCLAW_BOOT_STACK_DIR/docker-compose.yml" ]]; then
  echo "[watchdog] ERROR: Compose file missing in $OPENCLAW_BOOT_STACK_DIR" >&2
  exit 1
fi

echo "[watchdog] Ensuring OpenClaw Compose services exist and are started"

if ! docker compose \
  --project-directory "$OPENCLAW_BOOT_STACK_DIR" \
  up -d --remove-orphans; then
  echo "[watchdog] ERROR: docker compose up failed" >&2
  exit 1
fi

gateway_id="$(
  docker compose \
    --project-directory "$OPENCLAW_BOOT_STACK_DIR" \
    ps -q openclaw-gateway 2>/dev/null || true
)"

if [[ -z "$gateway_id" ]]; then
  echo "[watchdog] ERROR: gateway container was not created" >&2
  exit 1
fi

echo "[watchdog] Waiting for gateway readiness"

gateway_ready=false
for attempt in $(seq 1 45); do
  gateway_state="$(
    docker inspect \
      --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
      "$gateway_id" 2>/dev/null || true
  )"

  case "$gateway_state" in
    "running healthy"|"running no-healthcheck")
      gateway_ready=true
      break
      ;;
  esac

  sleep 2
done

if [[ "$gateway_ready" != "true" ]]; then
  echo "[watchdog] ERROR: gateway did not become ready" >&2
  docker compose \
    --project-directory "$OPENCLAW_BOOT_STACK_DIR" \
    ps >&2 || true
  exit 1
fi

echo "[watchdog] Docker and OpenClaw stack are ready"
# OPENCLAW_BOOT_RECOVERY_END

# ── Track restart attempts in state file ─────────────────────────────────────
get_restart_count() {
  python3 -c "
import sys, json, time
state_file = sys.argv[1]
window = int(sys.argv[2])
try:
    d = json.load(open(state_file))
    attempts = [a for a in d.get('restarts', []) if time.time() - a < window]
    print(len(attempts))
except: print(0)
" "$STATE_FILE" "$RESTART_ATTEMPT_WINDOW" 2>/dev/null || echo 0
}

record_restart() {
  python3 -c "
import sys, json, time
state_file = sys.argv[1]
window = int(sys.argv[2])
try:
    d = json.load(open(state_file))
except:
    d = {}
attempts = [a for a in d.get('restarts', []) if time.time() - a < window]
attempts.append(time.time())
d['restarts'] = attempts
d['last_restart'] = time.time()
import tempfile, os
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(state_file), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(d, f)
os.replace(tmp, state_file)
" "$STATE_FILE" "$RESTART_ATTEMPT_WINDOW" 2>/dev/null || true
}

clear_restarts() {
  python3 -c "
import sys, json
state_file = sys.argv[1]
try:
    d = json.load(open(state_file))
except:
    d = {}
d['restarts'] = []
d['health_failures'] = []
d['last_ok'] = __import__('time').time()
import tempfile, os
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(state_file), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(d, f)
os.replace(tmp, state_file)
" "$STATE_FILE" 2>/dev/null || true
}

get_health_failure_count() {
  python3 -c "
import sys, json, time
state_file = sys.argv[1]
window = int(sys.argv[2])
try:
    d = json.load(open(state_file))
    failures = [a for a in d.get('health_failures', []) if time.time() - a < window]
    print(len(failures))
except: print(0)
" "$STATE_FILE" "$HEALTH_FAILURE_WINDOW" 2>/dev/null || echo 0
}

record_health_failure() {
  python3 -c "
import sys, json, time
state_file = sys.argv[1]
window = int(sys.argv[2])
try:
    d = json.load(open(state_file))
except:
    d = {}
failures = [a for a in d.get('health_failures', []) if time.time() - a < window]
failures.append(time.time())
d['health_failures'] = failures
d['last_health_failure'] = time.time()
import tempfile, os
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(state_file), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(d, f)
os.replace(tmp, state_file)
" "$STATE_FILE" "$HEALTH_FAILURE_WINDOW" 2>/dev/null || true
}

# Restart the gateway via Docker Compose. The compose service owns the gateway
# lifecycle (restart: unless-stopped); we force a restart here when the watchdog
# determines recovery is required.
gateway_restart() {
  _docker_compose_restart 2>>"$LOG_FILE"
}

# Returns seconds since the gateway container started, or 999999 on error.
# Used to enforce GATEWAY_WARMUP_GRACE without docker being stubable in tests
# (docker inspect failure safely returns the large fallback).
_gateway_container_age_seconds() {
  local started
  started="$(docker inspect "${OPENCLAW_GATEWAY_CONTAINER}"     --format '{{.State.StartedAt}}' 2>/dev/null || true)"
  [[ -z "$started" ]] && echo 999999 && return
  python3 -c "
from datetime import datetime, timezone
import sys
raw = sys.argv[1].rstrip('Z').split('.')[0]
started = datetime.fromisoformat(raw).replace(tzinfo=timezone.utc)
now = datetime.now(timezone.utc)
print(int((now - started).total_seconds()))
" "$started" 2>/dev/null || echo 999999
}

maybe_run_session_monitor() {
  local now stamp_mtime

  [[ -x "$SESSION_MONITOR_SCRIPT" ]] || return 0
  mkdir -p "$(dirname "$SESSION_MONITOR_STAMP")"
  now="$(epoch_now)"
  stamp_mtime="$(file_mtime "$SESSION_MONITOR_STAMP" || true)"
  stamp_mtime="${stamp_mtime:-0}"

  if (( now - stamp_mtime < SESSION_MONITOR_THROTTLE )); then
    log "Session monitor throttled"
    return 0
  fi

  log "Running session monitor"
  if bash "$SESSION_MONITOR_SCRIPT" --no-alert >>"$LOG_FILE" 2>&1; then
    touch "$SESSION_MONITOR_STAMP"
  else
    log "Session monitor failed"
    touch "$SESSION_MONITOR_STAMP"
  fi
}

check_agent_layer_health() {
  # Scan recent gateway.err.log for known agent-layer failure patterns. The
  # HTTP /health probe can return 200 while every agent's tool_calls=0 because
  # of codex hang / cross-config provider / dead-run patterns. Log-based probe
  # complements the HTTP probe without spending a real model call per tick.
  local log="$OPENCLAW_DIR/logs/gateway.err.log"
  [[ -r "$log" ]] || return 0

  local cutoff
  cutoff="$(date -d '5 minutes ago' '+%Y-%m-%dT%H:%M' 2>/dev/null)" || return 0

  # Dedupe by timestamp-second: one real failure emits 4-5 log lines across
  # lane=main, lane=session:..., model-fallback/decision, embedded-agent loggers.
  # Counting raw lines triples the apparent rate. Counting distinct timestamps
  # gives one count per real incident (with worst case some adjacent failures
  # collapsing if they fire in the same second — preferred over false positives).
  #
  # Implemented as a single awk filter so pipefail doesn't trip when there are
  # zero matches (grep -E returns 1 on no-match, which under set -euo pipefail
  # would propagate even though "no failures" is the healthy case).
  local count
  count="$(
    awk -v cut="$cutoff" '
      $1 < cut { next }
      /Codex agent harness failed/ ||
      /codex app-server startup aborted/ ||
      /codex app-server client is closed/ ||
      /failed to load configuration: Model provider/ ||
      /Embedded agent failed before reply/ ||
      /stuck session.*age=[0-9]{3,}/ {
        seen[$1] = 1
      }
      END { print length(seen) }
    ' "$log" 2>/dev/null
  )"
  count="${count:-0}"

  if (( count >= 3 )); then
    log "Agent-layer health: $count distinct failure timestamps in last 5 min (HTTP probe is OK but agents may be dead)"
    return 1
  fi
  return 0
}

# ── Gateway health check ──────────────────────────────────────────────────────
GATEWAY_PORT="$(get_gateway_port)"
GATEWAY_URL="http://127.0.0.1:${GATEWAY_PORT}/healthz"

HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 15 "$GATEWAY_URL" 2>/dev/null || echo "000")

if [[ "$HTTP_STATUS" == "200" ]] || [[ "$HTTP_STATUS" == "401" ]]; then
  # 401 = gateway is up, auth token required (expected in normal operation)
  log "Gateway healthy (HTTP $HTTP_STATUS)"
  if ! check_agent_layer_health; then
    record_health_failure
    HEALTH_FAILURE_COUNT="$(get_health_failure_count)"
    log "Agent-layer probe failed; failures in last ${HEALTH_FAILURE_WINDOW}s: $HEALTH_FAILURE_COUNT"
    if (( HEALTH_FAILURE_COUNT >= REQUIRED_HEALTH_FAILURES )); then
      log "Agent-layer probe sustained — escalating to heal.sh"
      if [[ -f "$HEAL_SCRIPT" ]]; then
        bash "$HEAL_SCRIPT" 2>&1 | tee -a "$LOG_FILE" || log "heal.sh exited with errors"
      fi
      # heal.sh fixes config-level issues but only restarts the gateway when
      # it made changes. Backend-subprocess hangs (e.g. "codex app-server
      # client is closed") leave HTTP healthy and config valid — so heal.sh
      # is a no-op and the restart never happens. Force a restart here,
      # subject to the same rate limit as HTTP-down restarts, so the known
      # recovery path actually runs.
      RESTART_COUNT=$(get_restart_count)
      if (( RESTART_COUNT >= MAX_RESTART_ATTEMPTS )); then
        log "Agent-layer recovery: $RESTART_COUNT restart attempts in last ${RESTART_ATTEMPT_WINDOW}s — at limit, NOT restarting"
      else
        log "Agent-layer recovery: restarting gateway (attempt $((RESTART_COUNT + 1))/$MAX_RESTART_ATTEMPTS in window)"
        record_restart
        gateway_restart 2>&1 | tee -a "$LOG_FILE" || log "gateway restart command failed"
      fi
    fi
    exit 1
  fi
  clear_restarts
  maybe_run_session_monitor
  exit 0
fi

# ── Gateway is down ───────────────────────────────────────────────────────────
log "Gateway unreachable (HTTP $HTTP_STATUS)"

GATEWAY_AGE="$(_gateway_container_age_seconds)"
if (( GATEWAY_AGE < GATEWAY_WARMUP_GRACE )); then
  log "Gateway container is only ${GATEWAY_AGE}s old; treating as warm-up — not restarting"
  exit 0
fi

if gateway_running; then
  record_health_failure
  HEALTH_FAILURE_COUNT="$(get_health_failure_count)"
  log "Gateway health failures in last ${HEALTH_FAILURE_WINDOW}s: $HEALTH_FAILURE_COUNT"
  if (( HEALTH_FAILURE_COUNT < REQUIRED_HEALTH_FAILURES )); then
    log "Deferring restart until ${REQUIRED_HEALTH_FAILURES} consecutive unhealthy probes confirm failure"
    exit 1
  fi
else
  log "Gateway container not running; restart may proceed after restart-attempt checks"
fi

RESTART_COUNT=$(get_restart_count)
log "Restart attempts in last ${RESTART_ATTEMPT_WINDOW}s: $RESTART_COUNT"

if [[ "$RESTART_COUNT" -ge "$MAX_RESTART_ATTEMPTS" ]]; then
  log "ERROR: Max restart attempts ($MAX_RESTART_ATTEMPTS) reached in window. Escalating."
  send_notification "OpenClaw Watchdog" "Gateway is down and not recovering. Manual intervention needed. Check: tail -50 ~/.openclaw/logs/gateway.err.log"
  _discord_send error_alerts "$(_discord_ansi '1;31m' 'GATEWAY DOWN' 'not recovering — manual intervention needed')"
  log "ESCALATION: Gateway down, $RESTART_COUNT restarts attempted. Check: tail -50 ~/.openclaw/logs/gateway.err.log"
  exit 1
fi

# ── Attempt recovery ──────────────────────────────────────────────────────────
log "Attempting gateway restart (attempt $((RESTART_COUNT + 1)) of $MAX_RESTART_ATTEMPTS)"
record_restart

gateway_restart 2>&1 | tee -a "$LOG_FILE" || log "gateway restart command failed"
sleep 20

# Verify it came back up
HTTP_STATUS_AFTER=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 15 "$GATEWAY_URL" 2>/dev/null || echo "000")

if [[ "$HTTP_STATUS_AFTER" == "200" ]] || [[ "$HTTP_STATUS_AFTER" == "401" ]]; then
  log "Gateway recovered (HTTP $HTTP_STATUS_AFTER)"
  send_notification "OpenClaw Watchdog" "Gateway restarted successfully."
  _discord_send heartbeat "$(_discord_ansi '1;32m' 'Gateway recovered' 'restarted successfully')"
  maybe_run_session_monitor
  exit 0
fi

# ── Restart didn't help — run heal.sh ────────────────────────────────────────
if [[ -f "$HEAL_SCRIPT" ]]; then
  log "Simple restart failed — running heal.sh"
  bash "$HEAL_SCRIPT" 2>&1 | tee -a "$LOG_FILE" || log "heal.sh exited with errors"
else
  log "heal.sh not found at $HEAL_SCRIPT — skipping"
fi

# Final check
HTTP_FINAL=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 15 "$GATEWAY_URL" 2>/dev/null || echo "000")
if [[ "$HTTP_FINAL" == "200" ]] || [[ "$HTTP_FINAL" == "401" ]]; then
  log "Gateway recovered after heal.sh"
  clear_restarts
  maybe_run_session_monitor
  exit 0
else
  log "Gateway still down after heal.sh (HTTP $HTTP_FINAL)"
  exit 1
fi
