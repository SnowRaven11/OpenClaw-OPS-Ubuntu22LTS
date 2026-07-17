# Changelog

Notable changes to openclaw-ops. Format follows [Keep a Changelog](https://keepachangelog.com/).

**Target platform: Ubuntu 22 LTS.** macOS and Windows support was removed in v1.0.1.

---

## [v1.2.13] — 2026-07-17

### Fixed
- `scripts/watchdog.sh` — boot recovery. `_docker_compose_restart` (`docker compose restart`) can only restart a container that already exists — if the stack was never brought up after a host reboot, restart failed outright and OpenClaw stayed offline until a manual `docker compose up -d`. `gateway_restart()` now checks `gateway_running` first: if the gateway container is running, behavior is unchanged (`_docker_compose_restart`); if it isn't (including "doesn't exist"), it calls the existing `_docker_compose_up` helper instead (`docker compose up -d openclaw-gateway`), which is idempotent — creates+starts a missing container, no-ops on an already-running one. Reuses two helpers that already existed in `lib.sh` (the second already used live by `heal.sh`) instead of adding new logic, so the existing restart-rate-limit/warmup-grace machinery in `watchdog.sh` is untouched and no new code path bypasses the `_docker_*` stub layer that `tests/run.sh` overrides. +1 test (43 → 44).

  An earlier version of this fix (committed then caught before tagging) added ~75 lines of unconditional-every-tick logic that called raw `docker`/`docker compose`/`docker inspect` directly, bypassing `lib.sh`'s stub layer entirely — it broke all 9 test call sites that invoke `watchdog.sh` and violated this repo's own "never call bare `docker`" rule (see CLAUDE.md Deployment model). Replaced with the minimal fix above before release; no tag was ever cut against the broken version.

---

## [v1.2.12] — 2026-06-10

### Fixed
- `scripts/heal.sh` Step 4 — cron re-enablement was silently skipped on v2026.6.1+ because `jobs.json` was removed in that release. Step 4 is now version-gated: pre-v2026.6.1 uses the existing `jobs.json` path; v2026.6.1+ queries `openclaw cron list --all --json` and reads `state.consecutiveErrors` to find auto-disabled crons. The result is the same behavior (re-enable any cron disabled by errors) on both old and new installs.
- `scripts/heal.sh` — `CRON_FILE` path updated from tilde-expanded `~/.openclaw/cron/jobs.json` to `$OPENCLAW_DIR/cron/jobs.json` (honors `OPENCLAW_HOME`)

### Added
- `tests/run.sh` — `test_heal_cron_step_version_gated_for_v2026_6_1_plus`: static check that the `version_below v2026.6.1` guard appears before the `jobs.json` reference. Test count: 42 → 43

---

## [v1.2.11] — 2026-05-31

### Fixed
- `scripts/security-scan.sh` check [3] — `agents.defaults.sandbox.mode=off` now treated as an accepted warning with no score deduction on Docker-in-Docker hosts where the `docker` binary is unavailable inside the container. Mirrors the existing `gateway.bind=lan` pattern. Previously penalized `-15` even though `check-update.sh` explicitly enforces `off` on this install.

---

## [v1.2.10] — 2026-05-31

### Added
- `scripts/lib.sh` — defines `OPENCLAW_DIR="${OPENCLAW_DIR:-${OPENCLAW_HOME:-$HOME}/.openclaw}"` so all scripts honor the `OPENCLAW_HOME` env var introduced in OpenClaw 2026.5.28 (wins over `HOME` in OC's config root resolution). Scripts that already defined their own `OPENCLAW_DIR` are unaffected (lib.sh sets it first; their `:-` no-ops).
- `tests/run.sh` — `test_check_update_sandbox_mode_flagged_when_not_off`: stubs `agents.defaults.sandbox.mode=non-main` (the 2026.5.28 new default) and verifies check [5] fires with the expected diagnostic. Test count: 41 → 42

### Fixed
- `scripts/heal.sh`, `check-update.sh`, `watchdog.sh`, `session-purge.sh`, `security-scan.sh`, `install-cli-wrapper.sh`, `codex-perf-check.sh` — replaced hardcoded `$HOME/.openclaw` paths with `$OPENCLAW_DIR` so config, state, sessions, and approvals resolve correctly when `OPENCLAW_HOME` is set
- `scripts/lib.sh` `_discord_channel` — same path fix for `discord-channels.json` lookup

---

## [v1.2.9] — 2026-05-30

### Fixed
- `scripts/security-scan.sh` — `gateway.bind=lan` now treated as an accepted warning with no score deduction (matches common LAN-only install pattern)
- `scripts/security-scan.sh` — `~/.openclaw/.env` with chmod 600 approved as an active runtime secret exception (ANTHROPIC_API_KEY stored securely is not a violation)
- `scripts/security-scan.sh` — config file path now expands `$OPENCLAW_HOME` environment variable in addition to `~` (uses `os.path.expandvars` alongside `os.path.expanduser`)

---

## [v1.2.8] — 2026-05-27

### Changed
- Discord messages: only the alert label is now colored; verbose details render in default channel color. `_discord_ansi` updated to accept an optional third `detail` argument; all 9 call sites split into colored label + plain detail

---

## [v1.2.7] — 2026-05-27

### Added
- Discord notifications for all 9 existing `send_notification()` call sites across 6 scripts. Requires the Discord channel in OpenClaw to be connected; routes messages through `openclaw message send --channel discord`. No new alert conditions — existing events only
- `scripts/lib.sh` — three new helpers: `_discord_channel` (looks up a channel ID by key from `~/.openclaw/discord-channels.json`), `_discord_ansi` (wraps text in a Discord ANSI color block), `_discord_send` (resolves the channel ID and sends via the gateway; skips silently when the config file is absent, the key is missing, or the gateway is not running)
- `config/discord-channels.example.json` — repo-shipped template for the per-user channel ID file; copy to `~/.openclaw/discord-channels.json` and fill in your server's IDs. Channel IDs never live in the repo
- `scripts/install-cli-wrapper.sh` — prints a one-time setup hint pointing at the example file when `~/.openclaw/discord-channels.json` does not exist
- `tests/run.sh` — two new tests: `test_discord_send_skips_when_key_missing_from_config` (config exists but key absent → openclaw not called) and `test_discord_send_skips_when_gateway_not_running` (gateway stopped → openclaw not called). Test count: 39 → 41

### Routing
| Event | Channel key |
|-------|-------------|
| Gateway down / escalation | `error_alerts` |
| Gateway recovered (state change only) | `heartbeat` |
| Heal: items still broken | `error_alerts` |
| Heal: items self-fixed | `audit_trail` |
| Update check: fixes failed | `error_alerts` |
| Update check: fixes applied OK | `oc_updates` |
| Post-update: completed with warnings | `error_alerts` |
| Daily digest generated | `live_logs` |
| Session monitor: critical incident | `error_alerts` |

---

## [v1.2.6] — 2026-05-27

### Fixed
- `scripts/heal.sh` Layer 2b — `tools.exec.security` and `tools.exec.strictInlineEval` are config paths that were **removed in OpenClaw v2026.5.0** (exec policy is now managed entirely via `exec-approvals.json`). Without a version gate, every `heal.sh` run on v2026.5+ reported two bogus `[BROKEN] Failed to set tools.exec.*` lines. Now version-gated: skipped with an info message on v2026.5+, unchanged on v2026.2.24–v2026.4.x
- `scripts/check-update.sh` section `[2]` — same root cause: the v2026.2.24 breaking-change check for `tools.exec.security` always saw empty values (path not found → `""`) and flagged them as misconfigured, incrementing `ISSUES_FOUND` and printing phantom `[✗]` lines on every run against a v2026.5+ install. Now version-gated; prints a `[✓]` skip note on v2026.5+
- `scripts/check-update.sh` config snapshot — three fields in `SNAPSHOT_FIELDS` pointed at paths that no longer exist in v2026.5+: `tools.exec.security`, `tools.exec.strictInlineEval` (removed), and `agents.defaults.subagents.maxSpawnDepth` (renamed to `maxConcurrent`); `agents.defaults.model` also restructured to `model.primary`. Updated to current paths; `tools.exec.*` conditionally re-added for pre-v2026.5 installs

### Added
- `tests/run.sh` — two new tests: `test_heal_layer2b_version_gated_for_v2026_5_plus` (static guard that the version gate precedes the `tools.exec` config get in heal.sh) and `test_check_update_exec_section_skipped_for_v2026_5_plus` (behavioral: runs check-update.sh with v2026.5.1 and removed-path stubs, asserts no phantom issue is reported). Test count: 37 → 39

### Changed
- `README.md` — bumped "Tested against OpenClaw" from `2026.5.12` to `2026.5.26`
- `docs/cli-reference.md` — removed four config paths that no longer exist in v2026.5+: `agents.defaults.params.context1m`, `agents.defaults.params.cacheRetention`, `agents.defaults.subagents.maxSpawnDepth`, `agents.defaults.subagents.maxChildrenPerAgent`; replaced with current equivalents (`agents.defaults.model.primary`, `agents.defaults.subagents.maxConcurrent`)

---

## [v1.2.5] — 2026-05-20

### Fixed
- `scripts/lib.sh`, `scripts/install-cli-wrapper.sh`, `scripts/heal.sh`, `scripts/check-update.sh` — Docker Compose helpers and operator hints used `docker compose -C ${OPENCLAW_STACK_DIR}` (8 call sites), but Compose v2 has **no** `-C` shorthand (`-C` is `git` syntax). Every real gateway lifecycle call from these scripts failed with `unknown shorthand flag: 'C'` on the live install. Switched to the documented `docker compose --project-directory ${OPENCLAW_STACK_DIR}` form. Tests stub `_docker_compose_*` directly so the bad flag was never exercised in CI; added `test_docker_compose_helpers_use_project_directory_flag` to catch any regression in the real implementation
- `scripts/heal.sh` step `[5]` — rapid-fire loop detector called `json.load(open(session_file))` on `*.jsonl` session transcripts, which always raises `JSONDecodeError` on line 2 of any non-trivial session. The `try: except: pass` block swallowed the error, so the loop detector never fired against a real session. Rewritten to parse JSONL line-by-line and compare assistant-text content windows; added `test_heal_loop_check_parses_jsonl_line_by_line` static guard
- `scripts/heal.sh` — `require_tools python3 curl openssl` did not include `openclaw`, but every config-fix step (`gateway.auth.mode`, `tools.exec.security`, `tools.exec.strictInlineEval`, allowlist patching, cron re-enable, `openclaw doctor`) calls the CLI. Without the host CLI wrapper installed on Docker deployments, these silently fell through to `|| echo "unknown"` patterns and the script reported misleading `[broken]` status. Now requires `openclaw` and exits with a Docker-aware install hint when missing
- `scripts/health-check.sh` — auto-generated default targets file contained `process|gateway|openclaw.*gateway|300`, which always fails on Docker Compose installs (the gateway runs inside a container; the host `pgrep` cannot see it). On Docker deployments the script now generates a `container|gateway|${OPENCLAW_GATEWAY_CONTAINER}|300` target instead, and the URL line uses `/healthz` (the actual gateway endpoint) for consistency with `watchdog.sh`

### Added
- `scripts/health-check.sh` — new `container|<name>|<container-name>|<min-uptime-seconds>` target kind. Checks Docker container state, uptime, and the container's own healthcheck status. Reports failures when the container is not running, was started inside the warmup window, or its healthcheck reports `unhealthy`. Auto-generated default file picks this kind on Docker Compose deployments (`is_docker_deployment` true); falls back to the legacy `process|...` line otherwise
- `scripts/lib.sh` — generic `_docker_container_status`, `_docker_container_health`, and `_docker_container_started_at` helpers that take a container name argument (the gateway-specific helpers hard-coded `${OPENCLAW_GATEWAY_CONTAINER}`). Used by `health-check.sh`; tests stub them through `OPENCLAW_DOCKER_STUBS`
- `scripts/lib.sh` `require_tools` — when `openclaw` is the missing tool and a Docker Compose deployment is detected (the CLI container exists), the error hint now points at `bash scripts/install-cli-wrapper.sh` instead of the native installer URL. Falls back to the installer URL on native installs or when Docker is unavailable
- `tests/run.sh` — five new tests: `test_heal_loop_check_parses_jsonl_line_by_line`, `test_docker_compose_helpers_use_project_directory_flag`, `test_health_check_container_target_passes_when_running_and_warm`, `test_health_check_container_target_reports_when_not_running`, `test_health_check_container_target_reports_when_unhealthy`. Test count: 32 → 37

### Changed
- `README.md` — quickstart `docker compose -C /srv/openclaw/openclaw ps` corrected to `--project-directory`; "Tested against OpenClaw 2026.5.4" bumped to 2026.5.12
- `docs/architecture.md` — restart-command paragraph updated to `--project-directory` form

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
