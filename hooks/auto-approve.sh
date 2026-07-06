#!/usr/bin/env bash
# Orbit PreToolUse hook — auto-approve safe orbit commands.
#
# Reduces confirmation prompts for the agent's high-frequency orbit calls.
# Only auto-approves read-only + idempotent-workspace-write subcommands; the
# destructive / externally-visible ones (done, prune, clone, config, new) still
# fall through to the normal confirmation flow.
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

# Auto-approve tier: read-only + idempotent workspace writes.
# Excluded (still prompt): done, prune, clone, config, new.
case "$subcmd" in
  repos|info|status|context|goal|jot|memo|add|switch|sync|version|doctor|completion) ;;
  *) exit 0 ;;
esac

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"orbit %s: read-only / idempotent workspace command auto-approved by the orbit plugin"}}\n' "$subcmd"
exit 0
