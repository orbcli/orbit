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

# --- doctor command ---

@test "doctor: exits 0 with healthy environment" {
  local proj="$SANDBOX/doctor-test"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' doctor"
  [ "$status" -eq 0 ]
}

@test "doctor: reports git version" {
  local proj="$SANDBOX/doctor-test2"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' doctor"
  assert_contains "$output" "git"
  assert_contains "$output" "[OK]"
}

@test "doctor: reports bash version" {
  local proj="$SANDBOX/doctor-test3"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' doctor"
  assert_contains "$output" "bash"
  assert_contains "$output" "[OK]"
}

@test "doctor: reports project structure when in orbit project" {
  local proj="$SANDBOX/doctor-test4"
  clone_project "$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' doctor"
  [ "$status" -eq 0 ]
  assert_contains "$output" "repos in pool"
  assert_contains "$output" "1"
}
