# Changelog

Notable changes to openclaw-ops. Format follows [Keep a Changelog](https://keepachangelog.com/).

**Target platform: Ubuntu 22 LTS.** macOS and Windows support was removed in v1.0.1.

---

## [v1.2.3] — 2026-05-19

### Fixed
- `scripts/heal.sh` — step `[5]` session file globs used `*.json` instead of `*.jsonl`; real session transcripts are `*.jsonl` and `*.trajectory.jsonl`, so the 10MB large-file archival and rapid-fire loop detection never fired against real sessions. Large-file find changed to `*.jsonl`; loop check now uses `find -name "*.jsonl" ! -name "*.trajectory.jsonl"` (trajectory files have a different structure incompatible with the JSON loop detector)
- `scripts/session-purge.sh` — orphan UUID extraction used `${base%%.jsonl*}` which extracted `uuid.trajectory` (not `uuid`) from `uuid.trajectory.jsonl` files; classified as orphans and deleted with `--apply` even when the parent session was still active. Fixed to `${base%%.*}`
- `scripts/session-monitor.sh` — `find '*.jsonl'` matched all 299 `.trajectory.jsonl` files across agents; trajectory files are Codex rollout logs with a different structure and were silently skipped after wasted I/O. Added `! -name '*.trajectory.jsonl'` exclusion

---

## [v1.2.1] — 2026-05-19

### Fixed
- `scripts/watchdog.sh` — health probe was hitting `/health` instead of `/healthz` (actual gateway endpoint); would cause the watchdog to always see the gateway as unreachable and trigger restart-storms on a healthy container
- `scripts/codex-perf-check.sh` — gateway restart block still used `is_systemd_unit_active("openclaw-gateway.service")` + `systemctl --user restart`; the service unit was deleted in v1.2.0 so the restart silently failed after every `--fix` run; now calls `_docker_compose_restart()`
- `scripts/check-update.sh` — `restart_hint()` emitted `systemctl --user restart openclaw-gateway.service`; updated to emit `docker compose restart` with the wrapper alternative
- `SKILL.md` — 5 references to `openclaw-gateway.service` in diagnostic commands and interpretation rules; updated to `docker inspect`/`docker logs`/`docker exec` equivalents

---

## [v1.2.0] — 2026-05-19

Docker Compose is now the standard deployment model. The systemd gateway service is removed; Docker Compose (`restart: unless-stopped`) owns the gateway lifecycle. The watchdog timer still runs every 5 minutes via systemd to detect and recover stuck/unhealthy states.

### Added
- `scripts/install-cli-wrapper.sh` — installs `~/.local/bin/openclaw` wrapper for Docker Compose deployments; routes `gateway restart/start/stop` to `docker compose -C STACK_DIR`; all other subcommands to `docker exec CLI_CONTAINER node dist/index.js`; writes `~/.openclaw/ops-config.sh` with site-specific container names and stack dir (sourced automatically by `lib.sh`)
- `scripts/lib.sh` — `OPENCLAW_STACK_DIR`, `OPENCLAW_GATEWAY_CONTAINER`, `OPENCLAW_CLI_CONTAINER` constants (defaulting to the production Compose stack); four Docker-aware internal helpers: `_docker_gateway_status()`, `_docker_gateway_health()`, `_docker_compose_restart()`, `_docker_compose_up()`; public `gateway_running()`, `gateway_healthy()`, `is_docker_deployment()`; sources `~/.openclaw/ops-config.sh` when present; `OPENCLAW_DOCKER_STUBS` hook for test environments to override Docker helpers without stubbing the binary
- `tests/run.sh` — `test_watchdog_restarts_unhealthy_docker_gateway` (33rd test); Docker helper stubs injected via `OPENCLAW_DOCKER_STUBS` in `setup_fake_env()`

### Changed
- `scripts/watchdog.sh` — `gateway_restart()` calls `_docker_compose_restart()`; `gateway_pid()`/`gateway_process_age()` replaced with `_gateway_container_age_seconds()` (uses `docker inspect StartedAt`; returns 999999 on error so warmup grace is safe in test environments without Docker); warm-up check uses container start time instead of process age; `require_tools` no longer requires `openclaw` (wrapper provides it; watchdog core path is HTTP probe → Docker inspect → Compose restart)
- `scripts/heal.sh` — local `gateway_running()` override removed (lib.sh Docker-aware version used); `gateway_do_start()` calls `_docker_compose_up()`; `gateway_do_restart()` calls `_docker_compose_restart()`; `require_tools` softened (removes `openclaw` and `pgrep` as hard preflights)
- `scripts/watchdog-install.sh` — gateway service installation removed; adds a hint to run `install-cli-wrapper.sh` when `openclaw` is not in PATH
- `docs/architecture.md` — "Service architecture" section updated for Docker Compose gateway; log paths table replaces `journalctl -u openclaw-gateway.service` with `docker logs`; "Restart command" section updated
- `README.md` — quickstart updated for Docker Compose; prerequisites table adds `docker` and `docker compose v2`; log-viewing section updated

### Removed
- `systemd/openclaw-gateway.service` — Docker Compose with `restart: unless-stopped` owns gateway lifecycle; the systemd unit is unused in Docker deployments

---

## [v1.0.7] — 2026-05-19

### Added
- `scripts/log-rotate.sh` — rotates `~/.openclaw/logs/*.log` and `~/.openclaw/logs/*.jsonl` daily via `logrotate --state` (per-user state file; no system `/etc/logrotate.d/` config required). Keeps 14 days by default. Installed automatically as a `@daily` cron job by `watchdog-install.sh` on both systemd and cron-fallback installs.

### Changed
- `scripts/watchdog-install.sh` — adds a `@daily` cron entry for `log-rotate.sh` on both the systemd and cron-fallback install paths; prints confirmation in the post-install summary
- `scripts/heal.sh` — calls `send_notification()` at summary time: "Self-healed N item(s)" when fixes were applied, or "N item(s) still broken — manual intervention needed" when broken items remain. Surfaces self-heal events to journald (and desktop popup if DISPLAY set) on headless servers.
- `scripts/post-update.sh` — calls `send_notification()` when the post-update sequence completes with warnings, so failures in `check-update.sh --fix` / `heal.sh` / `security-scan.sh` / `openclaw health` surface to the operator without requiring them to tail the terminal.
- `scripts/check-update.sh` — calls `send_notification()` in `--fix` mode: once on success ("Applied N fix(es) — restart gateway to apply") and once on partial failure ("Applied N, M FAILED — see logs"); also surfaces these events to journald/notify-send on headless deployments

### Fixed
- `scripts/check-update.sh` — section `[3]` (gateway auth mode): when `openclaw config get gateway.auth.mode` returns an empty or unresolvable value, the result was shown as `good "gateway.auth.mode = ''"` — falsely passing the check. Now warns "Could not determine gateway.auth.mode — check openclaw is responding" instead.

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
