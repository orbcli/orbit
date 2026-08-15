#!/usr/bin/env bash
# Orbit Qoder SessionStart hook (resume | compact matcher) — inject the
# cruise block. Same JSON-wrapping contract as qoder/session-start.sh (the
# event is still SessionStart; only the matcher differs), delegating to the
# shared session-resume.sh.
set -euo pipefail

PARENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Map qoder's native project-dir env onto the claude-contract name the shared
# script anchors on (Qoder CLI documents only QODER_PROJECT_DIR; the IDE
# double-injects both). No-op when the compat alias is already set.
export CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${QODER_PROJECT_DIR:-}}"

if ! out=$(bash "$PARENT_DIR/session-resume.sh"); then
  exit 0
fi
[ -n "$out" ] || exit 0

# Minimal JSON string encoding: orbit's payloads are self-produced markdown.
# Escape the five named controls (backslash, double-quote, CR, LF, TAB) and
# strip the remaining C0/DEL bytes outright — they never legitimately occur
# in plain text, and literal C0 in a JSON string is invalid.
es=$(printf '%s' "$out" | tr -d '\000-\010\013\014\016-\037\177')
es=${es//\\/\\\\}
es=${es//\"/\\\"}
es=${es//$'\r'/\\r}
es=${es//$'\n'/\\n}
es=${es//$'\t'/\\t}
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$es"
