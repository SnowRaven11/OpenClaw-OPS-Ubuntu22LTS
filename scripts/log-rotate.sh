#!/usr/bin/env bash
# log-rotate.sh — rotate ~/.openclaw/logs with logrotate
#
# Generates a logrotate config from $HOME at runtime (no static template needed)
# and runs it with a per-user state file so system logrotate is not required.
#
# Run manually, or install as a daily cron/timer:
#   (crontab -l 2>/dev/null; echo "@daily bash $SCRIPTS_DIR/log-rotate.sh") | crontab -
#
# Override defaults with env vars:
#   OPENCLAW_LOG_DIR        — defaults to ~/.openclaw/logs
#   OPENCLAW_LOGROTATE_STATE — defaults to ~/.local/share/openclaw-logrotate.state
#   OPENCLAW_LOGROTATE_KEEP — number of old files to retain (default: 14)

set -euo pipefail

LOGS_DIR="${OPENCLAW_LOG_DIR:-$HOME/.openclaw/logs}"
STATE_FILE="${OPENCLAW_LOGROTATE_STATE:-$HOME/.local/share/openclaw-logrotate.state}"
ROTATE="${OPENCLAW_LOGROTATE_KEEP:-14}"

if ! command -v logrotate &>/dev/null; then
  echo "logrotate not found. Install: sudo apt-get install logrotate" >&2
  exit 1
fi

mkdir -p "$LOGS_DIR" "$(dirname "$STATE_FILE")"

conf=$(mktemp)
trap 'rm -f "$conf"' EXIT

# Generate config with the real log dir expanded from $HOME.
# copytruncate is used because the gateway process holds gateway.err.log open
# continuously; rename+recreate (the default) would redirect to the new inode
# only on the next gateway restart.
cat > "$conf" <<EOF
$LOGS_DIR/*.log $LOGS_DIR/*.jsonl {
    daily
    rotate $ROTATE
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

logrotate --state "$STATE_FILE" "$conf" "$@"
