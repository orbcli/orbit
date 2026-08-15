#!/usr/bin/env bash
# Orbit Qoder SessionStart hook (startup matcher) — inject workspace context.
#
# Qoder's IDE parses hook stdout strictly as JSON and silently drops bare
# text; the CLI accepts both (plain-text fallback). To serve both entry
# points with one registration, this wrapper runs the shared session-start.sh
# and re-encodes its stdout as hookSpecificOutput.additionalContext JSON —
# hookEventName is required, or the whole output is rejected. Stdin passes
# through to the shared script untouched; stderr stays the diagnostic
# channel. Empty shared output stays a silent no-op (no JSON emitted).
set -euo pipefail

PARENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Map qoder's native project-dir env onto the claude-contract name the shared
# script anchors on (Qoder CLI documents only QODER_PROJECT_DIR; the IDE
# double-injects both). No-op when the compat alias is already set.
export CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${QODER_PROJECT_DIR:-}}"

if ! out=$(bash "$PARENT_DIR/session-start.sh"); then
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
