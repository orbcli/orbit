#!/usr/bin/env bats

setup() {
  load test_helper/common
  common_setup
}

teardown() {
  common_teardown
}

# A single-branch clone (orbit always uses --single-branch) of a repo whose
# real default branch is non-standard leaves local origin/HEAD MISSING. The
# main/master fallbacks then miss too, so default-branch resolution must fall
# back to querying the remote directly.
setup_nonstandard_project() {
  local proj="$1" branch="$2"
  local remote="$SANDBOX/nonstd_remote_$(basename "$proj").git"
  create_bare_repo_default "$remote" "$branch"
  TEST_PROJECT="$proj"
  mkdir -p "$proj"
  cd "$proj" && orbit clone "$remote" --name nsrepo --branch "$branch" >/dev/null 2>&1
  cd "$proj" && orbit new "nonstd test" --name dev >/dev/null 2>&1
  NONSTD_REMOTE="$remote"
}

@test "add: resolves non-standard default when origin/HEAD is missing" {
  local proj="$SANDBOX/nonstd-add"
  setup_nonstandard_project "$proj" develop

  # Precondition: the single-branch clone left origin/HEAD unset in the pool.
  run git -C "$proj/.repos/nsrepo" symbolic-ref --quiet refs/remotes/origin/HEAD
  [ "$status" -ne 0 ]

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' add nsrepo"
  [ "$status" -eq 0 ]
  assert_dir_exists "$proj/dev/nsrepo"

  local branch
  branch=$(git -C "$proj/dev/nsrepo" branch --show-current)
  [ "$branch" = "ws/dev/develop" ]
}

@test "add: persists origin/HEAD repair for the next fast-path call" {
  local proj="$SANDBOX/nonstd-persist"
  setup_nonstandard_project "$proj" develop
  cd "$proj/dev" && orbit add nsrepo >/dev/null 2>&1

  # The fallback ran `git remote set-head --auto`, so origin/HEAD now resolves.
  local head
  head=$(git -C "$proj/.repos/nsrepo" symbolic-ref --quiet refs/remotes/origin/HEAD)
  [ "$head" = "refs/remotes/origin/develop" ]
}
