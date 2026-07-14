#!/usr/bin/env bats
#
# Lightweight argument-parsing / validation checks for install.sh.
# These deliberately avoid real end-to-end installs: they exercise only the
# paths that stop at parsing or validation, or that no-op when the target CLI
# is absent. No claude/codex/qodercli command is ever invoked.

setup() {
  load test_helper/common
  common_setup
  INSTALL="${BATS_TEST_DIRNAME}/../install.sh"
  # Isolated HOME so uninstall paths that touch ~/.config or ~/.local never
  # affect the real environment.
  FAKE_HOME="$SANDBOX/home"
  mkdir -p "$FAKE_HOME"
}

teardown() {
  common_teardown
}

# Run install.sh with an isolated HOME and a PATH that has no agent CLIs, so
# any plugin uninstall degrades to a "CLI not found — skipping" no-op.
run_install() {
  run env HOME="$FAKE_HOME" PATH="/usr/bin:/bin" bash "$INSTALL" "$@"
}

@test "help: --help exits 0 and prints usage" {
  run_install --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:"* ]]
}

@test "parse: unknown flag exits 1" {
  run_install --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option: --bogus"* ]]
}

@test "uninstall: no target is rejected" {
  run_install --uninstall
  [ "$status" -eq 1 ]
  [[ "$output" == *"--uninstall requires at least one target"* ]]
}

@test "uninstall: a single plugin target no-ops when its CLI is absent" {
  run_install --uninstall --claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude CLI not found"* ]]
}

@test "uninstall: --all runs every target and exits 0 when nothing is installed" {
  run_install --uninstall --all
  [ "$status" -eq 0 ]
  # --all expands to all plugin targets; missing CLIs are skipped, not fatal.
  [[ "$output" == *"codex CLI not found"* ]] || [[ "$output" == *"Removed"* ]]
  [[ "$output" == *"Done."* ]]
}

@test "uninstall: --cli reports nothing to remove when runtime is absent" {
  run_install --uninstall --cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to remove"* ]]
}
