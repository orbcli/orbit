#!/usr/bin/env bash
# Orbit SessionStart hook (resume / compact matcher).
# Thin wrapper: injects the cruise block from bare `orbit context`
# (cheap durables + conditional per-repo status), wrapped in <orbit-context>
# tags so the agent can tell hook-injected context from self-invoked output,
# plus a one-line XML comment hint that re-triggers skill loading (hook-layer
# furniture — the orbit runtime never emits it). Resume/compact means the
# skill CONTENT may be gone from working memory even when the session loaded
# it earlier — a compaction summary can still "remember" the load — so the
# condition is content-in-context, not loaded-this-session.
# Silent no-op when orbit is missing or CWD is not in a workspace (bare
# `orbit context` fails fast in both cases).

command -v orbit >/dev/null 2>&1 || exit 0

HINT='<!-- orbit workspace: invoke the orbit skill (skip only if its content is already in your context) -->'

if out=$(orbit context 2>/dev/null) && [ -n "$out" ]; then
  printf '<orbit-context>\n%s\n%s\n</orbit-context>\n' "$HINT" "$out"
fi
exit 0
