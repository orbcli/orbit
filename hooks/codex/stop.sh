#!/usr/bin/env bash
# Orbit Codex Stop hook — nudge the agent to memo-ize no/low-memo repos.
#
# Delegates to the shared stop.sh but strips the Claude/Qoder-specific
# JSON decision format, leaving only the plain-text nudge for the agent.
set -euo pipefail

PARENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Run the shared stop.sh. Capture its output (the JSON block decision).
output=$(bash "$PARENT_DIR/stop.sh" 2>/dev/null) || exit 0

# If the shared script emitted a block decision, extract the reason and
# print it as plain text so the agent sees the nudge.
if echo "$output" | grep -q '"decision":"block"'; then
  reason=$(echo "$output" | jq -r '.reason // empty' 2>/dev/null || true)
  if [ -n "$reason" ]; then
    printf '%s\n' "$reason"
  fi
fi
exit 0
