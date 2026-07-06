#!/usr/bin/env bats

setup_file() {
  load test_helper/common
  ensure_shared_project_with_branch
}

setup() {
  load test_helper/common
  common_setup
}

teardown() {
  common_teardown
}

# --- add --ref command ---

@test "add --ref: checks out worktree at specified branch" {
  local proj="$SANDBOX/add-ref-test"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "ref test" --name ws1 >/dev/null 2>&1

  cd "$proj/ws1" && orbit add myrepo --ref feature-x >/dev/null 2>&1
  assert_dir_exists "$proj/ws1/myrepo"
  local branch
  branch=$(git -C "$proj/ws1/myrepo" branch --show-current)
  assert_contains "$branch" "ws/ws1/"
}

@test "add --ref: fails gracefully for nonexistent ref" {
  local proj="$SANDBOX/add-ref-test2"
  clone_project "$proj"
  cd "$proj" && orbit new "ref test" --name ws1 >/dev/null 2>&1

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' add myrepo --ref nonexistent"
  [ "$status" -ne 0 ]
  assert_contains "$output" "cannot fetch ref"
}

@test "add: still works without --ref (backward compat)" {
  local proj="$SANDBOX/add-ref-test3"
  clone_project "$proj"
  cd "$proj" && orbit new "ref test" --name ws1 >/dev/null 2>&1

  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1
  assert_dir_exists "$proj/ws1/myrepo"
  local branch
  branch=$(git -C "$proj/ws1/myrepo" branch --show-current)
  [ "$branch" = "ws/ws1/main" ]
}

@test "add --ref: creates tracking branch with workspace prefix" {
  local proj="$SANDBOX/add-ref-test4"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "ref test" --name ws2 >/dev/null 2>&1

  cd "$proj/ws2" && orbit add myrepo --ref feature-y >/dev/null 2>&1
  local branch
  branch=$(git -C "$proj/ws2/myrepo" branch --show-current)
  [ "$branch" = "ws/ws2/main" ]
}

@test "add --ref: works with tag reference" {
  local proj="$SANDBOX/add-ref-test5"
  # Needs its own remote to add a tag
  local remote="$REMOTES/add-ref-repo5.git"
  clone_remote "$remote"
  git -C "$remote" tag v1.0.0 HEAD
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit clone "$remote" --name myrepo >/dev/null 2>&1
  cd "$proj" && orbit new "ref test" --name ws3 >/dev/null 2>&1

  cd "$proj/ws3" && orbit add myrepo --ref v1.0.0 >/dev/null 2>&1
  assert_dir_exists "$proj/ws3/myrepo"
}

@test "add: memo goes to stderr, added line to stdout" {
  local proj="$SANDBOX/add-memo-default"
  clone_project "$proj"
  cd "$proj" && orbit new "memo test" --name ws1 >/dev/null 2>&1
  printf '# myrepo\nmemo-sentinel-body\n' | (cd "$proj" && ORBIT_ROOT="$proj" bash "$ORBIT_CMD" memo myrepo) >/dev/null 2>&1

  # stdout only: should have the added line, NOT the memo
  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' add myrepo 2>/dev/null"
  [ "$status" -eq 0 ]
  assert_contains "$output" "added myrepo"
  ! echo "$output" | grep -q "memo-sentinel-body"
}

@test "add: memo content is present on stderr by default" {
  local proj="$SANDBOX/add-memo-stderr"
  clone_project "$proj"
  cd "$proj" && orbit new "memo test" --name ws1 >/dev/null 2>&1
  printf '# myrepo\nmemo-sentinel-body\n' | (cd "$proj" && ORBIT_ROOT="$proj" bash "$ORBIT_CMD" memo myrepo) >/dev/null 2>&1

  # stderr only
  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' add myrepo 2>&1 1>/dev/null"
  [ "$status" -eq 0 ]
  assert_contains "$output" "memo: myrepo"
  assert_contains "$output" "memo-sentinel-body"
}

@test "add -s: suppresses memo output" {
  local proj="$SANDBOX/add-memo-silent"
  clone_project "$proj"
  cd "$proj" && orbit new "memo test" --name ws1 >/dev/null 2>&1
  printf '# myrepo\nmemo-sentinel-body\n' | (cd "$proj" && ORBIT_ROOT="$proj" bash "$ORBIT_CMD" memo myrepo) >/dev/null 2>&1

  # capture stdout+stderr; memo must not appear anywhere
  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' add myrepo -s 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "added myrepo"
  ! echo "$output" | grep -q "memo-sentinel-body"
}

@test "add: prints hint when no memo exists" {
  local proj="$SANDBOX/add-memo-none"
  clone_project "$proj"
  cd "$proj" && orbit new "memo test" --name ws1 >/dev/null 2>&1
  rm -f "$proj/.repos/.myrepo.md"

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' add myrepo"
  [ "$status" -eq 0 ]
  assert_contains "$output" "no memo for myrepo"
}

@test "add --ref: worktree HEAD matches ref commit" {
  local proj="$SANDBOX/add-ref-head-test"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "test" --name ws1 >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo --ref feature-x >/dev/null 2>&1

  local ws_head
  ws_head=$(git -C "$proj/ws1/myrepo" rev-parse HEAD)
  local ref_head
  ref_head=$(git -C "$SHARED_REMOTE_WITH_BRANCH" rev-parse refs/heads/feature-x)
  [ "$ws_head" = "$ref_head" ]
}
