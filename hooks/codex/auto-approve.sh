#!/usr/bin/env bash
# Orbit Codex PermissionRequest hook — auto-approve safe orbit commands.
#
# Codex PermissionRequest hooks use exit codes: 0 = allow, non-zero = prompt.
# This wraps the shared auto-approve logic: it runs the same checks and
# exits 0 only when the command is a safe orbit invocation.
#
# Fail-safe by construction: if anything goes wrong, exit non-zero so the
# normal permission prompt happens.
set -euo pipefail

# Shared auto-approve logic is in the parent directory.
PARENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Run the shared auto-approve.sh. It reads stdin, checks the command,
# and prints a JSON allow decision on stdout when it matches.
result=$(bash "$PARENT_DIR/auto-approve.sh" 2>/dev/null) || exit 1

# If the shared script emitted an allow decision, grant permission.
if echo "$result" | grep -q '"permissionDecision":"allow"'; then
  exit 0
fi

# Otherwise, fall through to the normal prompt.
exit 1
