#!/usr/bin/env bash
# watchdog-uninstall.sh — remove OpenClaw watchdog (systemd timer or cron)

set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Error: this script targets Linux Ubuntu 22 LTS."
  exit 1
fi

systemd_dir="$HOME/.config/systemd/user"
removed=0

if systemctl --user list-units --all 2>/dev/null | grep -q 'openclaw-watchdog'; then
  systemctl --user stop openclaw-watchdog.timer   2>/dev/null || true
  systemctl --user stop openclaw-watchdog.service 2>/dev/null || true
  systemctl --user disable openclaw-watchdog.timer 2>/dev/null || true
  echo "Watchdog timer stopped and disabled."
  removed=1
fi

for unit in openclaw-watchdog.service openclaw-watchdog.timer; do
  path="$systemd_dir/$unit"
  if [[ -f "$path" ]]; then
    rm "$path"
    echo "Removed: $path"
    removed=1
  fi
done

[[ "$removed" -eq 1 ]] && systemctl --user daemon-reload 2>/dev/null || true

marker="# openclaw-watchdog"
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
