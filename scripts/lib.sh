#!/usr/bin/env bash
# lib.sh — shared functions for openclaw-ops scripts
# Source this from other scripts:
#   LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$LIB_DIR/lib.sh"

# ── Color output (disabled when not a TTY) ─────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GRN='\033[0;32m'
  YLW='\033[0;33m'
  CYN='\033[0;36m'
  BLD='\033[1m'
  RST='\033[0m'
else
  # shellcheck disable=SC2034  # used by sourcing scripts
  RED='' GRN='' YLW='' CYN='' BLD='' RST=''
fi

# ── Logging helpers ─────────────────────────────────────────────────────────
log_fixed()  { echo -e "${GRN}[FIXED]${RST}  $1"; }
log_broken() { echo -e "${RED}[BROKEN]${RST} $1"; }
log_manual() { echo -e "${YLW}[MANUAL]${RST} $1"; }
log_info()   { echo -e "        $1"; }
log_ok()     { echo -e "${GRN}[✓]${RST} $1"; }
log_warn()   { echo -e "${YLW}[!]${RST} $1"; }
log_error()  { echo -e "${RED}[✗]${RST} $1"; }

# ── Python launcher resolution ───────────────────────────────────────────────
# Git Bash on Windows often exposes a non-executable python3 shim via WindowsApps.
# Resolve a real interpreter once and reuse it everywhere scripts source lib.sh.
OPENCLAW_PYTHON3_AVAILABLE=0
OPENCLAW_PYTHON3_CMD=()

_python3_path="$(type -P python3 2>/dev/null || true)"
if [[ -n "$_python3_path" ]] && [[ "$_python3_path" != *'/WindowsApps/python3' ]]; then
  OPENCLAW_PYTHON3_CMD=("$_python3_path")
fi

if [[ ${#OPENCLAW_PYTHON3_CMD[@]} -eq 0 ]]; then
  _py_path="$(type -P py 2>/dev/null || true)"
  if [[ -n "$_py_path" ]]; then
    OPENCLAW_PYTHON3_CMD=("$_py_path" -3)
  fi
fi

if [[ ${#OPENCLAW_PYTHON3_CMD[@]} -eq 0 ]]; then
  _python_path="$(type -P python 2>/dev/null || true)"
  if [[ -n "$_python_path" ]]; then
    OPENCLAW_PYTHON3_CMD=("$_python_path")
  fi
fi

if [[ ${#OPENCLAW_PYTHON3_CMD[@]} -gt 0 ]]; then
  OPENCLAW_PYTHON3_AVAILABLE=1
fi

python3() {
  if [[ "$OPENCLAW_PYTHON3_AVAILABLE" -ne 1 ]]; then
    echo "Error: no usable Python interpreter found" >&2
    return 1
  fi
  "${OPENCLAW_PYTHON3_CMD[@]}" "$@"
}

# ── Docker / ops-config ─────────────────────────────────────────────────────
# Source user-specific overrides written by install-cli-wrapper.sh.
# Sets OPENCLAW_STACK_DIR, OPENCLAW_GATEWAY_CONTAINER, OPENCLAW_CLI_CONTAINER
# for site-specific Docker Compose installs. All vars default safely so scripts
# work without the file (e.g. in tests or native-process installs).
_OPS_CONFIG="${HOME}/.openclaw/ops-config.sh"
# shellcheck source=/dev/null
[[ -f "$_OPS_CONFIG" ]] && source "$_OPS_CONFIG" || true

OPENCLAW_STACK_DIR="${OPENCLAW_STACK_DIR:-/srv/openclaw/openclaw}"
OPENCLAW_GATEWAY_CONTAINER="${OPENCLAW_GATEWAY_CONTAINER:-openclaw-openclaw-gateway-1}"
OPENCLAW_CLI_CONTAINER="${OPENCLAW_CLI_CONTAINER:-openclaw-openclaw-cli-1}"

# ── Preflight checks ───────────────────────────────────────────────────────
require_tools() {
  local missing=()
  for tool in "$@"; do
    if [[ "$tool" == "python3" ]]; then
      [[ "$OPENCLAW_PYTHON3_AVAILABLE" -eq 1 ]] || missing+=("$tool")
    else
      command -v "$tool" &>/dev/null || missing+=("$tool")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing required tools: ${missing[*]}" >&2
    # If `openclaw` is missing but Docker Compose deployment is detected,
    # point at the host CLI wrapper instead of the native installer URL.
    if [[ " ${missing[*]} " == *' openclaw '* ]] && \
       command -v docker >/dev/null 2>&1 && \
       docker inspect "${OPENCLAW_CLI_CONTAINER:-openclaw-openclaw-cli-1}" >/dev/null 2>&1; then
      echo "  → Docker Compose detected — install the host CLI wrapper:" >&2
      echo "      bash scripts/install-cli-wrapper.sh" >&2
      echo "      (then add ~/.local/bin to your PATH)" >&2
    else
      echo "  → Install openclaw: curl -fsSL https://openclaw.ai/install.sh | bash" >&2
    fi
    return 1
  fi
}

# ── Version parsing ─────────────────────────────────────────────────────────
# Usage: get_openclaw_version → "v2026.2.12" or "unknown"
get_openclaw_version() {
  local version
  version="$(
    openclaw --version 2>/dev/null | grep -oE 'v?[0-9]{4}\.[0-9]+\.[0-9]+' | head -1
  )"

  if [[ -z "$version" ]]; then
    echo "unknown"
    return 0
  fi

  [[ "$version" == v* ]] || version="v$version"
  printf '%s\n' "$version"
}

# Usage: version_below "v2026.2.12" "v2026.2.12" → false (not below)
#        version_below "v2026.2.11" "v2026.2.12" → true
version_below() {
  local current="$1" minimum="$2"
  python3 -c "
import sys
a = tuple(int(x) for x in sys.argv[1].lstrip('v').split('.'))
b = tuple(int(x) for x in sys.argv[2].lstrip('v').split('.'))
sys.exit(0 if a < b else 1)
" "$current" "$minimum" 2>/dev/null
}

# ── State file helpers (safe — no shell interpolation in Python) ────────────
# Usage: state_get "$STATE_FILE" "key" → value or empty string
state_get() {
  local state_file="$1" key="$2"
  python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get(sys.argv[2], ''))
except: print('')
" "$state_file" "$key" 2>/dev/null || echo ""
}

# Usage: state_set "$STATE_FILE" "key" "value"
state_set() {
  local state_file="$1" key="$2" value="$3"
  python3 -c "
import json, sys
f = sys.argv[1]
try:
    d = json.load(open(f))
except:
    d = {}
d[sys.argv[2]] = sys.argv[3]
with open(f, 'w') as out:
    json.dump(d, out)
" "$state_file" "$key" "$value" 2>/dev/null || true
}

# ── Platform helpers ────────────────────────────────────────────────────────
# Current time in epoch seconds
epoch_now() {
  date +%s 2>/dev/null || python3 -c "import time; print(int(time.time()))" 2>/dev/null
}

# Current UTC timestamp in ISO-8601 form
iso_now() {
  python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null
}

# Redact common credential patterns from stdin
sanitize_sensitive() {
  python3 -c '
import re
import sys

text = sys.stdin.read()
patterns = [
    (re.compile(r"sk-[A-Za-z0-9-]{20,}"), "[REDACTED_API_KEY]"),
    (re.compile(r"xoxb-[0-9A-Za-z-]+"), "[REDACTED_SLACK_TOKEN]"),
    (re.compile(r"ghp_[A-Za-z0-9]{36,}"), "[REDACTED_GH_TOKEN]"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "[REDACTED_AWS_KEY]"),
    (re.compile(r"Bearer\s+[A-Za-z0-9._-]{20,}", re.IGNORECASE), "Bearer [REDACTED]"),
    (
        re.compile(
            r"(\"(?:password|secret|token|api_key|apiKey|auth_token)\"\s*:\s*\")([^\"]+)(\")",
            re.IGNORECASE,
        ),
        r"\1[REDACTED]\3",
    ),
]

for pattern, replacement in patterns:
    text = pattern.sub(replacement, text)

sys.stdout.write(text)
' 2>/dev/null
}

# Run inline Python and surface the first error line through the standard logger
run_python() {
  local script="$1"
  shift || true

  local output
  if ! output=$(python3 -c "$script" "$@" 2>&1); then
    log_error "Python script failed: ${output%%$'\n'*}"
    return 1
  fi

  printf '%s\n' "$output"
}

# File modification time in epoch seconds
file_mtime() {
  stat -c%Y "$1" 2>/dev/null
}

# File permissions as octal
file_perms() {
  stat -c%a "$1" 2>/dev/null
}

# File size in bytes
file_size() {
  stat -c%s "$1" 2>/dev/null || \
  python3 -c "import os,sys; print(os.path.getsize(sys.argv[1]))" "$1" 2>/dev/null || \
  echo 0
}

# Portable date N days ago (YYYY-MM-DD)
date_days_ago() {
  local days="$1"
  python3 -c "
from datetime import datetime, timedelta
import sys
print((datetime.now() - timedelta(days=int(sys.argv[1]))).strftime('%Y-%m-%d'))
" "$days" 2>/dev/null
}

# ── Gateway port resolution ────────────────────────────────────────────────
# Reads the gateway port from ~/.openclaw/openclaw.json.
# Precedence: OPENCLAW_GATEWAY_PORT env var → config file → 18789 fallback.
# Usage: GATEWAY_PORT=$(get_gateway_port)
get_gateway_port() {
  if [[ -n "${OPENCLAW_GATEWAY_PORT:-}" ]]; then
    echo "$OPENCLAW_GATEWAY_PORT"
    return
  fi
  python3 -c "
import json, sys, os
try:
    cfg = os.path.expanduser('~/.openclaw/openclaw.json')
    d = json.load(open(cfg))
    print(d.get('gateway', {}).get('port', 18789))
except:
    print(18789)
" 2>/dev/null || echo 18789
}

# ── SHA-256 hash ───────────────────────────────────────────────────────────
file_sha256() {
  sha256sum "$1" 2>/dev/null | awk '{print $1}' || \
  openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}' || \
  echo "error"
}

# ── systemd user session detection ─────────────────────────────────────────
# Returns 0 if a systemd user session is reachable, 1 otherwise.
is_systemd_available() {
  systemctl --user status >/dev/null 2>&1 || \
  systemctl --user list-units >/dev/null 2>&1
}

# Returns 0 if the named systemd user unit exists and is active.
is_systemd_unit_active() {
  local unit="$1"
  systemctl --user is-active "$unit" >/dev/null 2>&1
}

# ── Docker gateway helpers ──────────────────────────────────────────────────
# Thin wrappers around docker commands so tests can override them by sourcing
# OPENCLAW_DOCKER_STUBS without stubbing the docker binary itself.
# Requires Docker Compose v2 (docker compose, not docker-compose).

_docker_gateway_status() {
  docker inspect "${OPENCLAW_GATEWAY_CONTAINER}" \
    --format '{{.State.Status}}' 2>/dev/null || echo "missing"
}

_docker_gateway_health() {
  docker inspect "${OPENCLAW_GATEWAY_CONTAINER}" \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    2>/dev/null || echo "none"
}

_docker_compose_restart() {
  docker compose --project-directory "${OPENCLAW_STACK_DIR}" restart openclaw-gateway
}

_docker_compose_up() {
  docker compose --project-directory "${OPENCLAW_STACK_DIR}" up -d openclaw-gateway
}

# Generic per-container helpers used by health-check.sh container targets.
# Defined separately from the gateway-specific helpers above so callers can
# query arbitrary containers (e.g. lofty-mcp-http, openclaw-cli-1) without
# duplicating docker inspect invocations across scripts.
_docker_container_status() {
  docker inspect "$1" --format '{{.State.Status}}' 2>/dev/null || echo "missing"
}

_docker_container_health() {
  docker inspect "$1" \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    2>/dev/null || echo "none"
}

_docker_container_started_at() {
  docker inspect "$1" --format '{{.State.StartedAt}}' 2>/dev/null || true
}

# Allow test environments to override the four helpers above without stubbing docker.
# shellcheck source=/dev/null
[[ -n "${OPENCLAW_DOCKER_STUBS:-}" && -f "${OPENCLAW_DOCKER_STUBS}" ]] &&   source "${OPENCLAW_DOCKER_STUBS}" || true

# Returns 0 if the gateway container is in state "running".
gateway_running() {
  [[ "$(_docker_gateway_status)" == "running" ]]
}

# Returns 0 if the Docker healthcheck reports "healthy".
gateway_healthy() {
  [[ "$(_docker_gateway_health)" == "healthy" ]]
}

# Returns 0 if the expected gateway container exists in Docker.
is_docker_deployment() {
  docker inspect "${OPENCLAW_GATEWAY_CONTAINER}" >/dev/null 2>&1
}

# ── Notifications ──────────────────────────────────────────────────────────
# Usage: send_notification "Title" "Body text"
# Writes to journald (via systemd-cat) and, when a display session is present,
# sends a desktop popup via notify-send. Never fatal.
send_notification() {
  local title="${1:-OpenClaw}"
  local body="${2:-}"

  if command -v systemd-cat &>/dev/null; then
    echo "$title: $body" | systemd-cat -t openclaw-watchdog -p warning 2>/dev/null || true
  fi
  if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v notify-send &>/dev/null; then
    notify-send --urgency=critical "$title" "$body" 2>/dev/null || true
  fi
}
