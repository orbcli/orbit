#!/usr/bin/env bats
# hooks/auto-approve.sh — PreToolUse auto-approve decision contract.
#
# The hook reads a JSON payload on stdin and either prints an "allow" decision
# (auto-approve) or prints nothing (normal confirmation prompt). These tests
# pin the destructive-flag guard: any shell spelling that reaches the CLI as
# --force / --branch must fall through to the prompt.

setup() {
  load test_helper/common
  common_setup
  HOOK="$BATS_TEST_DIRNAME/../hooks/auto-approve.sh"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
}

teardown() {
  common_teardown
}

# Run the hook with a Bash tool payload for $1; output captured by `run`.
hook_decide() {
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" | bash "$HOOK"
}

@test "auto-approve: safe subcommands are allowed" {
  run hook_decide "orbit status"
  [ "$status" -eq 0 ]
  assert_contains "$output" '"permissionDecision":"allow"'

  run hook_decide "orbit sync myrepo"
  assert_contains "$output" '"permissionDecision":"allow"'
}

@test "auto-approve: destructive tier prompts" {
  for sub in done prune clone config new; do
    run hook_decide "orbit $sub"
    [ -z "$output" ]
  done
}

@test "auto-approve: sync --force and --branch prompt" {
  run hook_decide "orbit sync --force"
  [ -z "$output" ]
  run hook_decide "orbit sync myrepo --force"
  [ -z "$output" ]
  run hook_decide "orbit sync myrepo --branch dev"
  [ -z "$output" ]
}

@test "auto-approve: shell-equivalent --force spellings all prompt" {
  # bash hands each of these to orbit as the very same --force; the guard
  # must match what the CLI will actually see, not the raw spelling.
  run hook_decide "orbit sync '--force'"
  [ -z "$output" ]
  run hook_decide "orbit sync \\\"--force\\\""
  [ -z "$output" ]
  run hook_decide "orbit sync --force''"
  [ -z "$output" ]
  run hook_decide "orbit sync \\\\-\\\\-force"
  [ -z "$output" ]
  run hook_decide "orbit sync myrepo '--branch' dev"
  [ -z "$output" ]
}

@test "auto-approve: flag lookalikes do not trip the guard" {
  run hook_decide "orbit sync --forceful"
  assert_contains "$output" '"permissionDecision":"allow"'
}

@test "auto-approve: chained commands prompt" {
  run hook_decide "orbit status; rm -rf x"
  [ -z "$output" ]
  run hook_decide "orbit info \$(whoami)"
  [ -z "$output" ]
}
