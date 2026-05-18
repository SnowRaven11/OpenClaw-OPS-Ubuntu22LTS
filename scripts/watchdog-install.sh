#!/usr/bin/env bash
# watchdog-install.sh — install OpenClaw watchdog
#
# Linux (Ubuntu 22+): installs a systemd user timer + service that fires
#   watchdog.sh every 5 minutes. Survives reboots via user lingering.
# macOS: installs a LaunchAgent plist (unchanged from original).
#
# Uninstall: bash watchdog-uninstall.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHDOG_SCRIPT="$SCRIPTS_DIR/watchdog.sh"
LOG_DIR="${OPENCLAW_LOG_DIR:-$HOME/.openclaw/logs}"
PLATFORM="$(uname -s)"

# Validate watchdog script exists
if [[ ! -f "$WATCHDOG_SCRIPT" ]]; then
  echo "Error: watchdog.sh not found at $WATCHDOG_SCRIPT"
  exit 1
fi
chmod +x "$WATCHDOG_SCRIPT"
mkdir -p "$LOG_DIR"

# ── Linux / systemd ──────────────────────────────────────────────────────────
install_linux() {
  local systemd_dir="$HOME/.config/systemd/user"
  local service_src="$SCRIPTS_DIR/../systemd/openclaw-watchdog.service"
  local timer_src="$SCRIPTS_DIR/../systemd/openclaw-watchdog.timer"
  local service_dst="$systemd_dir/openclaw-watchdog.service"
  local timer_dst="$systemd_dir/openclaw-watchdog.timer"

  # Verify systemd --user is available
  if ! systemctl --user status >/dev/null 2>&1 && ! systemctl --user list-units >/dev/null 2>&1; then
    echo "Warning: systemd user session not available."
    echo "Falling back to cron install."
    install_linux_cron
    return
  fi

  if [[ ! -f "$service_src" ]] || [[ ! -f "$timer_src" ]]; then
    echo "Error: systemd unit templates not found under $(dirname "$service_src")."
    echo "Make sure the full openclaw-ops repository is present."
    exit 1
  fi

  mkdir -p "$systemd_dir"

  # Stop existing units before overwriting
  systemctl --user stop openclaw-watchdog.timer  2>/dev/null || true
  systemctl --user disable openclaw-watchdog.timer 2>/dev/null || true

  # Install service — substitute real script path into the SCRIPTS_DIR placeholder
  sed "s|SCRIPTS_DIR|${SCRIPTS_DIR}|g" "$service_src" > "$service_dst"
  cp "$timer_src" "$timer_dst"

  chmod 644 "$service_dst" "$timer_dst"

  systemctl --user daemon-reload
  systemctl --user enable --now openclaw-watchdog.timer

  # Enable lingering so the user timer fires at boot without a login session.
  # Required for headless/server installs. Safe to run on desktop sessions too.
  if command -v loginctl &>/dev/null; then
    if ! loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
      loginctl enable-linger "$USER" 2>/dev/null && \
        echo "Lingering enabled for $USER (services start at boot without login)." || \
        echo "Warning: could not enable lingering. On a headless server, run: loginctl enable-linger $USER"
    fi
  fi

  echo ""
  echo "OpenClaw watchdog installed (systemd user timer)."
  echo ""
  echo "  Runs every:   5 minutes"
  echo "  Script:       $WATCHDOG_SCRIPT"
  echo "  Service:      $service_dst"
  echo "  Timer:        $timer_dst"
  echo "  Log:          $LOG_DIR/watchdog.log"
  echo "  Journal:      journalctl --user -u openclaw-watchdog.service -f"
  echo ""
  echo "Commands:"
  echo "  Status:    systemctl --user status openclaw-watchdog.timer"
  echo "  Run now:   systemctl --user start openclaw-watchdog.service"
  echo "  Uninstall: bash $SCRIPTS_DIR/watchdog-uninstall.sh"
  echo "  Log:       tail -f $LOG_DIR/watchdog.log"
}

# Cron fallback for non-systemd Linux environments
install_linux_cron() {
  local cron_line="*/5 * * * * bash $WATCHDOG_SCRIPT >> $LOG_DIR/watchdog.log 2>&1"
  local marker="# openclaw-watchdog"

  # Remove any existing openclaw-watchdog cron entry before re-adding
  ( crontab -l 2>/dev/null | grep -v "$marker" ; echo "$cron_line $marker" ) | crontab -

  echo ""
  echo "OpenClaw watchdog installed (cron fallback)."
  echo ""
  echo "  Runs every:   5 minutes"
  echo "  Script:       $WATCHDOG_SCRIPT"
  echo "  Cron entry:   $cron_line"
  echo "  Log:          $LOG_DIR/watchdog.log"
  echo ""
  echo "Commands:"
  echo "  Status:    crontab -l | grep openclaw"
  echo "  Uninstall: bash $SCRIPTS_DIR/watchdog-uninstall.sh"
  echo "  Log:       tail -f $LOG_DIR/watchdog.log"
}

# ── macOS / LaunchAgent ──────────────────────────────────────────────────────
install_macos() {
  local PLIST_LABEL="ai.openclaw.watchdog"
  local PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

  mkdir -p "$HOME/Library/LaunchAgents"

  # Unload existing if present
  if launchctl list "$PLIST_LABEL" &>/dev/null; then
    echo "Unloading existing watchdog..."
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || \
      launchctl unload "$PLIST_PATH" 2>/dev/null || true
  fi

  # Discover the actual node binary directory at install time
  # so the plist PATH is concrete, not dependent on nvm at runtime
  local NODE_BIN_DIR=""
  if command -v node &>/dev/null; then
    NODE_BIN_DIR="$(dirname "$(command -v node)")"
  fi

  local PLIST_PATH_VALUE="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/opt/homebrew/sbin:${HOME}/.local/bin"
  if [[ -n "$NODE_BIN_DIR" ]] && [[ "$NODE_BIN_DIR" != "/usr/bin" ]] && [[ "$NODE_BIN_DIR" != "/usr/local/bin" ]]; then
    PLIST_PATH_VALUE="${PLIST_PATH_VALUE}:${NODE_BIN_DIR}"
  fi

  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${WATCHDOG_SCRIPT}</string>
  </array>

  <key>StartInterval</key>
  <integer>300</integer>

  <key>RunAtLoad</key>
  <false/>

  <key>StandardOutPath</key>
  <string>${LOG_DIR}/watchdog-launchd.log</string>

  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/watchdog-launchd.log</string>

  <key>KeepAlive</key>
  <false/>

  <!-- PATH resolved at install time — re-run watchdog-install.sh if you change Node versions -->
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${PLIST_PATH_VALUE}</string>
    <key>HOME</key>
    <string>${HOME}</string>
  </dict>
</dict>
</plist>
PLIST

  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || \
    launchctl load "$PLIST_PATH"

  echo ""
  echo "OpenClaw watchdog installed (macOS LaunchAgent)."
  echo ""
  echo "  Runs every:   5 minutes"
  echo "  Script:       $WATCHDOG_SCRIPT"
  echo "  Plist:        $PLIST_PATH"
  echo "  Log:          $LOG_DIR/watchdog.log"
  echo ""
  echo "Commands:"
  echo "  Status:    launchctl list $PLIST_LABEL"
  echo "  Run now:   launchctl kickstart -k gui/\$(id -u)/$PLIST_LABEL"
  echo "  Uninstall: bash $SCRIPTS_DIR/watchdog-uninstall.sh"
  echo "  Log:       tail -f $LOG_DIR/watchdog.log"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "$PLATFORM" in
  Linux)  install_linux  ;;
  Darwin) install_macos  ;;
  *)
    echo "Error: unsupported platform: $PLATFORM"
    echo "Supported: Linux (Ubuntu 22+), macOS"
    exit 1
    ;;
esac
