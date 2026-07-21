#!/usr/bin/env bash
# Orbit Codex SessionStart hook (resume | clear | compact matcher).
#
# Delegates to the shared session-resume.sh which injects the cruise block
# block (cheap durables + conditional per-repo status).
# Stdout is injected into the model's context.
set -euo pipefail

PARENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$PARENT_DIR/session-resume.sh"
