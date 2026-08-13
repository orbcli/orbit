#!/usr/bin/env bash
# Orbit PreToolUse hook — auto-approve safe orbit commands.
#
# Reduces confirmation prompts for the agent's high-frequency orbit calls.
# Only auto-approves framework-verified subcommands (read-only + idempotent
# workspace-write). done/new are framework-neutral (workflow timing — the
# user's own allowlist decides); prune/clone/config always prompt. Anything
# non-matching falls through to the normal confirmation flow.
#
# Contract: on a match, print a PreToolUse "allow" decision on stdout and exit 0.
# On anything else, print nothing and exit 0 (normal confirmation preserved).
#
# Fail-safe by construction: if jq is missing, if the tool is not Bash, if the
# command chains shell operators, or if the leading binary is not orbit, we emit
# nothing and let the agent's normal permission prompt happen.
set -euo pipefail

# No jq → cannot parse the tool payload safely → do not auto-approve anything.
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
[ "$tool_name" = "Bash" ] || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$cmd" ] || exit 0

# Refuse anything with shell chaining/redirection/substitution — a bare single
# command is the only shape we can reason about safely.
# shellcheck disable=SC2016  # single quotes are intentional — match literal metachars, no expansion
case "$cmd" in
  *';'*|*'&'*|*'|'*|*'`'*|*'$('*|*'>'*|*'<'*|*$'\n'*) exit 0 ;;
esac

# Leading binary must be orbit (allow an absolute/relative path to it).
trimmed=${cmd#"${cmd%%[![:space:]]*}"}
first=${trimmed%%[[:space:]]*}
case "${first##*/}" in
  orbit|orbit.sh) ;;
  *) exit 0 ;;
esac

# First argument after the binary is the subcommand.
rest=${trimmed#"$first"}
rest=${rest#"${rest%%[![:space:]]*}"}
subcmd=${rest%%[[:space:]]*}

# Auto-approve tier: framework-verified only (read-only + idempotent
# workspace writes). Excluded: prune, clone, config (always prompt —
# destructive / shared-infrastructure); done, new (framework-neutral —
# workflow timing, the user's own allowlist decides).
case "$subcmd" in
  repos|info|status|context|goal|jot|memo|add|switch|sync|version|doctor|completion) ;;
  *) exit 0 ;;
esac

# Strip quotes and backslashes from a single shell token. The result is the
# shape orbit actually receives as an argument after bash parsing — the
# TypeScript twin is bare() in .opencode-plugin/plugin.ts.
normalize_token() {
  local tok="$1"
  tok=${tok//\'/}
  tok=${tok//\"/}
  tok=${tok//\\/}
  printf '%s\n' "$tok"
}

# sync --force resets the pool repo; sync --branch rewrites pool-wide state
# (checked-out branch, origin/HEAD). Both are destructive — still prompt.
#
# Match on normalized tokens, not raw text: bash passes `'--force'`,
# `--force''` and `\-\-force` to orbit as the very same `--force`, so
# normalizing per token is what makes the guard match what the CLI will
# actually see. Tokens are still compared whole — a `--forceful` or
# `--force=x` spelling must not trip it.
if [ "$subcmd" = "sync" ]; then
  set -f  # word-split $rest without letting a '*' argument glob the filesystem
  for tok in $rest; do
    case "$(normalize_token "$tok")" in
      --force|--branch) exit 0 ;;
    esac
  done
  set +f
fi

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"orbit %s: read-only / idempotent workspace command auto-approved by the orbit plugin"}}\n' "$subcmd"
exit 0
