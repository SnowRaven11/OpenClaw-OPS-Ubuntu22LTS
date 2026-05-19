#!/usr/bin/env bash
# workspace-git-audit.sh — audit OpenClaw workspace git safety coverage.
#
# Checks that the main workspace and known per-agent workspaces are git repos,
# reports dirty/untracked files, verifies auto-commit cron coverage, and can
# print cron setup commands that use workspace-auto-commit.sh.

set -euo pipefail

command -v git >/dev/null 2>&1 || { printf 'Missing required tool: git\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'Missing required tool: python3\n' >&2; exit 1; }

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
MAIN_WORKSPACE="${OPENCLAW_WORKSPACE_ROOT:-$OPENCLAW_HOME/workspace}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_COMMIT_SCRIPT="$SCRIPT_DIR/workspace-auto-commit.sh"

json=0
strict=0
show_cron=0
paths=()

usage() {
  cat <<'EOF'
Usage: workspace-git-audit.sh [--json] [--strict] [--show-cron] [--path PATH ...]

Audits git coverage for OpenClaw workspaces:
- confirms each workspace is a git repo
- reports dirty/untracked file counts
- checks cron jobs for an auto-commit payload referencing each repo path
- optionally prints openclaw cron add commands for missing coverage

By default it checks ~/.openclaw/workspace and every ~/.openclaw/workspace-* dir.
--strict exits non-zero when any workspace is dirty or lacks cron coverage.
--show-cron prints suggested cron add commands for uncovered repos.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) json=1; shift ;;
    --strict) strict=1; shift ;;
    --show-cron) show_cron=1; shift ;;
    --path)
      [[ $# -ge 2 ]] || { echo "--path requires a value" >&2; exit 2; }
      paths+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

expand_path() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    ~/*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

if [[ ${#paths[@]} -eq 0 ]]; then
  paths+=("$MAIN_WORKSPACE")
  while IFS= read -r -d '' p; do
    paths+=("$p")
  done < <(find "$OPENCLAW_HOME" -maxdepth 1 -type d -name 'workspace-*' -print0 2>/dev/null | sort -z)
fi

cron_text=""
if command -v openclaw >/dev/null 2>&1; then
  cron_text="$(openclaw cron list --all --json 2>/dev/null || openclaw cron list --json 2>/dev/null || true)"
fi

workspace_slug() {
  local path="$1"
  local base
  base="$(basename "$path")"
  if [[ "$base" == "workspace" ]]; then
    printf 'workspace'
  else
    printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
  fi
}

shell_join() {
  python3 - "$@" <<'PY'
import shlex
import sys

print(shlex.join(sys.argv[1:]))
PY
}

cron_covers_path() {
  local cron_json="$1"
  local path="$2"
  [[ -n "$cron_json" ]] || return 1

  printf '%s' "$cron_json" | python3 -c '
import json
import sys

path = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)

if isinstance(payload, list):
    jobs = payload
elif isinstance(payload, dict):
    jobs = payload.get("jobs", payload.get("crons", []))
else:
    jobs = []

for job in jobs:
    haystack = json.dumps(job, ensure_ascii=False)
    if path in haystack and (
        "workspace-auto-commit.sh" in haystack or "git commit" in haystack
    ):
        sys.exit(0)

sys.exit(1)
' "$path"
}

print_cron_suggestion() {
  local path="$1"
  local slug="$2"
  local minute="$3"
  local script="$AUTO_COMMIT_SCRIPT"
  local exec_command
  local bash_command
  local message
  local cron_expr
  local cron_command

  exec_command="$(shell_join "$script" --workspace "$path" --label "$slug")"
  bash_command="$(shell_join bash -l -c "$exec_command")"
  message="$(printf 'Run local git auto-commit for %s. Use exactly one exec call: %s. Output exactly NO_REPLY regardless of result.' "$path" "$bash_command")"
  cron_expr="${minute} * * * *"
  cron_command="$(shell_join openclaw cron add --name "${slug}-auto-commit" --cron "$cron_expr" --session isolated --no-deliver --light-context --timeout-seconds 120 --message "$message")"

  cat <<EOF

Suggested cron for $path:
$cron_command
EOF
}

status=0
idx=0
if [[ "$json" -eq 1 ]]; then
  printf '['
fi
first=1

for path in "${paths[@]}"; do
  expanded="$(expand_path "$path")"
  exists=0; is_repo=0; dirty_count=""; last_commit=""; cron_covered=0
  slug="$(workspace_slug "$expanded")"
  minute=$(( (idx * 5) % 60 ))
  idx=$((idx + 1))

  [[ -d "$expanded" ]] && exists=1
  if [[ "$exists" -eq 1 ]] && git -C "$expanded" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    is_repo=1
    dirty_count="$(git -C "$expanded" status --short --untracked-files=all | wc -l | tr -d ' ')"
    last_commit="$(git -C "$expanded" log -1 --pretty='%h %ad %s' --date='format:%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || true)"
  fi
  if cron_covers_path "$cron_text" "$expanded"; then
    cron_covered=1
  fi

  if [[ "$exists" -ne 1 || "$is_repo" -ne 1 ]]; then
    status=1
  fi
  if [[ "$strict" -eq 1 && "$cron_covered" != "1" ]]; then
    status=1
  fi
  if [[ "$strict" -eq 1 && "${dirty_count:-0}" != "0" ]]; then
    status=1
  fi

  if [[ "$json" -eq 1 ]]; then
    [[ "$first" -eq 0 ]] && printf ','
    first=0
    python3 - "$expanded" "$exists" "$is_repo" "${dirty_count:-}" "$cron_covered" "$last_commit" <<'PY'
import json, sys
path, exists, is_repo, dirty_count, cron_covered, last_commit = sys.argv[1:]
print(json.dumps({
  "path": path,
  "exists": exists == "1",
  "is_git_repo": is_repo == "1",
  "dirty_count": None if dirty_count == "" else int(dirty_count),
  "auto_commit_cron_covered": cron_covered == "1",
  "last_commit": last_commit or None,
}, ensure_ascii=False), end="")
PY
  else
    echo "Workspace: $expanded"
    echo "  exists: $exists"
    echo "  git repo: $is_repo"
    [[ -n "$dirty_count" ]] && echo "  dirty files: $dirty_count"
    [[ -n "$last_commit" ]] && echo "  last commit: $last_commit"
    echo "  auto-commit cron covered: $cron_covered"
    if [[ "$show_cron" -eq 1 && "$exists" -eq 1 && "$is_repo" -eq 1 && "$cron_covered" -ne 1 ]]; then
      print_cron_suggestion "$expanded" "$slug" "$minute"
    fi
  fi
done

if [[ "$json" -eq 1 ]]; then
  printf ']\n'
fi

exit "$status"
