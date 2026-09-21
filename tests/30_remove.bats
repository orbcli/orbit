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

# --- basic remove ---

@test "remove: deletes the worktree directory" {
  local proj="$SANDBOX/remove-test"
  clone_project "$proj"
  cd "$proj" && orbit new "remove test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  assert_dir_exists "$proj/dev/myrepo"

  cd "$proj/dev" && orbit remove myrepo >/dev/null 2>&1
  [ ! -d "$proj/dev/myrepo" ]
}

@test "remove: deletes the scoped local branch by default" {
  local proj="$SANDBOX/remove-test2"
  clone_project "$proj"
  cd "$proj" && orbit new "remove test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev" && orbit remove myrepo >/dev/null 2>&1
  # Branch is gone from the pool repo's refs.
  ! git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/main >/dev/null 2>&1
}

@test "remove: pool repo (.repos/<name>) is never touched" {
  local proj="$SANDBOX/remove-test4"
  clone_project "$proj"
  cd "$proj" && orbit new "remove test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  # Pool repo commits stay reachable.
  local pool_sha_before pool_sha_after
  pool_sha_before=$(git -C "$proj/.repos/myrepo" rev-parse HEAD)
  cd "$proj/dev" && orbit remove myrepo >/dev/null 2>&1
  pool_sha_after=$(git -C "$proj/.repos/myrepo" rev-parse HEAD)
  [ "$pool_sha_before" = "$pool_sha_after" ]
  assert_dir_exists "$proj/.repos/myrepo"
}

@test "remove: --json emits a structured record" {
  local proj="$SANDBOX/remove-test5"
  clone_project "$proj"
  cd "$proj" && orbit new "remove test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  local out
  out=$(cd "$proj/dev" && orbit remove myrepo --json 2>/dev/null)
  assert_contains "$out" '"workspace":"dev"'
  assert_contains "$out" '"repo":"myrepo"'
  assert_contains "$out" '"worktreeRemoved":true'
  assert_contains "$out" '"branch":"ws/dev/main"'
  assert_contains "$out" '"branchAction":"deleted"'
}

# --- safety: dirty / unmerged ---

@test "remove: refuses when worktree has uncommitted changes" {
  local proj="$SANDBOX/remove-dirty"
  clone_project "$proj"
  cd "$proj" && orbit new "remove test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  echo "wip" > "$proj/dev/myrepo/dirty.txt"
  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' remove myrepo"
  [ "$status" -ne 0 ]
  # Worktree must still exist.
  assert_dir_exists "$proj/dev/myrepo"
}

@test "remove: --force discards uncommitted changes" {
  local proj="$SANDBOX/remove-dirty2"
  clone_project "$proj"
  cd "$proj" && orbit new "remove test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  echo "wip" > "$proj/dev/myrepo/dirty.txt"
  cd "$proj/dev" && orbit remove myrepo --force >/dev/null 2>&1
  [ ! -d "$proj/dev/myrepo" ]
}

@test "remove: keeps unmerged local branch with hint, worktree still removed" {
  local proj="$SANDBOX/remove-unmerged"
  clone_project "$proj"
  cd "$proj" && orbit new "remove test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  # Add an unpushed commit on the scoped branch — the branch now diverges
  # from origin/main, so the verdict is "keep".
  cd "$proj/dev/myrepo" && \
    echo "local-only" > local-only.txt && \
    git add local-only.txt && \
    git commit -m "local only commit" >/dev/null 2>&1

  cd "$proj/dev" && orbit remove myrepo >/dev/null 2>&1 || true
  # Worktree gone...
  [ ! -d "$proj/dev/myrepo" ]
  # ...but the local branch remains for review.
  git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/main >/dev/null 2>&1
}

@test "remove: --force force-deletes an unmerged local branch" {
  local proj="$SANDBOX/remove-unmerged2"
  clone_project "$proj"
  cd "$proj" && orbit new "remove test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo" && \
    echo "local-only" > local-only.txt && \
    git add local-only.txt && \
    git commit -m "local only commit" >/dev/null 2>&1

  cd "$proj/dev" && orbit remove myrepo --force >/dev/null 2>&1
  [ ! -d "$proj/dev/myrepo" ]
  ! git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/main >/dev/null 2>&1
}

# --- failure modes ---

@test "remove: fails when executed at project root" {
  local proj="$SANDBOX/remove-no-ws"
  clone_project "$proj"
  cd "$proj" && orbit new "remove test" --name dev >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' remove myrepo"
  [ "$status" -ne 0 ]
}

@test "remove: fails when repo is not in pool" {
  local proj="$SANDBOX/remove-no-pool"
  clone_project "$proj"
  cd "$proj" && orbit new "remove test" --name dev >/dev/null 2>&1

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' remove nonexistent"
  [ "$status" -ne 0 ]
}

@test "remove: fails when repo is not in this workspace" {
  local proj="$SANDBOX/remove-not-in-ws"
  clone_project "$proj"
  cd "$proj" && orbit new "remove test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  # Make a second workspace that never had myrepo added.
  cd "$proj" && orbit new "second task" --name dev2 >/dev/null 2>&1
  run bash -c "cd '$proj/dev2' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' remove myrepo"
  [ "$status" -ne 0 ]
}

@test "remove: rejects unknown option" {
  local proj="$SANDBOX/remove-badopt"
  clone_project "$proj"
  cd "$proj" && orbit new "remove test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' remove myrepo --bogus"
  [ "$status" -ne 0 ]
}

@test "remove: requires a repo name" {
  local proj="$SANDBOX/remove-noname"
  clone_project "$proj"
  cd "$proj" && orbit new "remove test" --name dev >/dev/null 2>&1

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' remove"
  [ "$status" -ne 0 ]
}

# --- id re-add after remove ---

@test "remove: re-adding the same repo after remove works" {
  local proj="$SANDBOX/remove-readd"
  clone_project "$proj"
  cd "$proj" && orbit new "remove test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit remove myrepo >/dev/null 2>&1

  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  assert_dir_exists "$proj/dev/myrepo"
}

# --- completeness: pool repo registration is preserved ---

@test "remove: pool repo worktree list no longer lists the removed worktree" {
  local proj="$SANDBOX/remove-wtlist"
  clone_project "$proj"
  cd "$proj" && orbit new "remove test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev" && orbit remove myrepo >/dev/null 2>&1
  # git worktree list (from the pool) should not contain the worktree path.
  ! git -C "$proj/.repos/myrepo" worktree list --porcelain | grep -Fq "$proj/dev/myrepo"
}