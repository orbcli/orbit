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

# --- branch.prefix: durable project property, not per-call env state ---

@test "config: branch.prefix defaults to ws and is settable" {
  local proj="$SANDBOX/prefix-default"
  clone_project "$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' config branch.prefix"
  [ "$status" -ne 0 ]   # unset — the default is not materialized

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' config branch.prefix team"
  [ "$status" -eq 0 ]
  assert_contains "$output" "set: branch.prefix = team"
}

@test "config: branch.prefix drives created branch names" {
  local proj="$SANDBOX/prefix-creates"
  clone_project "$proj"
  (cd "$proj" && ORBIT_ROOT="$proj" bash "$ORBIT_CMD" config branch.prefix team >/dev/null 2>&1)
  (cd "$proj" && orbit new "prefix test" --name dev >/dev/null 2>&1)

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' add myrepo"
  [ "$status" -eq 0 ]
  run git -C "$proj/dev/myrepo" branch --show-current
  assert_contains "$output" "team/dev/"
}

@test "config: branch.prefix rejects invalid values" {
  local proj="$SANDBOX/prefix-invalid"
  clone_project "$proj"

  for bad in "a/b" ".bad" "a..b" "x y"; do
    run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' config branch.prefix '$bad'"
    [ "$status" -ne 0 ]
    assert_contains "$output" "invalid branch.prefix"
  done
}

@test "config: branch.prefix cannot move while branches carry the current one" {
  local proj="$SANDBOX/prefix-locked"
  clone_project "$proj"
  (cd "$proj" && orbit new "locked test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)

  # The prefix is part of ws/dev/<branch>; moving it now would orphan that
  # branch — prune would look for it under the new prefix and never find it.
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' config branch.prefix team"
  [ "$status" -ne 0 ]
  assert_contains "$output" "part of existing branch names under 'ws/'"
  assert_contains "$output" "myrepo (1)"

  # Unsetting is the same move in reverse, and is refused the same way.
  (cd "$proj" && git config --file "$proj/.repos/.orbit" branch.prefix ws)
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' config branch.prefix team"
  [ "$status" -ne 0 ]
}

@test "config: branch.prefix moves freely once no branch carries it" {
  local proj="$SANDBOX/prefix-free"
  clone_project "$proj"
  (cd "$proj" && orbit new "free test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' config branch.prefix team"
  [ "$status" -eq 0 ]
  assert_contains "$output" "set: branch.prefix = team"
}

@test "config: prune deletes only branches under the configured prefix" {
  local proj="$SANDBOX/prefix-scope"
  clone_project "$proj"
  (cd "$proj" && orbit new "env test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  # A branch shaped like an orbit workspace branch but under a foreign prefix:
  # it is not orbit's to delete — the configured prefix is the selector.
  git -C "$proj/.repos/myrepo" branch "release/dev/keepme" >/dev/null 2>&1
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --force 2>&1"
  [ "$status" -eq 0 ]

  run git -C "$proj/.repos/myrepo" for-each-ref --format='%(refname:short)' refs/heads/release/
  assert_contains "$output" "release/dev/keepme"
}

@test "config: refuses to write pool index keys (repos.*)" {
  local proj="$SANDBOX/cfg-repos-guard"
  clone_project "$proj"

  # repos.* is orbit's pool index. It is rebuildable, but letting config write it
  # would rest this command's safety on that rebuildability instead of its own.
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' config repos.myrepo.url --unset"
  [ "$status" -ne 0 ]
  assert_contains "$output" "pool index data, not project config"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' config repos.myrepo.url http://evil"
  [ "$status" -ne 0 ]

  # the index entry is untouched
  run git config --file "$proj/.repos/.orbit" --get repos.myrepo.url
  [ "$status" -eq 0 ]
  [[ "$output" != "http://evil" ]]
}
