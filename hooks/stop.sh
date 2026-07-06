#!/usr/bin/env bash
# Orbit Stop hook — nudge the agent to memo-ize no/low-memo repos before it stops.
#
# A repo added with no (or thin) memo, worked on, and left without a real jot/memo
# leaves the pool with nothing reusable for the next session. This hook fires on
# turn end and, once per repo, reminds the agent to explore + capture + write a memo.
#
# Contract: emit a Stop `decision:"block"` + `reason` nudge on stdout and exit 0;
# emit nothing and exit 0 otherwise. Fail-safe by construction — any missing
# dependency, non-workspace CWD, or empty gap set results in a silent no-op.
set -euo pipefail

# No jq → cannot parse stdin / build JSON safely → no-op.
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

# Loop guard: if we already blocked/continued this turn, do not nudge again.
active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
[ "$active" = "true" ] && exit 0

command -v orbit >/dev/null 2>&1 || exit 0

# Only inside a workspace.
ws=$(orbit context path 2>/dev/null) || exit 0
[ -n "$ws" ] || exit 0

gaps_json=$(orbit context gaps --json 2>/dev/null || echo '[]')

# Collect gap repos not yet nudged this workspace (throttle: once per repo).
pending=()
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  marked=$(git config --file "$ws/.orbit" --get "nudge.$repo.seen" 2>/dev/null || true)
  [ -n "$marked" ] && continue
  pending+=("$repo")
done < <(printf '%s' "$gaps_json" | jq -r '.[]?' 2>/dev/null || true)

[ "${#pending[@]}" -gt 0 ] || exit 0

# Mark so we don't nag every turn; the done gate is the backstop if ignored.
for repo in "${pending[@]}"; do
  git config --file "$ws/.orbit" "nudge.$repo.seen" 1 2>/dev/null || true
done

list=$(printf '%s, ' "${pending[@]}"); list=${list%, }
msg="Before you finish: these repos still have no real memo (only a [seed] placeholder) — ${list}. For each, explore entry points/structure/build, capture findings with 'orbit jot <repo> \"...\"', then write the memo via 'orbit memo <repo>' (drop the [seed] line — it is an instruction, not memo content). One-time reminder per repo."

printf '%s' "$msg" | jq -Rs '{decision:"block",reason:.}'
exit 0
