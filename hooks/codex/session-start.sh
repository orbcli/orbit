#!/usr/bin/env bash
# Orbit Codex SessionStart hook — inject workspace context.
#
# Delegates to the shared session-start.sh which detects workspace status
# and injects the appropriate context block (prime or resume).
# Stdout is injected into the model's context.
set -euo pipefail

PARENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$PARENT_DIR/session-start.sh"
