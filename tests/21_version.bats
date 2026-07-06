#!/usr/bin/env bats

setup() {
  load test_helper/common
  common_setup
}

teardown() {
  common_teardown
}

# --- version command ---

@test "version: prints a semver on stdout and exits 0" {
  run bash -c "bash '$ORBIT_CMD' version"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "version: --version and -v are aliases" {
  run bash -c "bash '$ORBIT_CMD' version"
  local v="$output"
  run bash -c "bash '$ORBIT_CMD' --version"
  [ "$status" -eq 0 ]
  [ "$output" = "$v" ]
  run bash -c "bash '$ORBIT_CMD' -v"
  [ "$status" -eq 0 ]
  [ "$output" = "$v" ]
}

@test "doctor: reports orbit version" {
  local proj="$SANDBOX/version-doctor"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' doctor"
  [ "$status" -eq 0 ]
  assert_contains "$output" "orbit "
}
