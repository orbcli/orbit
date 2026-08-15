#!/usr/bin/env bats
# hooks/session-start.sh & hooks/session-resume.sh — host-CWD anchor contract.
#
# Hook CWD is not a cross-host contract — a host may run hooks from outside
# the project directory. The shared scripts anchor to the host-injected
# project dir before calling `orbit context`, whose workspace detection is
# CWD-based. They read exactly one anchor name: CLAUDE_PROJECT_DIR (claude's
# documented contract, also injected by Qoder IDE as a compat alias).
# Host-native variants are a wrapper concern — the qoder wrapper maps
# QODER_PROJECT_DIR onto CLAUDE_PROJECT_DIR (covered in
# 28_qoder_hook_wrapper.bats). These tests pin the shared-script side: the
# single anchor name, the guards (empty / unset / nonexistent / not-a-dir),
# and the no-op fallthrough for env-less hosts (codex).

setup() {
  load test_helper/common
  common_setup
  START_HOOK="$BATS_TEST_DIRNAME/../hooks/session-start.sh"
  RESUME_HOOK="$BATS_TEST_DIRNAME/../hooks/session-resume.sh"
  # Stub orbit on PATH: reports its argv and physical cwd.
  STUB_BIN="$SANDBOX/bin"
  mkdir -p "$STUB_BIN"
  cat >"$STUB_BIN/orbit" <<'EOF'
#!/usr/bin/env bash
printf 'STUB args=%s cwd=%s\n' "$*" "$(pwd -P)"
EOF
  chmod +x "$STUB_BIN/orbit"
  export PATH="$STUB_BIN:$PATH"
  PROJ="$SANDBOX/proj"
  OTHER="$SANDBOX/other"
  LAUNCH="$SANDBOX/launch"
  mkdir -p "$PROJ" "$OTHER" "$LAUNCH"
  PROJ_P="$(cd "$PROJ" && pwd -P)"
  OTHER_P="$(cd "$OTHER" && pwd -P)"
  LAUNCH_P="$(cd "$LAUNCH" && pwd -P)"
}

teardown() {
  common_teardown
}

# Run both hooks from $LAUNCH with env vars passed as NAME=VALUE args;
# assert every run reports the expected physical cwd.
# $1: expected cwd; remaining args: env assignments for `env`.
assert_hooks_cwd() {
  local want="$1"; shift
  local hook args
  for hook in "$START_HOOK" "$RESUME_HOOK"; do
    if [ "$hook" = "$START_HOOK" ]; then args="context --startup"; else args="context"; fi
    cd "$LAUNCH"
    run env -u CLAUDE_PROJECT_DIR -u QODER_PROJECT_DIR "$@" bash "$hook"
    [ "$status" -eq 0 ]
    assert_contains "$output" "STUB args=$args cwd=$want"
  done
}

@test "anchor: CLAUDE_PROJECT_DIR wins when set" {
  assert_hooks_cwd "$PROJ_P" "CLAUDE_PROJECT_DIR=$PROJ"
}

@test "anchor: QODER_PROJECT_DIR is not read by the shared script (wrapper maps it)" {
  assert_hooks_cwd "$LAUNCH_P" "QODER_PROJECT_DIR=$PROJ"
}

@test "anchor: empty CLAUDE_PROJECT_DIR keeps the launch cwd" {
  assert_hooks_cwd "$LAUNCH_P" "CLAUDE_PROJECT_DIR=" "QODER_PROJECT_DIR=$PROJ"
}

@test "anchor: unset env keeps the launch cwd (env-less hosts unaffected)" {
  assert_hooks_cwd "$LAUNCH_P"
}

@test "anchor: nonexistent dir is refused" {
  assert_hooks_cwd "$LAUNCH_P" "CLAUDE_PROJECT_DIR=$SANDBOX/no-such-dir"
}

@test "anchor: a regular file is not a dir anchor" {
  touch "$SANDBOX/afile"
  assert_hooks_cwd "$LAUNCH_P" "CLAUDE_PROJECT_DIR=$SANDBOX/afile"
}
