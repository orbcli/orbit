#!/usr/bin/env bash
# Orbit SessionStart hook (resume / compact matcher).
# Thin wrapper: injects the cruise block from bare `orbit context`
# (cheap durables + conditional per-repo status), wrapped in <orbit-context>
# tags so the agent can tell hook-injected context from self-invoked output.
# Silent no-op when orbit is missing or CWD is not in a workspace (bare
# `orbit context` fails fast in both cases).

command -v orbit >/dev/null 2>&1 || exit 0

if out=$(orbit context 2>/dev/null) && [ -n "$out" ]; then
  printf '<orbit-context>\n%s\n</orbit-context>\n' "$out"
fi
exit 0
