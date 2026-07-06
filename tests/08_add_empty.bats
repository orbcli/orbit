#!/usr/bin/env bats

setup() {
  load test_helper/common
  common_setup
}

teardown() {
  common_teardown
}

# Each test uses its own empty remote (some push to it, mutating state).
setup_empty_project() {
  local proj="$1"
  local remote="$SANDBOX/empty_remote_$(basename "$proj").git"
  create_empty_bare_repo "$remote"
  TEST_PROJECT="$proj"
  mkdir -p "$proj"
  cd "$proj" && orbit clone "$remote" --name emptyrepo >/dev/null 2>&1
  cd "$proj" && orbit new "empty test" --name dev >/dev/null 2>&1
  EMPTY_REMOTE="$remote"
}

@test "clone: succeeds on an empty remote" {
  local proj="$SANDBOX/empty-clone"
  local remote="$SANDBOX/empty_clone_remote.git"
  create_empty_bare_repo "$remote"
  TEST_PROJECT="$proj"
  mkdir -p "$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' clone '$remote' --name emptyrepo"
  [ "$status" -eq 0 ]
  assert_dir_exists "$proj/.repos/emptyrepo"
}

@test "add: bootstraps an orphan worktree for an empty repo" {
  local proj="$SANDBOX/empty-add"
  setup_empty_project "$proj"

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' add emptyrepo"
  [ "$status" -eq 0 ]
  assert_dir_exists "$proj/dev/emptyrepo"
  assert_file_exists "$proj/dev/emptyrepo/.git"
}

@test "add: empty worktree is on ws/<workspace>/<default> branch" {
  local proj="$SANDBOX/empty-branch"
  setup_empty_project "$proj"
  cd "$proj/dev" && orbit add emptyrepo >/dev/null 2>&1

  local branch
  branch=$(git -C "$proj/dev/emptyrepo" branch --show-current)
  [ "$branch" = "ws/dev/main" ]
}

@test "add: empty worktree has no commit yet" {
  local proj="$SANDBOX/empty-nocommit"
  setup_empty_project "$proj"
  cd "$proj/dev" && orbit add emptyrepo >/dev/null 2>&1

  run git -C "$proj/dev/emptyrepo" rev-parse --verify HEAD
  [ "$status" -ne 0 ]
}

@test "add: empty worktree has upstream configured" {
  local proj="$SANDBOX/empty-upstream"
  setup_empty_project "$proj"
  cd "$proj/dev" && orbit add emptyrepo >/dev/null 2>&1

  local merge remote
  merge=$(git -C "$proj/dev/emptyrepo" config --get branch.ws/dev/main.merge)
  remote=$(git -C "$proj/dev/emptyrepo" config --get branch.ws/dev/main.remote)
  [ "$merge" = "refs/heads/main" ]
  [ "$remote" = "origin" ]
}

@test "add: first commit can be authored and pushed" {
  local proj="$SANDBOX/empty-firstcommit"
  setup_empty_project "$proj"
  cd "$proj/dev" && orbit add emptyrepo >/dev/null 2>&1

  cd "$proj/dev/emptyrepo"
  echo "hello" > README.md
  git add README.md
  git commit -m "first commit" >/dev/null 2>&1
  # -c core.hooksPath=/dev/null: stay hermetic from the runner's global git hooks
  run git -c core.hooksPath=/dev/null push
  [ "$status" -eq 0 ]

  # Remote now has the default branch.
  run git -C "$EMPTY_REMOTE" rev-parse --verify main
  [ "$status" -eq 0 ]
}

@test "status: renders an empty (commitless) worktree without error" {
  local proj="$SANDBOX/empty-status"
  setup_empty_project "$proj"
  cd "$proj/dev" && orbit add emptyrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' status"
  [ "$status" -eq 0 ]
  assert_contains "$output" "emptyrepo"
}
