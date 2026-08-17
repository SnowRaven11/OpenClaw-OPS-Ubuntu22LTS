#!/usr/bin/env bash
# usage-growth-alert.sh — daily wrapper around ~/openclaw-oauth-usage-audit.sh
# Run: bash usage-growth-alert.sh
#
# Runs the 24h-vs-prior-24h token usage comparison and, if a token-usage growth
# flag is emitted (>50%/>100%/>200%, see the audit script), alerts via
# oc-notify.sh (Discord/Telegram) instead of leaving it buried in a cron log
# nobody reads daily. Added 2026-08-17 after a ~5-day, ~19.6M-token runaway
# went undetected until manual investigation — see
# ~/openclaw-oauth-credit-investigation.md.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

AUDIT_SCRIPT="${AUDIT_SCRIPT:-/home/thompson/openclaw-oauth-usage-audit.sh}"
NOTIFY="${NOTIFY_BIN:-/usr/local/bin/oc-notify.sh}"
# The audit script's own FLAG lines already start at 50% — this var is
# documentation of that floor, not a numeric comparison performed here.
USAGE_GROWTH_ALERT_THRESHOLD="${USAGE_GROWTH_ALERT_THRESHOLD:-50}"

if [[ ! -x "$AUDIT_SCRIPT" ]]; then
  log_error "audit script not found or not executable: $AUDIT_SCRIPT"
  exit 1
fi

OUTPUT=$("$AUDIT_SCRIPT" --hours 24 2>&1) || {
  log_error "audit script exited non-zero"
  echo "$OUTPUT"
  exit 1
}

FLAG_LINE=$(echo "$OUTPUT" | grep -m1 '^FLAG:' || true)
CHANGE_LINE=$(echo "$OUTPUT" | grep -m1 '^Change:' || true)

if [[ -n "$FLAG_LINE" ]]; then
  log_warn "$FLAG_LINE"
  if [[ -x "$NOTIFY" ]]; then
    "$NOTIFY" "OpenClaw token usage growth alert" \
      "$FLAG_LINE
$CHANGE_LINE
Run: $AUDIT_SCRIPT --hours 24  (on m80-prime) for full breakdown." \
      || log_error "oc-notify.sh call failed"
  else
    log_error "oc-notify.sh not found or not executable: $NOTIFY (alert not sent)"
  fi
else
  log_ok "no usage-growth flag (threshold >=${USAGE_GROWTH_ALERT_THRESHOLD}% not tripped): $CHANGE_LINE"
fi
