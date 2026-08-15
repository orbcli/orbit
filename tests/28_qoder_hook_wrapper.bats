#!/usr/bin/env bats
# hooks/qoder/session-start.sh & session-resume.sh — the qoder stdout contract.
#
# Qoder's IDE parses hook stdout strictly as JSON and drops bare text; the
# wrappers run the shared scripts and re-encode stdout as
# hookSpecificOutput.additionalContext JSON (hookEventName is required or the
# output is rejected wholesale). These tests pin: the JSON shape, the
# escaping, the silent no-op on empty output, and the QODER_PROJECT_DIR →
# CLAUDE_PROJECT_DIR anchor mapping (host-native env knowledge stays in the
# host wrapper; the shared script reads only the contract name).

setup() {
  load test_helper/common
  common_setup
  START_WRAP="$BATS_TEST_DIRNAME/../hooks/qoder/session-start.sh"
  RESUME_WRAP="$BATS_TEST_DIRNAME/../hooks/qoder/session-resume.sh"
  STUB_BIN="$SANDBOX/bin"
  mkdir -p "$STUB_BIN"
  PROJ="$SANDBOX/proj"; LAUNCH="$SANDBOX/launch"
  mkdir -p "$PROJ" "$LAUNCH"
  PROJ_P="$(cd "$PROJ" && pwd -P)"
  LAUNCH_P="$(cd "$LAUNCH" && pwd -P)"
}

teardown() {
  common_teardown
}

# Stub orbit on PATH: report argv and the physical cwd (what the anchor
# logic manipulates). $ORBIT_STUB_EMPTY makes it exit 0 with no output.
write_orbit_stub() {
  cat >"$STUB_BIN/orbit" <<'EOF'
#!/usr/bin/env bash
[ -n "${ORBIT_STUB_EMPTY:-}" ] && exit 0
printf 'STUB args=%s cwd=%s\n' "$*" "$(pwd -P)"
EOF
  chmod +x "$STUB_BIN/orbit"
}

# Validate $output as the exact JSON contract and return additionalContext.
json_context() {
  printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "SessionStart", "hookEventName missing/wrong"
sys.stdout.write(h["additionalContext"])
'
}

@test "qoder wrapper: shared stdout is re-encoded as JSON additionalContext" {
  write_orbit_stub
  cd "$LAUNCH"
  run env PATH="$STUB_BIN:/usr/bin:/bin" bash "$START_WRAP"
  [ "$status" -eq 0 ]
  ctx="$(json_context)"
  assert_contains "$ctx" "<orbit-context>"
  assert_contains "$ctx" "STUB args=context --startup cwd=$LAUNCH_P"
}

@test "qoder wrapper: resume variant wraps the cruise call" {
  write_orbit_stub
  cd "$LAUNCH"
  run env PATH="$STUB_BIN:/usr/bin:/bin" bash "$RESUME_WRAP"
  [ "$status" -eq 0 ]
  ctx="$(json_context)"
  assert_contains "$ctx" "STUB args=context cwd=$LAUNCH_P"
}

@test "qoder wrapper: empty shared output is a silent no-op (no JSON emitted)" {
  write_orbit_stub
  cd "$LAUNCH"
  run env PATH="$STUB_BIN:/usr/bin:/bin" ORBIT_STUB_EMPTY=1 bash "$START_WRAP"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "qoder wrapper: the orbit-missing prompt is also JSON-wrapped" {
  cd "$LAUNCH"
  run env PATH="/usr/bin:/bin" bash "$START_WRAP"   # no orbit on PATH
  [ "$status" -eq 0 ]
  ctx="$(json_context)"
  assert_contains "$ctx" "not on your PATH"
}

@test "qoder wrapper: QODER_PROJECT_DIR is mapped onto the anchor var" {
  write_orbit_stub
  cd "$LAUNCH"
  run env -u CLAUDE_PROJECT_DIR PATH="$STUB_BIN:/usr/bin:/bin" QODER_PROJECT_DIR="$PROJ" bash "$START_WRAP"
  [ "$status" -eq 0 ]
  ctx="$(json_context)"
  assert_contains "$ctx" "cwd=$PROJ_P"
}

@test "qoder wrapper: an existing CLAUDE_PROJECT_DIR is not overridden" {
  write_orbit_stub
  cd "$LAUNCH"
  run env PATH="$STUB_BIN:/usr/bin:/bin" CLAUDE_PROJECT_DIR="$PROJ" QODER_PROJECT_DIR="$LAUNCH" bash "$START_WRAP"
  [ "$status" -eq 0 ]
  ctx="$(json_context)"
  assert_contains "$ctx" "cwd=$PROJ_P"
}

@test "qoder wrapper: residual C0/DEL bytes are stripped, JSON stays valid" {
  cat >"$STUB_BIN/orbit" <<'EOF'
#!/usr/bin/env bash
printf 'clean\vcontrol\fbytes\bstay\n'
EOF
  chmod +x "$STUB_BIN/orbit"
  cd "$LAUNCH"
  run env PATH="$STUB_BIN:/usr/bin:/bin" bash "$START_WRAP"
  [ "$status" -eq 0 ]
  ctx="$(json_context)"   # invalid JSON (literal C0) would fail the parse here
  assert_contains "$ctx" "cleancontrolbytesstay"
}
