#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools python3 || exit 1

AGENTS_DIR="${OPENCLAW_AGENTS_DIR:-$HOME/.openclaw/agents}"
SESSION_FILE="${1:-}"
SUMMARY_ONLY=0
TOOLS_ONLY=0
LAST_COUNT=0
RAW_OUTPUT=0
AGENT_NAME=""

usage() {
  cat <<'USAGE'
Usage: scripts/session-resume.sh <session-file|--agent <name>> [--summary] [--tools-only] [--last N] [--raw]

  <session-file>    Path to a session .jsonl file
  --agent <name>    Auto-find the most recent session for the named agent
  --summary         Print only the compaction context and stats
  --tools-only      Print only tool call / tool result activity
  --last N          Print only the last N user/assistant messages
  --raw             Skip secret redaction
USAGE
}

# Allow --agent as the first argument in place of a file path
if [[ "${SESSION_FILE:-}" == "--agent" ]]; then
  AGENT_NAME="${2:-}"
  SESSION_FILE=""
  shift 2 || true
elif [[ -z "$SESSION_FILE" ]]; then
  usage >&2
  exit 1
else
  shift || true
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)
      AGENT_NAME="${2:-}"
      if [[ -z "$AGENT_NAME" ]]; then
        printf 'Error: --agent requires a name argument\n' >&2
        exit 1
      fi
      shift 2
      ;;
    --summary)
      SUMMARY_ONLY=1
      shift
      ;;
    --tools-only)
      TOOLS_ONLY=1
      shift
      ;;
    --last)
      LAST_COUNT="${2:-0}"
      shift 2
      ;;
    --raw)
      RAW_OUTPUT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Auto-discover latest session for --agent <name>
if [[ -n "$AGENT_NAME" ]]; then
  AGENT_SESSIONS_DIR="$AGENTS_DIR/$AGENT_NAME/sessions"
  if [[ ! -d "$AGENT_SESSIONS_DIR" ]]; then
    printf 'Error: sessions directory not found: %s\n' "$AGENT_SESSIONS_DIR" >&2
    exit 1
  fi
  # Python: find the most recently modified .jsonl — portable across Linux and macOS
  SESSION_FILE="$(python3 - "$AGENT_SESSIONS_DIR" <<'PY'
import os
import sys

sessions_dir = sys.argv[1]
best = None
best_mtime = -1
try:
    for entry in os.scandir(sessions_dir):
        if entry.name.endswith(".jsonl") and entry.is_file(follow_symlinks=False):
            mtime = entry.stat().st_mtime
            if mtime > best_mtime:
                best_mtime = mtime
                best = entry.path
except Exception:
    pass
if best:
    print(best)
PY
)"
  if [[ -z "$SESSION_FILE" ]]; then
    printf 'No session files found for agent: %s\n' "$AGENT_NAME" >&2
    exit 1
  fi
  printf 'Using session: %s\n' "$SESSION_FILE" >&2
fi

if [[ -z "$SESSION_FILE" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -f "$SESSION_FILE" ]]; then
  printf 'Session file not found: %s\n' "$SESSION_FILE" >&2
  exit 1
fi

result="$(
  python3 - "$SESSION_FILE" "$SUMMARY_ONLY" "$TOOLS_ONLY" "$LAST_COUNT" <<'PY'
import json
import os
import re
import sys

path = sys.argv[1]
summary_only = sys.argv[2] == "1"
tools_only = sys.argv[3] == "1"
last_count = int(sys.argv[4])

failure_pattern = re.compile(r"error:|failed|traceback|permission denied|exit code|unable to|cannot proceed|i apologize", re.IGNORECASE)


def shorten(text, limit=800):
    text = (text or "").strip()
    if len(text) <= limit:
        return text
    return text[: limit - 3].rstrip() + "..."


def message_text(message):
    chunks = []
    for item in message.get("content", []) or []:
        item_type = item.get("type")
        if item_type in {"thinking", "thinkingSignature"}:
            continue
        if item_type == "text" and item.get("text"):
            chunks.append(item["text"])
        elif item_type == "toolCall":
            name = item.get("name") or item.get("toolName") or "unknown"
            chunks.append(f"toolCall {name}")
    return "\n".join(chunks).strip()


header = {}
compactions = []
messages = []
tool_calls = 0
tool_results = 0
error_results = 0

with open(path, "r", encoding="utf-8", errors="replace") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except Exception:
            continue

        record_type = record.get("type")
        if record_type == "session" and not header:
            header = record
        elif record_type == "compaction":
            summary = record.get("summary")
            if summary:
                compactions.append(summary.strip())
        elif record_type == "message":
            message = record.get("message", {})
            role = message.get("role", "unknown")
            text = message_text(message)
            timestamp = record.get("timestamp") or message.get("timestamp") or ""
            messages.append(
                {
                    "role": role,
                    "timestamp": timestamp,
                    "text": text,
                    "message": message,
                }
            )
            if role == "assistant":
                for item in message.get("content", []) or []:
                    if item.get("type") == "toolCall":
                        tool_calls += 1
            elif role == "toolResult":
                tool_results += 1
                if message.get("isError") or (message.get("details") or {}).get("status") == "failed" or failure_pattern.search(text):
                    error_results += 1

session_id = header.get("id") or os.path.basename(path)
started = header.get("timestamp", "")
cwd = header.get("cwd", "")
model = header.get("model", "unknown")
compaction_text = "\n\n".join(compactions) if compactions else "No compaction records found."

recent_pairs = []
if not tools_only:
    text_messages = [m for m in messages if m["role"] in {"user", "assistant"} and m["text"]]
    if last_count > 0:
        text_messages = text_messages[-last_count:]
        for item in text_messages:
            label = "User" if item["role"] == "user" else "Assistant"
            recent_pairs.append(f"**{label}:** {shorten(item['text'])}")
    else:
        pairs = []
        current_user = None
        for item in text_messages:
            if item["role"] == "user":
                current_user = item
            elif item["role"] == "assistant" and current_user is not None:
                pairs.append((current_user, item))
                current_user = None
        for user_msg, assistant_msg in pairs[-5:]:
            recent_pairs.append(f"**User:** {shorten(user_msg['text'])}")
            recent_pairs.append(f"**Assistant:** {shorten(assistant_msg['text'])}")

failure_point = ""
for item in reversed(messages[-20:]):
    if failure_pattern.search(item["text"]):
        role_label = "Tool" if item["role"] == "toolResult" else item["role"].capitalize()
        failure_point = f"**{role_label}:** {shorten(item['text'])}"
        break

stats = [
    f"- Messages: {len(messages)}",
    f"- Tool calls: {tool_calls}",
    f"- Tool results: {tool_results}",
    f"- Error results: {error_results}",
]

if tools_only:
    lines = [
        f"## Session Resume: {session_id}",
        "",
        "### Tool Activity",
    ]
    for item in messages:
        if item["role"] not in {"assistant", "toolResult"}:
            continue
        if not item["text"]:
            continue
        label = "Assistant" if item["role"] == "assistant" else "Tool"
        lines.append(f"**{label}:** {shorten(item['text'])}")
    print("\n".join(lines))
    raise SystemExit(0)

lines = [
    f"## Session Resume: {session_id}",
    f"**Started:** {started} | **Model:** {model} | **CWD:** {cwd}",
    "",
    "### Session Context (from compaction)",
    compaction_text,
]

if not summary_only:
    lines.extend(
        [
            "",
            "### Recent Exchange",
            "\n".join(recent_pairs) if recent_pairs else "No recent user/assistant exchange found.",
            "",
            "### Point of Failure",
            failure_point or "No failure signals detected in the last 20 messages.",
        ]
    )

lines.extend(
    [
        "",
        "### Stats",
        "\n".join(stats),
    ]
)

print("\n".join(lines))
PY
)"

# Sanitize secrets unless --raw was passed
if [[ "$RAW_OUTPUT" -eq 0 ]]; then
  result="$(printf '%s\n' "$result" | sanitize_sensitive)"
fi

# Auto-pager: pipe through $PAGER (or less -R) when stdout is a terminal.
# Skipped when output is redirected or piped — plain text is fine there.
if [[ -t 1 && "$RAW_OUTPUT" -eq 0 ]]; then
  pager="${PAGER:-}"
  if [[ -z "$pager" ]] && command -v less &>/dev/null; then
    pager="less -R"
  fi
  if [[ -n "$pager" ]]; then
    printf '%s\n' "$result" | $pager
    exit 0
  fi
fi

printf '%s\n' "$result"
