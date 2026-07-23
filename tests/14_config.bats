#!/usr/bin/env bats

setup() {
  load test_helper/common
  common_setup
}

teardown() {
  common_teardown
}

@test "config: set and get a value" {
  local proj="$SANDBOX/cfg-test"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  run orbit config agent.recommend 'claude "开始"'
  [ "$status" -eq 0 ]
  assert_contains "$output" "set: agent.recommend"

  run orbit config agent.recommend
  [ "$status" -eq 0 ]
  assert_contains "$output" 'claude "开始"'
}

@test "config: unset a value" {
  local proj="$SANDBOX/cfg-test2"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  orbit config agent.recommend 'claude "开始"' >/dev/null
  run orbit config agent.recommend --unset
  [ "$status" -eq 0 ]
  assert_contains "$output" "unset: agent.recommend"

  # after --unset the key reports (unset), exit 1
  run orbit config agent.recommend
  [ "$status" -eq 1 ]
  assert_contains "$output" "(unset)"
}

@test "config: list filters out repo/index entries" {
  local proj="$SANDBOX/cfg-test3"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  git config --file "$proj/.repos/.orbit" repos.backend.url "git@github.com:org/backend.git"
  orbit config agent.recommend 'claude "开始"' >/dev/null

  run orbit config
  [ "$status" -eq 0 ]
  assert_contains "$output" "agent.recommend"
  # repos.* entries should be filtered out
  ! printf '%s' "$output" | grep -q "repos.backend"
}

@test "config: get nonexistent key reports (unset)" {
  local proj="$SANDBOX/cfg-test4"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  # unset keys report (unset) and exit non-zero (git config --get semantics)
  run orbit config no.such.key
  [ "$status" -eq 1 ]
  assert_contains "$output" "(unset)"
}
