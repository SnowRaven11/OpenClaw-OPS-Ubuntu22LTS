# openclaw-ops

OpenClaw gateway operations skill for agent environments. Covers health checks, repair workflows, continuous monitoring, session analysis, update-change detection, and security review for a local or self-hosted OpenClaw install.

Tested against OpenClaw `2026.5.26`.

## What it does

### Skill
- **`/openclaw-ops`** — full triage and configuration: gateway, auth, exec approvals, cron jobs, channels, sessions, and installation

### Scripts

Scripts are grouped by function. For full per-script documentation — purpose, when to use, flags, output, gotchas — see [`docs/scripts-reference.md`](docs/scripts-reference.md).

#### Install & setup

| Script | Purpose |
|--------|---------|
| `scripts/install-cli-wrapper.sh` | Installs `~/.local/bin/openclaw` host wrapper for Docker Compose installs; writes `~/.openclaw/ops-config.sh` |
| `scripts/watchdog-install.sh` | Installs the watchdog as a systemd user timer (5 min); cron fallback for non-systemd; also adds daily log-rotate cron |
| `scripts/watchdog-uninstall.sh` | Removes the watchdog (systemd units and/or cron entry) |

#### Always-on monitoring

| Script | Purpose |
|--------|---------|
| `scripts/watchdog.sh` | Runs every 5 min — HTTP ping, restart if down, `heal.sh` escalation after 3 consecutive failures, `notify-send` alert |
| `scripts/session-monitor.sh` | Behavioral checks over live session JSONL files; detects retry loops, stuck runs, auth errors |
| `scripts/log-rotate.sh` | Rotates `~/.openclaw/logs` via logrotate; installed as a daily cron job by `watchdog-install.sh` |

#### One-shot recovery

| Script | Purpose |
|--------|---------|
| `scripts/heal.sh` | One-shot auto-fix for the most common gateway issues: gateway down, auth mode, exec approvals, auto-disabled crons, stuck sessions |
| `scripts/post-update.sh` | Post-update orchestrator: runs `check-update.sh --fix`, `heal.sh`, workspace reconcile, `security-scan.sh`, final health check, policy-guard sentinel |
| `scripts/check-update.sh` | Detects version changes, explains broken config, auto-fix with `--fix`; version-aware (skips checks for paths removed in newer releases) |

#### Declarative checks

| Script | Purpose |
|--------|---------|
| `scripts/health-check.sh` | Declarative URL/container/process health checks; auto-generates a Docker-aware targets file on first run |
| `scripts/security-scan.sh` | Config hardening and credential exposure scan (0–100 score); skips bulky session history unless `--include-sessions` is passed |

#### Performance tuning

| Script | Purpose |
|--------|---------|
| `scripts/codex-perf-check.sh` | Checks and fixes four GPT-5.x performance opt-ins that ship disabled by default (`--fix` to apply); requires v2026.4.x+ |

#### Cron management

| Script | Purpose |
|--------|---------|
| `scripts/cron-error-inspector.sh` | Formats `openclaw cron list` failures as a triage-ready list: agent, schedule, last-error-reason, consecutive-error count, payload preview, fix hints |
| `scripts/cron-optimize.sh` | Audits `agentTurn` cron jobs for missing `--light-context` flag (reduces token cost and timeout risk); `--fix` applies changes |

#### Sessions & transcripts

| Script | Purpose |
|--------|---------|
| `scripts/session-purge.sh` | Reclaim disk and trim session-context bloat: archives large sessions, removes orphaned files, prunes old deleted/reset archives (`--apply` to write) |
| `scripts/session-search.sh` | Full-text session search with structured output and secret redaction |
| `scripts/session-resume.sh` | Compaction-first markdown resume for a single session, including failure context |
| `scripts/prompt-truncation-report.sh` | Reports bootstrap-prompt truncation warnings from the latest session per agent (fires when AGENTS.md + MEMORY.md + SOUL*.md exceed model context budget) |

#### Workspace (git safety)

| Script | Purpose |
|--------|---------|
| `scripts/workspace-auto-commit.sh` | Local-only git snapshot for OpenClaw workspace repos; defaults to `~/.openclaw/workspace`, supports `--workspace` and `--all`, never pushes |
| `scripts/workspace-git-audit.sh` | Audits `~/.openclaw/workspace*` repos for git status and auto-commit cron coverage; `--show-cron` prints setup commands for uncovered repos |

#### Reporting & triage

| Script | Purpose |
|--------|---------|
| `scripts/daily-digest.sh` | Incident, activity, watchdog, and cost summary for the last N hours |
| `scripts/incident-manager.sh` | Shared incident lifecycle helper (sourced by other scripts; not run directly) |
| `scripts/remediation-board.sh` | Durable checklist for surfaced remediation items — status transitions, evidence, next-check tracking |

#### Audits & housekeeping

| Script | Purpose |
|--------|---------|
| `scripts/agent-dirs-audit.sh` | Audits dirs under `~/.openclaw/agents/` not in `agents.list`; classifies as EMPTY/STALE/DORMANT and offers cleanup modes |
| `scripts/context-audit.sh` | Static audit of bootstrap-context bloat — scans AGENTS.md, MEMORY.md, SOUL*.md, estimates tokens, flags files above threshold |
| `scripts/backup-rotate.sh` | Groups `*.bak*` files under `~/.openclaw` by path prefix and keeps the newest N per group; prunes accumulated backup noise |
| `scripts/skill-audit.sh` | Static security audit for third-party skills before installation |

#### Shared library

| Script | Purpose |
|--------|---------|
| `scripts/lib.sh` | Shared helpers: Docker introspection, port resolution, logging, state files, notifications, sanitization (sourced by all other scripts) |

## Prerequisites

| Tool | Required for |
|------|-------------|
| `openclaw` | everything |
| `python3` | heal.sh, lib.sh, watchdog.sh, session scripts |
| `curl` | watchdog.sh, health-check.sh HTTP checks |
| `openssl` | heal.sh auth token generation |
| `rg` (ripgrep) | session-search.sh |
| `docker` | gateway detection and restart (watchdog.sh, heal.sh) |
| `docker compose` (v2) | gateway lifecycle — restart/up via `--project-directory` |
| `systemd` | watchdog timer only (gateway managed by Docker Compose) |
| `notify-send` (optional) | desktop notifications when DISPLAY is set — `sudo apt-get install libnotify-bin` |

`python3`, `curl`, `openssl`, and `logrotate` are pre-installed on Ubuntu 22 LTS. Install ripgrep if you want `session-search.sh`:
```bash
sudo apt-get install -y ripgrep
```

## Minimum version

**v2026.2.12** or later. Versions before this contain critical CVEs (including CVE-2026-25253 plus additional SSRF, path traversal, and prompt-injection fixes).

```bash
openclaw --version
```

Scripts are version-aware: checks for config paths removed in newer OpenClaw releases are automatically skipped (e.g. `tools.exec.*` removed in v2026.5.0 — exec policy is now managed via `exec-approvals.json`).

## Quick start

```bash
# 1. Verify Docker Compose gateway is running
docker compose --project-directory /srv/openclaw/openclaw ps

# 2. Install host CLI wrapper (routes openclaw commands into Docker containers)
bash scripts/install-cli-wrapper.sh
# Add ~/.local/bin to PATH if prompted, then: source ~/.bashrc

# 3. One-time heal pass (fixes approvals, auth mode, cron state)
bash scripts/heal.sh

# 4. Install always-on watchdog (systemd user timer, 5-min interval)
bash scripts/watchdog-install.sh

# 5. Verify watchdog is running
systemctl --user status openclaw-watchdog.timer

# 6. View logs
tail -f ~/.openclaw/logs/watchdog.log
journalctl --user -u openclaw-watchdog.service -f

# 7. After every OpenClaw update
bash scripts/post-update.sh

# 8. Run health checks — targets file is auto-generated on first run
bash scripts/health-check.sh --verbose

# 9. Audit workspace git protection
bash scripts/workspace-git-audit.sh --show-cron

# Update triage only:
bash scripts/check-update.sh        # report only
bash scripts/check-update.sh --fix  # report + auto-fix

# View incident history
cat ~/.openclaw/logs/heal-incidents.jsonl
```

### Gateway port

Scripts read the gateway port directly from `~/.openclaw/openclaw.json` — no hardcoded port, no manual setup. Override with the `OPENCLAW_GATEWAY_PORT` env var if needed.

### Session monitoring

```bash
# Scan all active sessions for behavioral issues
bash scripts/session-monitor.sh --verbose

# Search session history
bash scripts/session-search.sh "unauthorized" --limit 10

# Purge old/large sessions (dry run first, then --apply)
bash scripts/session-purge.sh
bash scripts/session-purge.sh --apply

# Build a resume for a specific session
bash scripts/session-resume.sh ~/.openclaw/agents/daedalus/sessions/<session>.jsonl

# 24-hour digest: incidents, activity, costs
bash scripts/daily-digest.sh --hours 24

# Track cron/ops findings to completion
bash scripts/remediation-board.sh import-cron-errors
bash scripts/remediation-board.sh list
```

## Watchdog escalation model

1. **Tier 1** — HTTP ping every 5 min (systemd user timer; cron fallback on non-systemd)
2. **Tier 2** — Gateway restart via `docker compose --project-directory` + `heal.sh` if simple restart fails
3. **Tier 3** — journald warning + desktop popup (via `notify-send`) + Discord `#error-alerts` after 3 failures in 15 min

## Platform

**Target: Ubuntu 22 LTS.** Cron fallback available for non-systemd Linux. Other platforms are not supported.

## Viewing logs

```bash
docker logs -f openclaw-openclaw-gateway-1
journalctl --user -u openclaw-watchdog.service -f
tail -f ~/.openclaw/logs/gateway.err.log
tail -f ~/.openclaw/logs/watchdog.log
```

## Notes

- `health-check.sh` creates `~/.openclaw/health-targets.conf` on first run using the port from `openclaw.json`. On Docker Compose deployments the default target is a `container|gateway|...` check rather than a host process check. Edit the file to add custom targets or adjust thresholds.
- `health-check.sh` reports a container uptime failure immediately after a gateway restart if the target has a minimum uptime threshold (default 300s). Expected — lower the threshold during smoke tests, then restore it.
- `security-scan.sh` reports file paths and line numbers for suspected secrets but redacts the values themselves.
- `check-update.sh` is intended for post-upgrade triage. It is normal to report a version change the first time it runs after an upgrade. Version-specific checks are automatically skipped when the underlying config path no longer exists in the installed version.
- `post-update.sh` skips the full sequence when the stored version matches the current version. Otherwise it runs `check-update.sh --fix`, `heal.sh`, the workspace reconcile script if present, `security-scan.sh`, and a final `openclaw health --json`, then touches `~/.openclaw/state/policy-guard.trigger`.
- Set `OPENCLAW_POST_UPDATE_RECONCILE_SCRIPT` (and optionally `OPENCLAW_POST_UPDATE_RECONCILE_INTERPRETER`) if the reconcile script lives somewhere other than the default workspace path.
- Set `OPENCLAW_SKIP_WRAPPER_BACKUP=1` when an outer automation layer calls `post-update.sh` so nested `openclaw` calls don't trigger backup loops.
- `codex-perf-check.sh` requires v2026.4.x or later — the settings it checks don't exist in earlier releases.
- `session-purge.sh` excludes `*.trajectory.jsonl` files from orphan detection using `${base%%.*}` UUID extraction to avoid false positives against Codex rollout logs.

## Discord notifications

When a Discord channel is connected in OpenClaw, ops scripts can route alerts to specific Discord channels. Channel IDs are stored in a per-user file so anyone can clone the repo without touching script code:

```bash
cp config/discord-channels.example.json ~/.openclaw/discord-channels.json
# Edit ~/.openclaw/discord-channels.json and fill in your channel IDs
```

Notifications are sent via `openclaw message send --channel discord`. If the gateway is not running, sends are skipped silently. If the config file is absent or a key is missing, that send is a no-op.

| Event | Channel key | Default channel |
|-------|-------------|-----------------|
| Gateway down / escalation | `error_alerts` | `#error-alerts` |
| Gateway recovered (state change only) | `heartbeat` | `#heartbeat-monitor` |
| Heal: items still broken | `error_alerts` | `#error-alerts` |
| Heal: items self-fixed | `audit_trail` | `#audit-trail` |
| Update check: fixes failed | `error_alerts` | `#error-alerts` |
| Update check: fixes applied OK | `oc_updates` | `#oc-updates-logs` |
| Post-update: completed with warnings | `error_alerts` | `#error-alerts` |
| Daily digest generated | `live_logs` | `#live-logs` |
| Session monitor: critical incident | `error_alerts` | `#error-alerts` |

## Version history

| Version | Key change |
|---------|-----------|
| v1.0.1–v1.0.7 | Ubuntu 22 LTS redesign: systemd units, `send_notification`, log-rotate; macOS/Windows support removed |
| v1.2.0 | Docker Compose deployment: lib.sh Docker helpers, `install-cli-wrapper.sh`, watchdog uses `docker inspect` / `compose restart` |
| v1.2.1 | GAP fixes: `/health` → `/healthz` probe, codex-perf-check/check-update gateway restart stubs, SKILL.md docker equivalents |
| v1.2.2 | GAP improvements: TTY-aware `-i`/`-it` in wrapper, `gateway_restart &` → foreground + `sleep 20`, heal.sh polls `gateway_healthy()` for 30s |
| v1.2.3 | Live-install GAP: heal.sh `*.json` → `*.jsonl` session globs, session-purge trajectory UUID fix, session-monitor excludes `*.trajectory.jsonl` |
| v1.2.5 | `docker compose -C` → `--project-directory` (8 sites were broken at runtime), heal.sh loop check parses JSONL line-by-line, health-check.sh gains `container` target kind with Docker-aware defaults, +5 tests (37) |
| v1.2.6 | v2026.5+ GAP: version-gate removed `tools.exec.*` config paths in heal.sh and check-update.sh; fix snapshot fields (`maxConcurrent`, `model.primary`); update cli-reference.md, +2 tests (39) |
| v1.2.7 | Discord notifications: 9 existing `send_notification` call sites routed to Discord via `_discord_send`; per-user `~/.openclaw/discord-channels.json`; ANSI color blocks; `config/discord-channels.example.json` shipped in repo; +2 tests (41) |
| v1.2.8 | Discord message style: only the alert label is colored; verbose details render in default channel color. `_discord_ansi` accepts optional `detail` argument; all 9 call sites updated |
| v1.2.9 | `security-scan.sh`: `gateway.bind=lan` treated as accepted warning (no score deduction); `~/.openclaw/.env` with chmod 600 approved as active runtime secret exception; config path now expands `$OPENCLAW_HOME` as well as `~` |

## Running tests

```bash
bash tests/run.sh
```

41 tests, 0 shellcheck warnings.

## Claude Code

A [`CLAUDE.md`](CLAUDE.md) is included for use with [Claude Code](https://claude.ai/code). It covers commands, deployment model, the single-owner restart policy, lib.sh patterns, test structure, and bash style conventions.

## Open-Source Release Checklist

- Remove any local `~/.openclaw` state, logs, or example outputs from the repository.
- Do not publish screenshots or pasted scan output that contain real tokens, session material, or private channel identifiers.
- Keep examples generic: placeholder tokens, placeholder user IDs, and non-sensitive hostnames only.
- Run `bash tests/run.sh` before publishing changes.
