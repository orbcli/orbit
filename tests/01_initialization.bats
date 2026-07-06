#!/usr/bin/env bats

setup_file() {
  load test_helper/common
  ensure_shared_remote
}

setup() {
  load test_helper/common
  common_setup
}

teardown() {
  common_teardown
}

@test "clone: auto-initializes .repos/ directory on first clone" {
  local proj="$SANDBOX/init-test"
  mkdir -p "$proj"
  TEST_PROJECT="$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' clone '$SHARED_REMOTE' --name init-repo"
  [ "$status" -eq 0 ]
  assert_dir_exists "$proj/.repos"
}

@test "clone: auto-creates .repos/.orbit index file" {
  local proj="$SANDBOX/init-test2"
  mkdir -p "$proj"
  TEST_PROJECT="$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' clone '$SHARED_REMOTE' --name init-repo2"
  [ "$status" -eq 0 ]
  assert_file_exists "$proj/.repos/.orbit"
}

@test "clone: creates repo in pool directory" {
  local proj="$SANDBOX/init-test3"
  mkdir -p "$proj"
  TEST_PROJECT="$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' clone '$SHARED_REMOTE' --name init-repo3"
  [ "$status" -eq 0 ]
  assert_dir_exists "$proj/.repos/init-repo3"
}

@test "new: auto-creates .repos/ directory when missing" {
  local proj="$SANDBOX/init-test-new"
  mkdir -p "$proj"
  TEST_PROJECT="$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' new 'test goal'"
  [ "$status" -eq 0 ]
  assert_dir_exists "$proj/.repos"
}

@test "new: creates workspace directory on implicit init" {
  local proj="$SANDBOX/init-test-new2"
  mkdir -p "$proj"
  TEST_PROJECT="$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' new 'test goal'"
  [ "$status" -eq 0 ]
  assert_dir_exists "$proj/task-01"
}
