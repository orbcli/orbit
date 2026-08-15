#!/usr/bin/env bash
# Orbit SessionStart hook (resume / compact matcher).
# Thin wrapper: injects the cruise block from bare `orbit context`
# (cheap durables + conditional per-repo status), wrapped in <orbit-context>
# tags so the agent can tell hook-injected context from self-invoked output,
# plus a one-line XML comment hint that re-triggers skill loading (hook-layer
# furniture — the orbit runtime never emits it). A compaction can wipe the
# skill content while a summary still "remembers" it — and a presence check
# ("is its content in your context") can't tell the two apart. So the skip
# condition is an enumeration-recall test: recite the skill's "Safety rules"
# section in full, count included, from the loaded skill text — a summary
# mentioning rules does not count; on any doubt, invoke.
# Silent no-op when orbit is missing or CWD is not in a workspace (bare
# `orbit context` fails fast in both cases).

command -v orbit >/dev/null 2>&1 || exit 0

# Same CWD anchoring as session-start.sh: hook CWD is not a cross-host
# contract, so anchor to the host-injected project dir (CLAUDE_PROJECT_DIR
# only; qoder's native QODER_PROJECT_DIR is mapped onto it by the qoder
# wrapper) before the CWD-based workspace detection. Guarded — empty/unset/
# invalid values are a silent no-op.
_orbit_anchor="${CLAUDE_PROJECT_DIR:-}"
if [ -n "$_orbit_anchor" ] && [ -d "$_orbit_anchor" ]; then
  cd "$_orbit_anchor" >/dev/null 2>&1 || true
fi
unset _orbit_anchor

HINT='<!-- orbit workspace: invoke the orbit skill (skip only if you can fully recall its "Safety rules" section, count included, from the loaded skill text — not from a summary; on any doubt, invoke) -->'

if out=$(orbit context 2>/dev/null) && [ -n "$out" ]; then
  printf '<orbit-context>\n%s\n%s\n</orbit-context>\n' "$HINT" "$out"
fi
exit 0
