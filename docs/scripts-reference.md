# Scripts Reference

Reference for every script under `scripts/`. Each entry covers purpose, when to use it, usage, what it produces (output and side effects), and notable gotchas.

For the **OpenClaw CLI** itself (`openclaw config`, `openclaw cron`, etc.), see [`cli-reference.md`](cli-reference.md). For the **single-owner restart policy** and other architecture decisions, see [`architecture.md`](architecture.md).

> All scripts target Ubuntu 22 LTS with the OpenClaw gateway running in Docker Compose. They share helpers from `lib.sh` (Docker introspection, port resolution, notifications, sanitization). Run any script with `--help` for its inline usage.

---

## Table of contents

| Group | Scripts |
|---|---|
| **Install & setup** | [`install-cli-wrapper.sh`](#install-cli-wrappersh), [`watchdog-install.sh`](#watchdog-installsh), [`watchdog-uninstall.sh`](#watchdog-uninstallsh) |
| **Always-on monitoring** | [`watchdog.sh`](#watchdogsh), [`session-monitor.sh`](#session-monitorsh), [`log-rotate.sh`](#log-rotatesh) |
| **One-shot recovery** | [`heal.sh`](#healsh), [`post-update.sh`](#post-updatesh), [`check-update.sh`](#check-updatesh) |
| **Declarative checks** | [`health-check.sh`](#health-checksh), [`security-scan.sh`](#security-scansh) |
| **Performance tuning** | [`codex-perf-check.sh`](#codex-perf-checksh) |
| **Cron management** | [`cron-error-inspector.sh`](#cron-error-inspectorsh), [`cron-optimize.sh`](#cron-optimizesh) |
| **Sessions & transcripts** | [`session-purge.sh`](#session-purgesh), [`session-search.sh`](#session-searchsh), [`session-resume.sh`](#session-resumesh), [`prompt-truncation-report.sh`](#prompt-truncation-reportsh) |
| **Workspace (git safety)** | [`workspace-auto-commit.sh`](#workspace-auto-commitsh), [`workspace-git-audit.sh`](#workspace-git-auditsh) |
| **Reporting & triage** | [`daily-digest.sh`](#daily-digestsh), [`incident-manager.sh`](#incident-managersh), [`remediation-board.sh`](#remediation-boardsh) |
| **Audits & housekeeping** | [`agent-dirs-audit.sh`](#agent-dirs-auditsh), [`context-audit.sh`](#context-auditsh), [`backup-rotate.sh`](#backup-rotatesh), [`skill-audit.sh`](#skill-auditsh) |
| **Shared library** | [`lib.sh`](#libsh) |

---

## Install & setup

These are one-time setup steps you run once per machine.

### `install-cli-wrapper.sh`

**Purpose:** On Docker Compose deployments, OpenClaw runs inside containers — there is no `openclaw` binary on the host. This script generates `~/.local/bin/openclaw`, a wrapper that routes:
- `openclaw gateway restart/start/stop` → `docker compose --project-directory $STACK_DIR ...`
- everything else → `docker exec -i/-it $CLI_CONTAINER node dist/index.js "$@"` (TTY-detected: `-it` for interactive shells, `-i` for scripted calls)

**When to use:** First-time setup on a Docker Compose host; re-run after the gateway/CLI container names change.

**Usage:**
```bash
bash scripts/install-cli-wrapper.sh
# or with explicit overrides:
bash scripts/install-cli-wrapper.sh \
  --stack-dir /srv/openclaw/openclaw \
  --gateway-container openclaw-openclaw-gateway-1 \
  --cli-container openclaw-openclaw-cli-1
```

**Produces:**
- `~/.local/bin/openclaw` (the wrapper)
- `~/.openclaw/ops-config.sh` — sourced automatically by `lib.sh` so every other script in this repo picks up the same stack dir and container names

**Gotchas:**
- `~/.local/bin` must be on `$PATH` — the script prints a reminder if it isn't.
- If `docker` is not in `$PATH`, the wrapper installs successfully but every call fails at runtime. Install Docker first.
- Site-specific overrides written to `ops-config.sh` win over the lib.sh defaults of `OPENCLAW_STACK_DIR=/srv/openclaw/openclaw`, `OPENCLAW_GATEWAY_CONTAINER=openclaw-openclaw-gateway-1`, `OPENCLAW_CLI_CONTAINER=openclaw-openclaw-cli-1`.

---

### `watchdog-install.sh`

**Purpose:** Install [`watchdog.sh`](#watchdogsh) as a systemd user timer that fires every 5 minutes. Also installs a daily `log-rotate.sh` cron entry. Falls back to a 5-minute crontab entry if systemd user sessions are unavailable.

**When to use:** Once after cloning the repo, on any machine where you want hands-off gateway recovery.

**Usage:**
```bash
bash scripts/watchdog-install.sh
```

**Produces:**
- `~/.config/systemd/user/openclaw-watchdog.service` (oneshot)
- `~/.config/systemd/user/openclaw-watchdog.timer` (`OnCalendar=*:0/5`, `Persistent=true`)
- Daily crontab entry: `@daily bash $SCRIPTS_DIR/log-rotate.sh`
- Enables `loginctl enable-linger $USER` so the timer survives reboots without a login session

**Gotchas:**
- Cron-fallback installs use `*/5 * * * * bash $SCRIPTS_DIR/watchdog.sh >> $LOG_DIR/watchdog.log 2>&1`.
- After install, verify the timer is active: `systemctl --user status openclaw-watchdog.timer`.
- If `openclaw` is not on `$PATH`, the script reminds you to run `install-cli-wrapper.sh`.

---

### `watchdog-uninstall.sh`

**Purpose:** Cleanly remove the watchdog — systemd units, the crontab entry, the log-rotate cron entry.

**When to use:** Decommissioning the watchdog on a host, or before reinstalling from a different repo location.

**Usage:**
```bash
bash scripts/watchdog-uninstall.sh
```

**Side effects:** Stops/disables the timer and service, removes the unit files, strips the `# openclaw-watchdog` and `log-rotate.sh` lines from your crontab. State files in `~/.openclaw/` are left in place.

---

## Always-on monitoring

These run continuously once installed. You normally don't invoke them by hand.

### `watchdog.sh`

**Purpose:** The single owner of gateway recovery. On each tick:
1. HTTP `/healthz` probe with a 15s timeout. If `200` or `401`, gateway is up.
2. If `200`, also runs an **agent-layer log probe** (`check_agent_layer_health`) — scans `gateway.err.log` for known failure patterns that leave HTTP healthy but agents dead (codex app-server hangs, harness failures, provider config errors, stuck sessions).
3. If the gateway is down, enforces a warmup grace (`GATEWAY_WARMUP_GRACE=120s`), requires two consecutive health failures within 10 minutes (`REQUIRED_HEALTH_FAILURES=2`), and rate-limits restarts (`MAX_RESTART_ATTEMPTS=3` per `RESTART_ATTEMPT_WINDOW=900s`).
4. Recovery: `docker compose --project-directory $STACK_DIR restart openclaw-gateway` (via `_docker_compose_restart`). If a simple restart fails, escalates to [`heal.sh`](#healsh).
5. Throttled session-monitor invocation (`SESSION_MONITOR_THROTTLE=600s`) — runs a session anomaly scan no more than once every 10 minutes.

**When to use:** Installed by [`watchdog-install.sh`](#watchdog-installsh). You can also run a single tick manually for diagnosis: `bash scripts/watchdog.sh`.

**Produces:**
- `~/.openclaw/logs/watchdog.log` (trimmed to last 500 lines on each run)
- `~/.openclaw/watchdog-state.json` (restart-attempt window, health-failure window, version tracking)
- `~/.openclaw/watchdog.lock/` (mkdir-style mutex with 15-min stale-lock recovery)
- `send_notification()` warnings on escalation (journald via `systemd-cat`, plus `notify-send` if a display is present)

**Gotchas:**
- **Single-owner policy:** no other script in this repo should call `openclaw gateway restart` or `docker compose restart openclaw-gateway`. See [`architecture.md`](architecture.md).
- The agent-layer probe dedupes by timestamp-second so a single real failure (which emits 4–5 log lines across loggers) counts as one incident, not four.
- Health endpoint is `/healthz` (not `/health`); both currently return JSON on v2026.5.x but only `/healthz` is the documented contract.

---

### `session-monitor.sh`

**Purpose:** Behavioral anomaly detector that reads session JSONL transcripts and emits `incident_report` events for retry loops, dead runs, stuck runs, auth errors, and error clusters. Designed to run from the watchdog on a 10-minute throttle, but can be invoked directly.

**When to use:**
- Triggered automatically by [`watchdog.sh`](#watchdogsh).
- Manual scan: `bash scripts/session-monitor.sh --verbose --force`.
- Scan one agent only: `bash scripts/session-monitor.sh --agent argos`.

**Detections (current heuristics):**
| Anomaly | Trigger |
|---|---|
| `retry-loop` | same tool returns an error ≥ 5 times in a row |
| `dead-run` | session header > 10 min old, last activity > 30 min ago, < 2 meaningful assistant messages |
| `stuck-run` | file mtime within 24 h, last activity > 30 min ago, ≥ 1 meaningful assistant message |
| `auth-error` | regex match for `401|403|unauthorized|forbidden|token expired` |
| `error-cluster` | ≥ 4 error-looking lines in one session |

**Produces:**
- `~/.openclaw/session-monitor/latest.json` (incremental scan summary)
- Incident records via [`incident-manager.sh`](#incident-managersh) (lifecycle in `~/.openclaw/logs/incidents-state.json`)
- `send_notification` + `openclaw system event --mode now` on critical severity (unless `--no-alert`)

**Gotchas:**
- Excludes `*.trajectory.jsonl` files (Codex rollout logs with a different schema; would just waste I/O).
- Uses `xargs -0 -n1 -P4` for parallel analysis; the dispatch is wrapped in `|| true` so a single corrupt file can't abort the whole scan under `set -euo pipefail`.
- Reads `mtime` of `~/.openclaw/session-monitor.lastrun` to skip files unchanged since the previous scan; pass `--force` to override.

---

### `log-rotate.sh`

**Purpose:** Rotate `~/.openclaw/logs/*.log` and `*.jsonl` daily so logs don't grow unbounded. Generates a logrotate config at runtime from `$HOME` and runs `logrotate --state` with a per-user state file — no system `/etc/logrotate.d/` config required. Uses `copytruncate` for `gateway.err.log` (which the gateway process holds open continuously).

**When to use:** Installed as `@daily` cron by [`watchdog-install.sh`](#watchdog-installsh). Manual run: `bash scripts/log-rotate.sh`.

**Configurable via env:**
- `OPENCLAW_LOG_DIR` (default `~/.openclaw/logs`)
- `OPENCLAW_LOGROTATE_STATE` (default `~/.local/share/openclaw-logrotate.state`)
- `OPENCLAW_LOGROTATE_KEEP` (default `14`)

---

## One-shot recovery

These you run interactively when something's wrong or after an update.

### `heal.sh`

**Purpose:** Auto-fix the most common gateway breakages in one pass. Step list:

| Step | Action |
|---|---|
| `[0]` | Version check (minimum v2026.2.12 — older has critical CVEs); detect version change since last run |
| `[1]` | Gateway start if container not running; poll `gateway_healthy()` up to 30 s |
| `[2]` | Auth mode check — replace `gateway.auth.mode=none` (removed in v2026.1.29) with `token` + new random token |
| `[3]` | Exec approvals — patch `exec-approvals.json` `defaults` block (`security=full`, `ask=off`, `askFallback=full`), add wildcard allowlist for any empty-allowlist agents, set `tools.exec.security=full` and `tools.exec.strictInlineEval=false` |
| `[4]` | Re-enable any auto-disabled cron jobs |
| `[5]` | Stuck-session check — archive any session JSONL larger than 10 MB; detect rapid-fire content loops (≥ 10 identical assistant messages in the last 20) and reset the session pointer |
| `[6]` | Restart gateway if any step made changes |
| `[7]` | Run `openclaw doctor` |

**Usage:**
```bash
bash scripts/heal.sh
```

**Produces:**
- Console output with `[FIXED]`, `[BROKEN]`, `[MANUAL]` lines
- Appends one record per run to `~/.openclaw/logs/heal-incidents.jsonl`
- `send_notification` on `Self-healed N item(s)` or `N item(s) still broken`

**Gotchas:**
- Requires the `openclaw` binary (host CLI wrapper from [`install-cli-wrapper.sh`](#install-cli-wrappersh) on Docker installs).
- Restarts the gateway at most once per run; relies on the watchdog's rate limit when called via escalation.
- Session loop detection parses JSONL line-by-line (fixed in v1.2.5 — earlier versions used `json.load` on a JSONL file and silently never fired).

---

### `post-update.sh`

**Purpose:** Run the canonical post-update sequence in order:
1. `check-update.sh --fix`
2. `heal.sh`
3. workspace reconcile script (if `OPENCLAW_POST_UPDATE_RECONCILE_SCRIPT` exists)
4. `security-scan.sh`
5. `openclaw health --json`

Touches a sentinel file (`~/.openclaw/state/policy-guard.trigger`) at the end that an in-band policy guard can wire `openclaw-policy-guard.path` to. Idempotent — exits immediately if the current version matches the stored watchdog state and no version change is pending.

**When to use:** After every `openclaw update`. Can be wired into an update wrapper or `openclaw update`'s post-hook.

**Usage:**
```bash
bash scripts/post-update.sh
```

**Gotchas:**
- Exports `OPENCLAW_SKIP_WRAPPER_BACKUP=1` so nested `openclaw` calls don't trigger backup loops.
- Set `OPENCLAW_POST_UPDATE_RECONCILE_SCRIPT` and `OPENCLAW_POST_UPDATE_RECONCILE_INTERPRETER` if the reconcile lives outside the default workspace.

---

### `check-update.sh`

**Purpose:** Compare the current OpenClaw version to the last-seen version and walk a table of known breaking changes (auth mode removal, exec policy Layer 2, webhook sessionKey rejection, etc.). In `--fix` mode, applies the safe corrections; otherwise just reports.

**When to use:** After an update, or any time agents start hitting approval walls / silent command failures. The post-update orchestrator calls this first.

**Usage:**
```bash
bash scripts/check-update.sh        # report only
bash scripts/check-update.sh --fix  # report + auto-fix
```

**Produces:**
- Console report with `[✓]` `[!]` `[✗]` `[FIXED]` markers
- Updates `~/.openclaw/watchdog-state.json` with current_version, previous_version, last_update_check
- `send_notification` on `--fix` success or failure summary

**Gotchas:**
- Every `--fix` attempt goes through `try_fix()` which captures stderr and reports real exit codes — earlier versions used `cmd 2>/dev/null && fixed || bad` which lied in the summary when commands failed silently (issue #3).
- Auth-mode token write happens **before** flipping the mode to `token`; if the token write fails the script refuses to flip the mode (otherwise the gateway would require a token it doesn't have).
- Restart hint at the end uses `docker compose --project-directory $STACK_DIR restart openclaw-gateway` (or the wrapper alternative).

---

## Declarative checks

These are read-only or score-based; they don't change config on their own.

### `health-check.sh`

**Purpose:** Run a list of declarative checks against URLs, processes, and Docker containers. Auto-generates a sensible default targets file on first run (Docker-aware: container target on Docker Compose installs, process target otherwise).

**Target file format** (`~/.openclaw/health-targets.conf`, pipe-delimited):
```
url|<name>|<url>|<expected-substring-optional>
process|<name>|<pgrep-pattern>|<min-uptime-seconds-optional>
container|<name>|<docker-container-name>|<min-uptime-seconds-optional>
```

The `container` kind checks `docker inspect .State.Status`, applies a min-uptime threshold, and surfaces the container's own Docker healthcheck (`unhealthy` is reported as failure; `starting` and `none` are tolerated).

**When to use:**
- Manually for a quick health snapshot: `bash scripts/health-check.sh --verbose`.
- As an external probe (Nagios/CronicleHQ/Loki alert) — exits non-zero with `FAIL: ...` lines for any failure.

**Usage:**
```bash
bash scripts/health-check.sh                       # default targets file
bash scripts/health-check.sh -t my-targets.conf    # custom targets
bash scripts/health-check.sh --verbose             # also print OK lines
bash scripts/health-check.sh --no-alert            # don't send openclaw system event
```

**Produces:** Stdout only; sends `openclaw system event --mode now` summary on failure (unless `--no-alert`).

**Gotchas:**
- Auto-generated default URL uses `/healthz` (consistent with the watchdog).
- The container check intentionally treats `starting` health as a pass — Docker healthcheck has a `start_period` during which `starting` is normal.

---

### `security-scan.sh`

**Purpose:** Two-phase compliance + credential scan with a 0–100 score.

**Compliance checks (deducts points):**
| # | Check | Penalty |
|---|---|---|
| 1 | `gateway.bind` is `loopback` / `127.0.0.1` | -20 |
| 2 | `gateway.auth.mode` is `token` / `trusted-proxy` | -15 |
| 3 | `agents.defaults.sandbox.mode` is `all` / `non-main` | -15 |
| 4 | enabled channels have `dmPolicy` of `pairing` / `allowlist` | -15 |
| 5 | `defaults.autoAllowSkills` is `false` | -10 |
| 6 | OpenClaw version ≥ `v2026.2.12` | -20 |
| 7 | `security.trust_model.multi_user_heuristic` is `true` (v2026.2.24+) | -5 |
| 8 | `openclaw-watchdog.timer` is active | -5 |

**Credential scan:** greps config files (`*.json`, `*.jsonl`, `*.yaml`, `*.toml`, `*.env`, `*.service`, `*.ini`, `*.log`, `*.bak*`) for 20+ secret patterns (Anthropic, OpenAI, GitHub, Slack, AWS, Google API, JWT, etc.). Reports redacted location only. Auth/credential stores like `auth-profiles.json` are tagged as "expected secret-shaped values" and not counted as leaks (unless `--include-sessions` is passed for a deep pass). Also enforces `600` permissions on config files and `700` on `~/.openclaw/credentials/`. Systemd unit files and plugin/runtime source files are exempt from the permission check.

**Optional `--drift`:** SHA-256 hashes of every file under `~/.openclaw/skills/` are compared to a baseline at `~/.openclaw/security/skill-hashes.json`. First run creates the baseline; subsequent runs report `[NEW]`, `[MODIFIED]`, `[REMOVED]`.

**Usage:**
```bash
bash scripts/security-scan.sh                # full scan (compliance + credentials)
bash scripts/security-scan.sh --fix          # apply safe permission/config fixes
bash scripts/security-scan.sh --drift        # add skill drift detection
bash scripts/security-scan.sh --credentials  # credentials only
bash scripts/security-scan.sh --include-sessions  # don't skip session/log roots
```

**Exit:** non-zero when score < 80.

---

## Performance tuning

### `codex-perf-check.sh`

**Purpose:** Check and optionally apply four GPT-5.x performance opt-ins that ship disabled by default:
1. `agents.list[].embeddedPi.executionContract = "strict-agentic"`
2. `plugins.entries.openai.config.personality = "friendly"`
3. `agents.defaults.thinkingDefault = "adaptive"` (or `high`)
4. `plugins.entries.codex.enabled = true` + `agents.defaults.embeddedHarness.runtime = "codex"`

Requires OpenClaw v2026.4.x or later; the settings don't exist before that.

**Usage:**
```bash
bash scripts/codex-perf-check.sh         # check only
bash scripts/codex-perf-check.sh --fix   # apply fixes; restarts the gateway via _docker_compose_restart
```

---

## Cron management

### `cron-error-inspector.sh`

**Purpose:** Format `openclaw cron list --all --json` failures as a triage-ready list with agent, schedule, last-error-reason, consecutive-error count, payload preview, and (when applicable) a deterministic hint — currently just "timeout + missing `--light-context`".

**Usage:**
```bash
bash scripts/cron-error-inspector.sh
bash scripts/cron-error-inspector.sh --agent argos
bash scripts/cron-error-inspector.sh --consecutive 3   # only jobs with ≥3 consecutive errors
```

---

### `cron-optimize.sh`

**Purpose:** Audit `agentTurn` cron jobs for the `--light-context` flag, which the docs recommend for cron jobs that don't need full session history (reduces token cost and timeout risk). With `--fix`, calls `openclaw cron edit <id> --light-context [--thinking LEVEL]` on each missing job.

**Usage:**
```bash
bash scripts/cron-optimize.sh                          # report
bash scripts/cron-optimize.sh --fix                    # patch missing jobs
bash scripts/cron-optimize.sh --fix --level medium     # also set thinking level on jobs that don't have one
bash scripts/cron-optimize.sh --agent daedalus         # scope to one agent
```

**Exit:** `0` if everything is optimized (or all fixes succeeded), `1` if missing jobs remain, `2` on script/CLI error.

---

## Sessions & transcripts

### `session-purge.sh`

**Purpose:** Reclaim disk and trim session-context bloat. Three classes of cleanup per agent:
1. **`sessions.json` index entries** older than `--age-days` (default 7); plus orphaned cron entries (cron session IDs no longer in `openclaw cron list`); plus all subagent entries (always ephemeral). Always creates a fresh timestamped `sessions.json.bak-*` before mutating.
2. **Old `sessions.json.bak-*` backups** beyond `--keep-backups` (default 3).
3. **Orphaned `.jsonl` transcripts** whose UUID no longer appears in `sessions.json`, plus all `.jsonl.reset.*` archives. Also removes paired `*.codex-app-server.json` files.

**Usage:**
```bash
bash scripts/session-purge.sh                      # DRY RUN
bash scripts/session-purge.sh --apply              # actually delete
bash scripts/session-purge.sh --agent daedalus --age-days 14 --keep-backups 5 --apply
```

**Gotchas:**
- The UUID extraction uses `${base%%.*}` (fixed in v1.2.3); the previous `${base%%.jsonl*}` form misclassified `uuid.trajectory.jsonl` as `uuid.trajectory`, treating active trajectory files as orphans and deleting them under `--apply`.
- Never touches `credentials/`, agent config, or active `sessions.json` entries.

---

### `session-search.sh`

**Purpose:** Full-text search across all session JSONL transcripts, with role filtering, date range, and secret redaction. Output is hit lines with redacted previews; pass `--json` for structured output suitable for piping.

**Usage:**
```bash
bash scripts/session-search.sh "unauthorized"
bash scripts/session-search.sh "401" --role toolResult --limit 10
bash scripts/session-search.sh "OAuth" --agent argos --since 2026-05-01
bash scripts/session-search.sh "OPENCLAW_GATEWAY_TOKEN" --raw         # disable redaction (be careful)
bash scripts/session-search.sh "abc-[0-9]+" --regex --json
```

**Requires:** `rg` (ripgrep) — `sudo apt-get install ripgrep`.

---

### `session-resume.sh`

**Purpose:** Generate a markdown digest of a single session for hand-off or human review. Compaction-first: it favors the most recent compaction summary plus the last few exchanges and tool-call outcomes, rather than dumping the whole transcript.

**Usage:**
```bash
bash scripts/session-resume.sh ~/.openclaw/agents/daedalus/sessions/<uuid>.jsonl
bash scripts/session-resume.sh --agent argos                      # auto-find most recent session
bash scripts/session-resume.sh <file> --summary                   # compaction context + stats only
bash scripts/session-resume.sh <file> --tools-only                # tool calls/results only
bash scripts/session-resume.sh <file> --last 5                    # last 5 user/assistant messages
bash scripts/session-resume.sh <file> --raw                       # skip the auto-pager
```

**Auto-pager:** pipes through `$PAGER` (or `less -R`) when stdout is a terminal; bypassed when redirected.

---

### `prompt-truncation-report.sh`

**Purpose:** Report bootstrap-prompt truncation warnings from the latest session per agent. Truncation happens when the agent system prompt + injected context (AGENTS.md, MEMORY.md, SOUL*.md) exceeds the model's context budget at session start; the agent loses awareness of facts it should have.

**Usage:**
```bash
bash scripts/prompt-truncation-report.sh           # all agents
bash scripts/prompt-truncation-report.sh --agent argos
bash scripts/prompt-truncation-report.sh --json
```

**Companion:** [`context-audit.sh`](#context-auditsh) for static AGENTS.md/MEMORY.md size auditing.

---

## Workspace (git safety)

### `workspace-auto-commit.sh`

**Purpose:** Deterministic local git snapshots for OpenClaw agent workspaces. Never pushes. Designed to be installed as a cron job so workspace state is always recoverable from local git history.

**Usage:**
```bash
bash scripts/workspace-auto-commit.sh                              # default workspace (~/.openclaw/workspace)
bash scripts/workspace-auto-commit.sh --all                        # all ~/.openclaw/workspace*
bash scripts/workspace-auto-commit.sh --workspace ~/path/to/repo
bash scripts/workspace-auto-commit.sh --dry-run --json
bash scripts/workspace-auto-commit.sh --label nightly --message "scheduled snapshot"
```

---

### `workspace-git-audit.sh`

**Purpose:** Audit the main workspace and known per-agent workspaces (`~/.openclaw/workspace*`) for git status, dirty/untracked counts, and auto-commit cron coverage. `--show-cron` prints the suggested cron-install commands for uncovered repos.

**Usage:**
```bash
bash scripts/workspace-git-audit.sh
bash scripts/workspace-git-audit.sh --json
bash scripts/workspace-git-audit.sh --strict           # exit non-zero on any uncovered repo
bash scripts/workspace-git-audit.sh --show-cron        # print install commands
bash scripts/workspace-git-audit.sh --path ~/some/repo --path ~/other/repo
```

---

## Reporting & triage

### `daily-digest.sh`

**Purpose:** Last-24-hour (configurable) summary of incident counts, per-agent activity (messages / tool calls / errors), watchdog events, and recorded usage cost. Renders text by default; `--html` produces a styled standalone HTML page suitable for email.

**Usage:**
```bash
bash scripts/daily-digest.sh                       # text, 24h window
bash scripts/daily-digest.sh --hours 6
bash scripts/daily-digest.sh --html > digest.html
bash scripts/daily-digest.sh --notify              # also send_notification with first 3 lines
```

**Gotchas:** Output is piped through `sanitize_sensitive` before printing so tokens/keys never leak into a digest.

---

### `incident-manager.sh`

**Purpose:** Shared incident lifecycle helpers (open / acknowledge / mute / resolve / list / status). Used by [`session-monitor.sh`](#session-monitorsh) and is `source`-ed by other scripts; rarely invoked standalone.

**Stored state:**
- `~/.openclaw/logs/incidents-state.json` (current snapshot)
- `~/.openclaw/logs/incidents.jsonl` (append-only history)
- `~/.openclaw/locks/incidents.lock` (mutex)
- `~/.openclaw/incidents-config.json` (per-pattern mute/severity overrides)

---

### `remediation-board.sh`

**Purpose:** Durable triage board for surfaced findings — converts noisy operational hits (cron errors, audit findings) into a tracked queue with a fixed lifecycle:

`open → in-progress → fixed-awaiting-rerun → verified-fixed | deferred | excluded`

Each item carries `id`, `title`, `source`, `evidence`, `next` (next-check instructions), `notes` (timestamped), and `observations` (every time the source re-fires).

**Usage:**
```bash
bash scripts/remediation-board.sh import-cron-errors                 # import from openclaw cron list
bash scripts/remediation-board.sh import-cron-errors --agent argos --consecutive 3
bash scripts/remediation-board.sh add my-id "Title" --source manual --evidence "..." --next "..."
bash scripts/remediation-board.sh set my-id in-progress --note "investigating"
bash scripts/remediation-board.sh set my-id fixed-awaiting-rerun --next "watch next cron tick"
bash scripts/remediation-board.sh close my-id --note "verified fixed"
bash scripts/remediation-board.sh list                               # markdown
bash scripts/remediation-board.sh list --status open --json
bash scripts/remediation-board.sh show my-id
```

**Storage:** `~/.openclaw/remediation-board.json` (override with `--board PATH` or `OPENCLAW_REMEDIATION_BOARD_FILE`).

---

## Audits & housekeeping

### `agent-dirs-audit.sh`

**Purpose:** Audit top-level dirs under `~/.openclaw/agents` that are **not** in `agents.list` (the configured agents). Classifies each unclaimed dir as `EMPTY`, `STALE`, `DORMANT`, or `_archived` and offers two cleanup modes.

**Usage:**
```bash
bash scripts/agent-dirs-audit.sh                  # dry-run report
bash scripts/agent-dirs-audit.sh --archive        # move DORMANT to ~/.openclaw/agents/_archived/YYYY-MM-DD/
bash scripts/agent-dirs-audit.sh --delete-empty   # remove EMPTY dirs
```

---

### `context-audit.sh`

**Purpose:** Static audit of bootstrap-context bloat — scans `AGENTS.md`, `MEMORY.md`, and `SOUL*.md` under `~/.openclaw`, estimates tokens (chars/4), filters above a threshold, sorts largest first. Read-only.

**Usage:**
```bash
bash scripts/context-audit.sh                                       # all agents, threshold 10000 tokens
bash scripts/context-audit.sh --agent argos
bash scripts/context-audit.sh --threshold-tokens 5000 --json
```

**Companion:** [`prompt-truncation-report.sh`](#prompt-truncation-reportsh) for runtime truncation evidence.

---

### `backup-rotate.sh`

**Purpose:** Group `*.bak*` files under `~/.openclaw` by the path prefix before the first `.bak` and keep the newest N per group. Catches the dozens of `openclaw.json.bak-*`, `sessions.json.bak-*`, etc. that accumulate over weeks of edits.

**Usage:**
```bash
bash scripts/backup-rotate.sh                # dry-run, default keep=3
bash scripts/backup-rotate.sh --apply --keep 5
```

---

### `skill-audit.sh`

**Purpose:** Static security audit for a third-party skill **before** installation. Five passes:
1. Hardcoded secrets (Anthropic / OpenAI / GitHub / AWS / Slack / Google / Stripe / private-key patterns)
2. Suspicious network calls (`curl -F`, `curl --post-data`, `curl $(cat …)`, raw-IP requests, pastebin/onion/bit domains)
3. Dangerous shell commands (`chmod 777`, `rm -rf /`, `kill -9 -1`, `/etc/sudoers` writes, `mv … /usr/bin`, `dd of=/dev`)
4. Prompt-injection markers in `.md` / `.txt` (`ignore previous instructions`, `pretend to be`, `reveal password`, etc.)
5. Structure validation (`SKILL.md` present)

**Usage:**
```bash
bash scripts/skill-audit.sh /path/to/some-third-party-skill
```

**Exit:** `0` = LOW risk (no findings), `1` = MEDIUM (1–2), `2` = HIGH (≥ 3).

---

## Shared library

### `lib.sh`

**Purpose:** Sourced by every other script. Not invoked directly. Provides:

| Group | Helpers |
|---|---|
| Colors / logging | `RED/GRN/YLW/CYN/BLD/RST`; `log_fixed/broken/manual/info/ok/warn/error` |
| Python launcher | `python3` shim — resolves a real Python 3 even when Git-Bash-style shims are on PATH |
| Preflight | `require_tools tool ...` — exits 1 with a Docker-aware install hint when `openclaw` is missing |
| Versioning | `get_openclaw_version` (normalizes `vX.Y.Z`), `version_below current minimum` |
| State files | `state_get FILE KEY`, `state_set FILE KEY VALUE` (no shell interpolation in Python) |
| Time | `epoch_now`, `iso_now`, `date_days_ago N` |
| File metadata | `file_mtime`, `file_perms`, `file_size`, `file_sha256` (sha256sum → openssl) |
| Sanitization | `sanitize_sensitive` (stdin filter: API keys / Slack tokens / GH tokens / AWS keys / Bearer tokens / `"password"/"secret"/"token"/"api_key"` JSON fields) |
| Inline Python | `run_python SCRIPT ARGS...` — runs inline Python, surfaces first error line through `log_error` |
| Gateway port | `get_gateway_port` — `OPENCLAW_GATEWAY_PORT` env > `~/.openclaw/openclaw.json` gateway.port > `18789` |
| systemd | `is_systemd_available`, `is_systemd_unit_active UNIT` |
| Docker (gateway) | `_docker_gateway_status`, `_docker_gateway_health`, `_docker_compose_restart`, `_docker_compose_up`, `gateway_running`, `gateway_healthy`, `is_docker_deployment` |
| Docker (generic) | `_docker_container_status NAME`, `_docker_container_health NAME`, `_docker_container_started_at NAME` (used by `health-check.sh` container targets) |
| Notifications | `send_notification TITLE BODY` — journald via `systemd-cat` + `notify-send` when a display is set |

**Config sourcing:** `lib.sh` sources `~/.openclaw/ops-config.sh` (written by `install-cli-wrapper.sh`) so all scripts automatically pick up the local stack dir and container names. Defaults: `/srv/openclaw/openclaw`, `openclaw-openclaw-gateway-1`, `openclaw-openclaw-cli-1`.

**Test override:** When `OPENCLAW_DOCKER_STUBS` points at a sourceable file, lib.sh loads it after defining the docker helpers — tests use this to stub the `_docker_*` functions without needing Docker installed.
