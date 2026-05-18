#!/usr/bin/env bash
# watchdog-uninstall.sh — remove OpenClaw watchdog
#
# Linux: removes the systemd user timer + service (or cron entry).
# macOS: removes the LaunchAgent plist.

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLATFORM="$(uname -s)"

# ── Linux ────────────────────────────────────────────────────────────────────
uninstall_linux() {
  local systemd_dir="$HOME/.config/systemd/user"
  local removed=0

  # systemd path
  if systemctl --user list-units --all 2>/dev/null | grep -q 'openclaw-watchdog'; then
    systemctl --user stop openclaw-watchdog.timer   2>/dev/null || true
    systemctl --user stop openclaw-watchdog.service 2>/dev/null || true
    systemctl --user disable openclaw-watchdog.timer 2>/dev/null || true
    echo "Watchdog timer stopped and disabled."
    removed=1
  fi

  for unit in openclaw-watchdog.service openclaw-watchdog.timer; do
    local path="$systemd_dir/$unit"
    if [[ -f "$path" ]]; then
      rm "$path"
      echo "Removed: $path"
      removed=1
    fi
  done

  if [[ "$removed" -eq 1 ]]; then
    systemctl --user daemon-reload 2>/dev/null || true
  fi

  # cron fallback path
  local marker="# openclaw-watchdog"
  if crontab -l 2>/dev/null | grep -q "$marker"; then
    crontab -l 2>/dev/null | grep -v "$marker" | crontab -
    echo "Removed cron entry."
    removed=1
  fi

  if [[ "$removed" -eq 0 ]]; then
    echo "Watchdog was not installed."
  else
    echo "OpenClaw watchdog uninstalled."
  fi
}

# ── macOS ────────────────────────────────────────────────────────────────────
uninstall_macos() {
  local PLIST_LABEL="ai.openclaw.watchdog"
  local PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

  if launchctl list "$PLIST_LABEL" &>/dev/null; then
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || \
      launchctl unload "$PLIST_PATH" 2>/dev/null || true
    echo "Watchdog unloaded."
  else
    echo "Watchdog was not running."
  fi

  if [[ -f "$PLIST_PATH" ]]; then
    rm "$PLIST_PATH"
    echo "Plist removed: $PLIST_PATH"
  fi

  echo "OpenClaw watchdog uninstalled."
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "$PLATFORM" in
  Linux)  uninstall_linux  ;;
  Darwin) uninstall_macos  ;;
  *)
    echo "Error: unsupported platform: $PLATFORM"
    exit 1
    ;;
esac
