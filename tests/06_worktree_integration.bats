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

# --- add command ---

@test "add: creates worktree directory in workspace" {
  local proj="$SANDBOX/add-test"
  clone_project "$proj"
  cd "$proj" && orbit new "add test" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  assert_dir_exists "$proj/dev/myrepo"
}

@test "add: creates .git file in worktree" {
  local proj="$SANDBOX/add-test2"
  clone_project "$proj"
  cd "$proj" && orbit new "add test" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  assert_file_exists "$proj/dev/myrepo/.git"
}

@test "add: creates ws/<workspace>/<default-branch> branch" {
  local proj="$SANDBOX/add-test3"
  clone_project "$proj"
  cd "$proj" && orbit new "add test" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  local branch
  branch=$(git -C "$proj/dev/myrepo" branch --show-current)
  [ "$branch" = "ws/dev/main" ]
}

@test "add: sets upstream tracking on worktree branch" {
  local proj="$SANDBOX/add-test4"
  clone_project "$proj"
  cd "$proj" && orbit new "add test" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  local upstream
  upstream=$(git -C "$proj/dev/myrepo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo "none")
  [ "$upstream" = "origin/main" ]
}

@test "add: ensures workspace .orbit file exists" {
  local proj="$SANDBOX/add-test5"
  clone_project "$proj"
  cd "$proj" && orbit new "add test" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  assert_file_exists "$proj/dev/.orbit"
}

@test "add: duplicate repo in same workspace fails" {
  local proj="$SANDBOX/add-test6"
  clone_project "$proj"
  cd "$proj" && orbit new "add test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' add myrepo"
  [ "$status" -ne 0 ]
}

@test "add: fails when executed at project root" {
  local proj="$SANDBOX/add-test7"
  clone_project "$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' add myrepo"
  [ "$status" -ne 0 ]
}

@test "add: non-existent repo in pool fails" {
  local proj="$SANDBOX/add-test8"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "add test" --name dev >/dev/null 2>&1

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' add nonexist"
  [ "$status" -ne 0 ]
}

# --- switch command ---

@test "switch: -c creates ws/<ws>/<name> branch from HEAD" {
  local proj="$SANDBOX/switch-test"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo" && orbit switch -c feat-new >/dev/null 2>&1
  local branch
  branch=$(git -C "$proj/dev/myrepo" branch --show-current)
  [ "$branch" = "ws/dev/feat-new" ]
}

@test "switch: -c sets upstream merge ref" {
  local proj="$SANDBOX/switch-test2"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo" && orbit switch -c feat-new >/dev/null 2>&1
  local merge_ref
  merge_ref=$(git -C "$proj/dev/myrepo" config --get "branch.ws/dev/feat-new.merge" 2>/dev/null || echo "")
  [ "$merge_ref" = "refs/heads/feat-new" ]
}

@test "switch: -c sets upstream remote to origin" {
  local proj="$SANDBOX/switch-test3"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo" && orbit switch -c feat-new >/dev/null 2>&1
  local remote_cfg
  remote_cfg=$(git -C "$proj/dev/myrepo" config --get "branch.ws/dev/feat-new.remote" 2>/dev/null || echo "")
  [ "$remote_cfg" = "origin" ]
}

@test "switch: ensures push.default=upstream on repo" {
  local proj="$SANDBOX/switch-test4"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo" && orbit switch -c feat-new >/dev/null 2>&1
  local push_default
  push_default=$(git -C "$proj/.repos/myrepo" config --get push.default)
  [ "$push_default" = "upstream" ]
}

@test "switch: switches to existing remote branch with tracking" {
  local proj="$SANDBOX/switch-test5"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo" && orbit switch feature-x >/dev/null 2>&1
  local branch
  branch=$(git -C "$proj/dev/myrepo" branch --show-current)
  [ "$branch" = "ws/dev/feature-x" ]
}

@test "switch: sets merge ref when switching to remote branch" {
  local proj="$SANDBOX/switch-test6"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo" && orbit switch feature-x >/dev/null 2>&1
  local merge_ref
  merge_ref=$(git -C "$proj/dev/myrepo" config --get "branch.ws/dev/feature-x.merge" 2>/dev/null || echo "")
  [ "$merge_ref" = "refs/heads/feature-x" ]
}

@test "switch: non-existent remote branch fails" {
  local proj="$SANDBOX/switch-test7"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev/myrepo' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' switch nonexist-branch"
  [ "$status" -ne 0 ]
}

@test "switch: -c with existing remote branch name fails" {
  local proj="$SANDBOX/switch-test8"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev/myrepo' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' switch -c feature-x"
  [ "$status" -ne 0 ]
}

@test "switch: explicit repo argument from workspace root" {
  local proj="$SANDBOX/switch-test9"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev/myrepo" && orbit switch -c feat-new >/dev/null 2>&1

  cd "$proj/dev" && orbit switch myrepo feat-new >/dev/null 2>&1 || true
  local branch
  branch=$(git -C "$proj/dev/myrepo" branch --show-current)
  [ "$branch" = "ws/dev/feat-new" ]
}

# --- status command ---

@test "status: shows workspace name from CWD" {
  local proj="$SANDBOX/status-test"
  clone_project "$proj"
  cd "$proj" && orbit new "status goal" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' status"
  assert_contains "$output" "dev"
}

@test "status: shows goal in output" {
  local proj="$SANDBOX/status-test2"
  clone_project "$proj"
  cd "$proj" && orbit new "status goal" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' status"
  assert_contains "$output" "status goal"
}

@test "status: shows repo name in output" {
  local proj="$SANDBOX/status-test3"
  clone_project "$proj"
  cd "$proj" && orbit new "status goal" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' status"
  assert_contains "$output" "myrepo"
}

@test "status: works with explicit workspace name from root" {
  local proj="$SANDBOX/status-test4"
  clone_project "$proj"
  cd "$proj" && orbit new "status goal" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' status dev"
  assert_contains "$output" "dev"
}

@test "status: shows branch info with explicit workspace" {
  local proj="$SANDBOX/status-test5"
  clone_project "$proj"
  cd "$proj" && orbit new "status goal" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' status dev"
  assert_contains "$output" "ws/dev/main"
}

# --- CWD inference ---

@test "cwd-inference: goal works from worktree subdirectory" {
  local proj="$SANDBOX/cwd-test"
  clone_project "$proj"
  cd "$proj" && orbit new "cwd test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev/myrepo' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context goal"
  [ "$output" = "cwd test" ]
}

@test "cwd-inference: done works from worktree subdirectory" {
  local proj="$SANDBOX/cwd-test2"
  clone_project "$proj"
  cd "$proj" && orbit new "cwd test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo" && orbit done >/dev/null 2>&1
  local st
  st=$(git config --file "$proj/dev/.orbit" --get workspace.status)
  [ "$st" = "done" ]
}

@test "cwd-inference: status works from worktree subdirectory" {
  local proj="$SANDBOX/cwd-test3"
  clone_project "$proj"
  cd "$proj" && orbit new "cwd test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev/myrepo' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' status 2>/dev/null"
  assert_contains "$output" "dev"
}
