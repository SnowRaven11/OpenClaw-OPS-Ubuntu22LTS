#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools curl pgrep ps grep python3 || exit 1

TARGETS_FILE="${OPENCLAW_HEALTH_TARGETS:-$HOME/.openclaw/health-targets.conf}"
VERBOSE=0
NO_ALERT=0
failures=()

usage() {
  cat <<'USAGE'
Usage: scripts/health-check.sh [-t targets-file] [--verbose] [--no-alert]

Targets file format (pipe-delimited):
  url|<name>|<url>|<contains-optional>
  process|<name>|<pgrep-pattern>|<min-uptime-seconds-optional>
  container|<name>|<docker-container-name>|<min-uptime-seconds-optional>

Examples:
  url|gateway|http://127.0.0.1:<PORT>/healthz
  container|gateway|openclaw-openclaw-gateway-1|300
  process|worker|openclaw-worker|300
USAGE
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

elapsed_to_seconds() {
  local raw="$1"
  raw="${raw//[[:space:]]/}"
  [[ -z "$raw" ]] && return 1

  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$raw"
    return 0
  fi

  python3 -c '
import sys

raw = sys.argv[1]
days = 0
if "-" in raw:
    day_part, raw = raw.split("-", 1)
    days = int(day_part)

parts = [int(part) for part in raw.split(":")]
if len(parts) == 2:
    hours = 0
    minutes, seconds = parts
elif len(parts) == 3:
    hours, minutes, seconds = parts
else:
    raise SystemExit(1)

print(days * 86400 + hours * 3600 + minutes * 60 + seconds)
' "$raw" 2>/dev/null
}

process_elapsed_seconds() {
  local pid="$1"
  local elapsed seconds
  elapsed="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  seconds="$(elapsed_to_seconds "$elapsed" || true)"
  [[ -n "$seconds" ]] && printf '%s\n' "$seconds" && return 0
  return 1
}

log_verbose() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    printf '%s\n' "$1"
  fi
}

record_failure() {
  local message="$1"
  failures+=("$message")
  printf 'FAIL: %s\n' "$message"
}

check_url() {
  local name="$1"
  local url="$2"
  local contains="${3:-}"
  local body_file
  local code

  body_file="$(mktemp)"
  code="$(curl -sS -L -o "$body_file" -w '%{http_code}' "$url" || true)"

  if [[ "$code" != "200" ]]; then
    record_failure "url:$name returned status $code ($url)"
    rm -f "$body_file"
    return
  fi

  if [[ -n "$contains" ]] && ! grep -Fq "$contains" "$body_file"; then
    record_failure "url:$name missing expected content [$contains] ($url)"
    rm -f "$body_file"
    return
  fi

  log_verbose "OK: url:$name"
  rm -f "$body_file"
}

check_container() {
  local name="$1"
  local container="$2"
  local min_uptime="${3:-${OPENCLAW_HEALTH_MIN_UPTIME:-300}}"
  local status started uptime health

  status="$(_docker_container_status "$container")"
  if [[ "$status" != "running" ]]; then
    record_failure "container:$name not running (status: $status)"
    return
  fi

  started="$(_docker_container_started_at "$container")"
  if [[ -z "$started" ]]; then
    record_failure "container:$name could not read StartedAt"
    return
  fi

  uptime="$(python3 -c "
from datetime import datetime, timezone
import sys
raw = sys.argv[1].rstrip('Z').split('.')[0]
started = datetime.fromisoformat(raw).replace(tzinfo=timezone.utc)
print(int((datetime.now(timezone.utc) - started).total_seconds()))
" "$started" 2>/dev/null || echo 0)"

  if (( uptime < min_uptime )); then
    record_failure "container:$name uptime below threshold (${uptime}s < ${min_uptime}s)"
    return
  fi

  # Also surface unhealthy state from the container's own healthcheck when present.
  health="$(_docker_container_health "$container")"
  if [[ "$health" != "none" && "$health" != "healthy" && "$health" != "starting" ]]; then
    record_failure "container:$name docker healthcheck status: $health"
    return
  fi

  log_verbose "OK: container:$name"
}

check_process() {
  local name="$1"
  local pattern="$2"
  local min_uptime="${3:-${OPENCLAW_HEALTH_MIN_UPTIME:-300}}"
  local pids
  local uptime_ok=0
  local best_uptime=0
  local pid

  pids="$(pgrep -f "$pattern" || true)"
  if [[ -z "$pids" ]]; then
    record_failure "process:$name not running (pattern: $pattern)"
    return
  fi

  for pid in $pids; do
    local etimes
    etimes="$(process_elapsed_seconds "$pid" || true)"
    [[ -z "$etimes" ]] && continue

    if (( etimes > best_uptime )); then
      best_uptime="$etimes"
    fi

    if (( etimes >= min_uptime )); then
      uptime_ok=1
    fi
  done

  if (( uptime_ok == 0 )); then
    record_failure "process:$name uptime below threshold (${best_uptime}s < ${min_uptime}s)"
    return
  fi

  log_verbose "OK: process:$name"
}

send_alert() {
  local text="$1"

  if [[ "$NO_ALERT" -eq 1 ]]; then
    return
  fi

  if command -v openclaw >/dev/null 2>&1; then
    openclaw system event --mode now --text "$text" >/dev/null 2>&1 || true
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--targets)
      TARGETS_FILE="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    --no-alert)
      NO_ALERT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "$TARGETS_FILE" ]]; then
  _port="$(get_gateway_port)"
  mkdir -p "$(dirname "$TARGETS_FILE")"
  if is_docker_deployment; then
    # Docker Compose install: the gateway runs inside a container, so a host
    # pgrep can never find it. Check the container's runtime state instead.
    cat >"$TARGETS_FILE" <<EOF
# Auto-generated by health-check.sh — edit as needed.
# Port read from ~/.openclaw/openclaw.json at creation time.

# URL targets
url|gateway|http://127.0.0.1:${_port}/healthz

# Container targets (Docker Compose deployments)
container|gateway|${OPENCLAW_GATEWAY_CONTAINER}|300
EOF
    printf 'Created targets file: %s (Docker Compose deployment detected, gateway port %s)\n' "$TARGETS_FILE" "$_port" >&2
  else
    cat >"$TARGETS_FILE" <<EOF
# Auto-generated by health-check.sh — edit as needed.
# Port read from ~/.openclaw/openclaw.json at creation time.

# URL targets
url|gateway|http://127.0.0.1:${_port}/healthz

# Process targets
process|gateway|openclaw.*gateway|300
EOF
    printf 'Created targets file: %s (gateway port %s)\n' "$TARGETS_FILE" "$_port" >&2
  fi
fi

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="$(trim "$raw_line")"
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

  IFS='|' read -r kind name arg3 arg4 <<<"$line"
  kind="$(printf '%s' "$(trim "${kind:-}")" | tr '[:upper:]' '[:lower:]')"
  name="$(trim "${name:-}")"
  arg3="$(trim "${arg3:-}")"
  arg4="$(trim "${arg4:-}")"

  case "$kind" in
    url)
      if [[ -z "$name" || -z "$arg3" ]]; then
        record_failure "invalid url target line: $raw_line"
        continue
      fi
      check_url "$name" "$arg3" "$arg4"
      ;;
    process)
      if [[ -z "$name" || -z "$arg3" ]]; then
        record_failure "invalid process target line: $raw_line"
        continue
      fi
      check_process "$name" "$arg3" "$arg4"
      ;;
    container)
      if [[ -z "$name" || -z "$arg3" ]]; then
        record_failure "invalid container target line: $raw_line"
        continue
      fi
      check_container "$name" "$arg3" "$arg4"
      ;;
    *)
      record_failure "unknown target type in line: $raw_line"
      ;;
  esac
done <"$TARGETS_FILE"

if (( ${#failures[@]} > 0 )); then
  summary="health-check failed (${#failures[@]} issue(s)): ${failures[*]}"
  send_alert "$summary"
  exit 1
fi

log_verbose "All health checks passed"
