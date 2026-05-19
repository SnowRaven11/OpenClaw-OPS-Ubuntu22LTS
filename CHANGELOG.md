# Changelog

Notable changes to openclaw-ops. Format follows [Keep a Changelog](https://keepachangelog.com/).

**Target platform: Ubuntu 22 LTS.** macOS and Windows support was removed in v1.0.1.

---

## [v1.0.6] — 2026-05-19

### Removed
- `scripts/linux-prereqs.sh` — deleted. Most packages it installed (`python3`,
  `curl`, `openssl`, `procps`) are pre-installed on Ubuntu 22 LTS. `loginctl
  enable-linger` is already handled by `watchdog-install.sh`. `jq` was listed
  but not used by any script. Only `ripgrep` (for `session-search.sh`) and
  `libnotify-bin` (optional desktop notifications) are non-standard; these are
  now noted inline in the README prerequisites table.

### Changed
- `README.md` — prerequisites table now includes install hints for optional
  packages (`ripgrep`, `libnotify-bin`) directly; removed the installer block
  and the step referencing it from the quick-start guide

---

## [v1.0.5] — 2026-05-19

### Added
- `.github/workflows/ci.yml` — GitHub Actions workflow running on `ubuntu-22.04` on every push and PR to main; steps: install `shellcheck`, `ripgrep`, `python3` → `shellcheck --severity=warning scripts/*.sh` → `bash tests/run.sh`
- `CONTRIBUTING.md` PR checklist: added `shellcheck --severity=warning scripts/*.sh` as a required local check before opening a PR

### Fixed
- `scripts/workspace-auto-commit.sh`, `scripts/workspace-git-audit.sh` (SC2088) — `"~/"*` in `expand_path()` case patterns quoted so tilde never expanded; changed to `~/*` which is equivalent and correct
- `scripts/watchdog.sh` — `check_agent_layer_health()` still had the dead BSD `date -v-5M` (macOS-only) branch with a silent fallback to GNU `date -d`; removed the dead branch, GNU form only
- `scripts/security-scan.sh` — removed two dead `case` patterns from the credential-scan skip list: `*/codex-home/sessions/*` was already covered by `*/sessions/*`, and `*/scripts/**/*.bak*` was already covered by `*/scripts/*.bak*` (in bash `case` patterns `*` crosses directory boundaries)
- `README.md`, `scripts/security-scan.sh`, `scripts/session-resume.sh`, `.github/ISSUE_TEMPLATE/bug-report.md` — final macOS/platform remnants missed in earlier passes

### Removed
- `scripts/check-update.sh` — `OPENCLAW_JSON` variable defined but never referenced
- `scripts/codex-perf-check.sh` — `VALID_LEVELS` array superseded by `WEAK_LEVELS`; `CODEX_STATUS` assignment superseded by two separate extraction variables used by the actual logic

---

## [v1.0.4] — 2026-05-19

### Changed
- `CONTRIBUTING.md` — replaced "platform parity (Linux, BSD)" contribution area with "Ubuntu 22 LTS operational improvements"; removed dead "Linux / systemd parity for LaunchAgent-only flows" entry; simplified failure pattern verification snippet to GNU `date -d '24 hours ago'` only

---

## [v1.0.3] — 2026-05-19

### Changed
- `CHANGELOG.md` — added full versioned entries for v1.0.1 and v1.0.2; preserved earlier upstream history under Pre-v1.0.1

---

## [v1.0.2] — 2026-05-19

### Changed
- `docs/architecture.md` — dropped "Linux (Ubuntu 22 LTS)" qualifiers from section headers now that Ubuntu 22 is the only platform; sections now read "Service architecture", "Log paths", "Restart command", "Notifications"
- `docs/troubleshooting.md` — removed macOS "Live logs" comment from the diagnostic workflow; simplified Codex detection snippet to GNU `date -d '1 hour ago'` (BSD `date -v-1H` removed); removed iMessage troubleshooting section; removed WSL2-Specific Issues section

### Removed
- `docs/channel-setup.md` — iMessage section removed (macOS-only channel, not available on Linux)

---

## [v1.0.1] — 2026-05-19

Full redesign targeting Ubuntu 22 LTS as the sole supported platform. macOS (LaunchAgent) and Windows (WSL2/cygpath) support removed.

### Added
- `scripts/linux-prereqs.sh` — installs Ubuntu 22 apt dependencies (`python3`, `curl`, `openssl`, `ripgrep`, `libnotify-bin`, `jq`) and enables `loginctl enable-linger` for headless boot-time service startup
- `systemd/openclaw-gateway.service` — systemd user service for the gateway process (`Restart=no` to preserve watchdog restart authority)
- `systemd/openclaw-watchdog.service` — oneshot service that runs `watchdog.sh` on each timer tick
- `systemd/openclaw-watchdog.timer` — fires `openclaw-watchdog.service` every 5 minutes (`OnCalendar=*:0/5`, `Persistent=true` so missed ticks fire once on resume)
- `lib.sh`: `is_systemd_available()`, `is_systemd_unit_active()` — helpers used by watchdog, heal, check-update, and security-scan to detect and interact with systemd user units
- `lib.sh`: `send_notification()` — replaces all `osascript` calls; writes a `warning`-priority journald entry via `systemd-cat` on every alert, plus a `notify-send` desktop popup when `DISPLAY`/`WAYLAND_DISPLAY` is set
- `lib.sh`: `file_size()` — cross-platform file size helper (`stat -c%s`), used by `session-purge.sh` instead of inline BSD/GNU `stat` branches
- `session-monitor.sh`: `--agent <name>` flag — scopes the JSONL scan to a single agent's directory
- `session-resume.sh`: `--agent <name>` flag — auto-finds the most recent session for an agent using Python `os.scandir()` (portable; GNU `find -printf` is Linux-only)
- `session-resume.sh`: auto-pager — pipes output through `$PAGER` / `less -R` when stdout is a terminal; skipped when redirected or piped
- `security-scan.sh`: `[8/8] Watchdog status` compliance check (-5 points) — verifies `openclaw-watchdog.timer` is active; distinguishes installed-but-stopped from not-installed
- `check-update.sh`: `restart_hint()` — emits the correct gateway restart command for the current environment (`systemctl --user restart` when the unit is active, `openclaw gateway restart` otherwise)
- `tests/run.sh`: fake `systemctl` stub in `setup_fake_env()` — intercepts all `systemctl --user` calls that scripts now make; defaults to unit-not-installed; configurable via `SYSTEMCTL_GATEWAY_ACTIVE_RC` and `SYSTEMCTL_WATCHDOG_ACTIVE_RC` env vars

### Changed
- `watchdog-install.sh` — complete rewrite: installs a systemd user timer on Linux (cron fallback for non-systemd); the 90-line macOS LaunchAgent plist block is gone; script is now 75 lines
- `watchdog-uninstall.sh` — complete rewrite: removes systemd units and/or cron entry on Linux; 35 lines (down from 84)
- `watchdog.sh` — `gateway_restart()` prefers `systemctl --user restart openclaw-gateway.service` when the unit is active; falls back to `openclaw gateway restart` (cron installs); `osascript` escalation replaced with `send_notification()`
- `heal.sh` — `gateway_do_start()` and `gateway_do_restart()` prefer systemctl when the gateway is a managed unit; `uname -s` guards removed
- `check-update.sh` — hardcoded `openclaw gateway restart` hints replaced with `restart_hint()` in all three summary paths
- `codex-perf-check.sh` — gateway restart block uses `is_systemd_unit_active` guard instead of `uname -s`
- `security-scan.sh` — `run_drift()` SHA-256 tool order corrected to `sha256sum` → `openssl` (drops `shasum`, which is macOS-native and absent from Ubuntu by default); permission check now uses separate `perm_skipped_plugin` and `perm_skipped_systemd` counters with distinct messages; `.service`/`.timer` files exempt from 600 permission check (systemd requires world-readable unit files — 644 is correct)
- `session-monitor.sh` — critical severity alerts now call `send_notification()` in addition to `openclaw system event`; `xargs -P4` dispatch wrapped in `|| true` so a single corrupt session file cannot abort the entire scan under `set -euo pipefail`
- `session-purge.sh` — inline `stat -f%z || stat -c%s` replaced with `file_size()` from `lib.sh`
- `lib.sh`: `file_mtime()` and `file_perms()` — removed `OSTYPE == darwin` branches; `stat -c%Y` / `stat -c%a` only
- `lib.sh`: `file_sha256()` — removed `shasum` fallback; `sha256sum` then `openssl`
- `health-check.sh` — `process_elapsed_seconds()` simplified to `ps -o etimes=` only; `etime=` fallback removed (procps-ng on Ubuntu 22 always supports `etimes=`)
- `daily-digest.sh` — `osascript` notification replaced with `send_notification()`
- `tests/run.sh` — removed `cygpath` and `USERPROFILE` (Windows remnants); `ps` stub simplified to `etimes=` only; removed `test_health_check_falls_back_to_etime_when_etimes_unsupported` (tested the now-removed `etime=` fallback path); updated `test_security_scan_detects_nested_files_and_permissions` to reflect `.service` file permission exemption

### Removed
- `watchdog-install.sh` — `install_macos()` function (macOS LaunchAgent plist)
- `watchdog-uninstall.sh` — `uninstall_macos()` function
- `lib.sh` — `OSTYPE == darwin` branches in `file_mtime`, `file_perms`; `shasum` fallback in `file_sha256`; macOS `osascript` branch in `send_notification()`
- `health-check.sh` — `ps -o etime=` fallback path (BSD-style elapsed time format)
- `security-scan.sh` — macOS `launchctl` watchdog check from `[8/8]` compliance section
- `SKILL.md` / `README.md` / `docs/architecture.md` — macOS quickstart, LaunchAgent quarantine section (replaced with systemd unit quarantine), platform support tables

---

## [Pre-v1.0.1 / Earlier]

### Added
- `scripts/workspace-auto-commit.sh` — local-only git snapshot helper for `~/.openclaw/workspace*` repos. Supports `--workspace PATH`, `--all`, `--dry-run`, and JSON output. Never pushes.
- `scripts/workspace-git-audit.sh` — audits OpenClaw workspace repos for git status, dirty counts, and auto-commit cron coverage; `--show-cron` prints suggested cron setup commands for uncovered repos.
- `docs/architecture.md` — single-owner restart policy and conventions for extending detection patterns rather than adding parallel watchdogs.
- `CONTRIBUTING.md` with guidance on what to contribute and what to avoid (especially: don't add new restart-capable watchdogs).
- `.github/ISSUE_TEMPLATE/new-failure-pattern.md` — structured way for users to report new failure modes worth detecting.
- `.github/ISSUE_TEMPLATE/bug-report.md` — generic bug report template.
- `scripts/watchdog.sh` `check_agent_layer_health()` now also detects `codex app-server client is closed` — a common failure mode where the bundled codex subprocess drops its stdio connection mid-call. Gateway HTTP `/health` returns 200 but no agent calls succeed.
- `docs/troubleshooting.md`: "Agent Silent But Gateway Healthy (Codex Backend Failure)" entry documenting symptoms, detection, recovery, and the fallback-chain trap.

### Changed
- `scripts/watchdog.sh` `check_agent_layer_health()` now dedupes by timestamp before counting. A single real failure emits 4-5 log lines across different loggers — counting raw matches inflated the apparent failure rate by 4-5x and would have false-triggered the restart threshold.
- `scripts/check-update.sh`: `--fix` mode now verifies each command's exit code via `try_fix()`. The previous `cmd 2>/dev/null && fixed || bad` pattern claimed success even when the underlying command failed silently. Closes [#3](https://github.com/cathrynlavery/openclaw-ops/issues/3).
- `scripts/check-update.sh`: summary now distinguishes "X applied, Y failed" and exits non-zero if any fix failed.

### Fixed
- `.gitignore` now excludes `*.bak` and `*.bak.*` patterns so script-generated backup files don't get committed.

---

For history before this changelog was started, see `git log`.
