#!/usr/bin/env bash
# watchdog-install.sh — install OpenClaw watchdog as a systemd user timer
#
# Installs openclaw-watchdog.timer (fires every 5 min) and enables user
# lingering so the timer survives reboots on headless servers.
# Cron fallback available for non-systemd Linux environments.
#
# Uninstall: bash watchdog-uninstall.sh

set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Error: this script targets Linux Ubuntu 22 LTS."
  exit 1
fi

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHDOG_SCRIPT="$SCRIPTS_DIR/watchdog.sh"
LOG_DIR="${OPENCLAW_LOG_DIR:-$HOME/.openclaw/logs}"

if [[ ! -f "$WATCHDOG_SCRIPT" ]]; then
  echo "Error: watchdog.sh not found at $WATCHDOG_SCRIPT"
  exit 1
fi
chmod +x "$WATCHDOG_SCRIPT"
mkdir -p "$LOG_DIR"

# ── systemd path ─────────────────────────────────────────────────────────────
if ! systemctl --user status >/dev/null 2>&1 && ! systemctl --user list-units >/dev/null 2>&1; then
  echo "Warning: systemd user session not available — falling back to cron."
  cron_line="*/5 * * * * bash $WATCHDOG_SCRIPT >> $LOG_DIR/watchdog.log 2>&1"
  marker="# openclaw-watchdog"
  ( crontab -l 2>/dev/null | grep -v "$marker"; echo "$cron_line $marker" ) | crontab -
  log_rotate_line="@daily bash $SCRIPTS_DIR/log-rotate.sh"
  ( crontab -l 2>/dev/null | grep -v "log-rotate.sh"; echo "$log_rotate_line" ) | crontab -
  echo ""
  echo "OpenClaw watchdog installed (cron fallback)."
  echo "  Cron entry: $cron_line"
  echo "  Log:        $LOG_DIR/watchdog.log"
  echo ""
  echo "Log rotation: @daily cron entry installed (log-rotate.sh)"
  exit 0
fi

systemd_dir="$HOME/.config/systemd/user"
service_src="$SCRIPTS_DIR/../systemd/openclaw-watchdog.service"
timer_src="$SCRIPTS_DIR/../systemd/openclaw-watchdog.timer"
service_dst="$systemd_dir/openclaw-watchdog.service"
timer_dst="$systemd_dir/openclaw-watchdog.timer"

if [[ ! -f "$service_src" ]] || [[ ! -f "$timer_src" ]]; then
  echo "Error: systemd unit templates not found under $(dirname "$service_src")."
  exit 1
fi

mkdir -p "$systemd_dir"

systemctl --user stop openclaw-watchdog.timer  2>/dev/null || true
systemctl --user disable openclaw-watchdog.timer 2>/dev/null || true

sed "s|SCRIPTS_DIR|${SCRIPTS_DIR}|g" "$service_src" > "$service_dst"
cp "$timer_src" "$timer_dst"
chmod 644 "$service_dst" "$timer_dst"

systemctl --user daemon-reload
systemctl --user enable --now openclaw-watchdog.timer

if command -v loginctl &>/dev/null; then
  if ! loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
    loginctl enable-linger "$USER" 2>/dev/null && \
      echo "Lingering enabled for $USER (timer starts at boot without login)." || \
      echo "Warning: could not enable lingering — run manually: loginctl enable-linger $USER"
  fi
fi

echo ""
echo "OpenClaw watchdog installed."
echo ""
echo "  Runs every:   5 minutes"
echo "  Script:       $WATCHDOG_SCRIPT"
echo "  Service:      $service_dst"
echo "  Timer:        $timer_dst"
echo "  Log:          $LOG_DIR/watchdog.log"
echo "  Journal:      journalctl --user -u openclaw-watchdog.service -f"
echo ""
# Add daily log rotation via user cron (logrotate runs per-user via --state;
# no system-level /etc/logrotate.d/ config needed).
log_rotate_line="@daily bash $SCRIPTS_DIR/log-rotate.sh"
if command -v crontab &>/dev/null; then
  ( crontab -l 2>/dev/null | grep -v "log-rotate.sh"; echo "$log_rotate_line" ) | crontab -
  LOG_ROTATE_MSG="@daily cron entry installed"
else
  LOG_ROTATE_MSG="crontab not found — add manually: $log_rotate_line"
fi

echo "Commands:"
echo "  Status:    systemctl --user status openclaw-watchdog.timer"
echo "  Run now:   systemctl --user start openclaw-watchdog.service"
echo "  Uninstall: bash $SCRIPTS_DIR/watchdog-uninstall.sh"
echo "  Log:       tail -f $LOG_DIR/watchdog.log"
echo ""
echo "Log rotation: $LOG_ROTATE_MSG"
echo "  Run now:   bash $SCRIPTS_DIR/log-rotate.sh"
