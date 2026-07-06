#!/usr/bin/env bats

setup() {
  load test_helper/common
  common_setup
}

teardown() {
  common_teardown
}

@test "metadata: goal auto-creates .orbit file on manual workspace" {
  local proj="$SANDBOX/autocreate-test"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  # Manual workspace dir (no orbit new → no .orbit)
  mkdir -p "$proj/manual-ws"

  cd "$proj/manual-ws" && orbit goal "set from nothing" >/dev/null 2>&1
  assert_file_exists "$proj/manual-ws/.orbit"
}

@test "metadata: auto-created .orbit has created timestamp (numeric)" {
  local proj="$SANDBOX/autocreate-test2"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  mkdir -p "$proj/manual-ws"

  cd "$proj/manual-ws" && orbit goal "set from nothing" >/dev/null 2>&1
  local created
  created=$(git config --file "$proj/manual-ws/.orbit" --get workspace.created)
  [[ "$created" =~ ^[0-9]+$ ]]
}
