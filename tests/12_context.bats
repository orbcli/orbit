#!/usr/bin/env bats

setup_file() {
  load test_helper/common
  ensure_shared_project
}

setup() {
  load test_helper/common
  common_setup
}

teardown() {
  common_teardown
}

# --- context command ---

@test "context: outputs workspace name and goal" {
  local proj="$SANDBOX/context-test"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "implement feature X" --name ws1 >/dev/null 2>&1

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context"
  [ "$status" -eq 0 ]
  assert_contains "$output" "ws1"
  assert_contains "$output" "implement feature X"
}

@test "context: lists repos with memo content" {
  local proj="$SANDBOX/context-test2"
  clone_project "$proj"
  printf '# myrepo\n\nThis is the memo for context test.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1
  cd "$proj" && orbit new "context test" --name ws1 >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context --json"
  [ "$status" -eq 0 ]
  assert_contains "$output" "This is the memo for context test."
}

@test "context --json: outputs valid JSON with expected fields" {
  local proj="$SANDBOX/context-test3"
  clone_project "$proj"
  printf '# myrepo\n\nJSON context memo.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1
  cd "$proj" && orbit new "json context goal" --name ws1 >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context --json"
  [ "$status" -eq 0 ]
  assert_contains "$output" '"workspace"'
  assert_contains "$output" '"goal"'
  assert_contains "$output" '"worktrees"'
  assert_contains "$output" '"memo"'
}

@test "context <key>: returns single value for path" {
  local proj="$SANDBOX/context-key1"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "key test" --name ws1 >/dev/null 2>&1

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context path"
  [ "$status" -eq 0 ]
  [ "$output" = "$proj/ws1" ]
}

@test "context <key>: returns workspace name" {
  local proj="$SANDBOX/context-key2"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "key test" --name myws >/dev/null 2>&1

  run bash -c "cd '$proj/myws' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "myws" ]
}

@test "context <key>: returns goal" {
  local proj="$SANDBOX/context-key3"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "the goal text" --name ws1 >/dev/null 2>&1

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context goal"
  [ "$status" -eq 0 ]
  [ "$output" = "the goal text" ]
}

@test "context <key>: unknown key fails" {
  local proj="$SANDBOX/context-key4"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "test" --name ws1 >/dev/null 2>&1

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context badkey"
  [ "$status" -ne 0 ]
  assert_contains "$output" "unknown key"
}

@test "context: auto-recreates missing .orbit file" {
  local proj="$SANDBOX/context-rebuild"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "rebuild test" --name ws1 >/dev/null 2>&1

  rm -f "$proj/ws1/.orbit"
  [ ! -f "$proj/ws1/.orbit" ]

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context path"
  [ "$status" -eq 0 ]
  [ "$output" = "$proj/ws1" ]

  [ -f "$proj/ws1/.orbit" ]
}

@test "context: fails when run from project root" {
  local proj="$SANDBOX/context-test4"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context"
  [ "$status" -ne 0 ]
  assert_contains "$output" "cannot infer workspace from project root"
}

# --- context gaps ---

@test "context gaps: lists a no-memo repo, drops it after a real jot" {
  local proj="$SANDBOX/context-gaps"
  clone_project "$proj"
  cd "$proj" && orbit new --name ws1 --no-goal >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1

  # No memo → add seeded a [seed] jot → still a gap.
  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context gaps"
  [ "$status" -eq 0 ]
  assert_contains "$output" "myrepo"

  # A real (non-seed) jot closes the gap.
  orbit jot myrepo "real finding" 2>/dev/null
  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context gaps"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "context gaps --json: emits a JSON array" {
  local proj="$SANDBOX/context-gaps-json"
  clone_project "$proj"
  cd "$proj" && orbit new --name ws1 --no-goal >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context gaps --json"
  [ "$status" -eq 0 ]
  assert_contains "$output" "[\"myrepo\"]"
}
