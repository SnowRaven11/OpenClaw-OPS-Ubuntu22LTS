#!/usr/bin/env bash
# linux-prereqs.sh — install Ubuntu 22 LTS prerequisites for openclaw-ops
#
# Run once before using any other scripts:
#   bash scripts/linux-prereqs.sh
#
# Requires sudo for apt-get. Does not install openclaw itself —
# see: curl -fsSL https://openclaw.ai/install.sh | bash

set -euo pipefail

PLATFORM="$(uname -s)"
if [[ "$PLATFORM" != "Linux" ]]; then
  echo "This script is for Linux only (detected: $PLATFORM)."
  exit 1
fi

if ! command -v apt-get &>/dev/null; then
  echo "Error: apt-get not found. This script targets Ubuntu/Debian."
  exit 1
fi

echo "Installing openclaw-ops prerequisites..."
sudo apt-get update -qq
sudo apt-get install -y \
  python3 \
  python3-pip \
  curl \
  openssl \
  procps \
  ripgrep \
  libnotify-bin \
  jq

# libnotify-bin provides notify-send for desktop notifications when
# DISPLAY/WAYLAND_DISPLAY is set. Safe to have on headless servers too.

echo ""
echo "All prerequisites installed."
echo ""

# Enable lingering so systemd user services start at boot without a login.
# Required for headless/server installs.
if command -v loginctl &>/dev/null; then
  if loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
    echo "Lingering already enabled for $USER."
  else
    loginctl enable-linger "$USER"
    echo "Lingering enabled for $USER (services start at boot without login)."
  fi
fi

echo ""
echo "Next steps:"
echo "  1. Install openclaw:  curl -fsSL https://openclaw.ai/install.sh | bash"
echo "  2. Run initial heal:  bash scripts/heal.sh"
echo "  3. Install watchdog:  bash scripts/watchdog-install.sh"
