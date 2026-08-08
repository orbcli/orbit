#!/usr/bin/env bats

setup_file() {
  load test_helper/common
  ensure_shared_remote
  ensure_shared_remote_with_branch
}

setup() {
  load test_helper/common
  common_setup
}

teardown() {
  common_teardown
}

@test "clone: sets push.default=upstream on cloned repo" {
  local proj="$SANDBOX/clone-test"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && orbit clone "$SHARED_REMOTE" --name backend >/dev/null 2>&1
  local push_default
  push_default=$(git -C "$proj/.repos/backend" config --get push.default)
  [ "$push_default" = "upstream" ]
}

@test "clone: does not set push.autoSetupRemote (raw mode is plain git)" {
  local proj="$SANDBOX/clone-no-autosetup"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && orbit clone "$SHARED_REMOTE" --name backend >/dev/null 2>&1
  run git -C "$proj/.repos/backend" config --get push.autoSetupRemote
  [ "$status" -ne 0 ]
}

@test "clone: fetch config converges to the wildcard map plus fetch.prune" {
  local proj="$SANDBOX/clone-fetchcfg"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && orbit clone "$SHARED_REMOTE_WITH_BRANCH" --name backend >/dev/null 2>&1
  # the map covers every branch (@{u} resolution) while the initial object
  # pull stays single-branch
  run git -C "$proj/.repos/backend" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/*:refs/remotes/origin/*" ]
  [ "$(git -C "$proj/.repos/backend" config --type=bool --get fetch.prune)" = "true" ]
  run git -C "$proj/.repos/backend" branch -r
  assert_contains "$output" "origin/main"
  refute_contains "$output" "origin/feature-x"
  refute_contains "$output" "origin/feature-y"
}

@test "clone: once mode still writes the baseline at birth" {
  local proj="$SANDBOX/clone-fetch-clone"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  orbit config git.fetchAllBranches once >/dev/null 2>&1
  orbit config git.fetchPrune once >/dev/null 2>&1
  orbit config git.pushUpstreamByDefault once >/dev/null 2>&1

  cd "$proj" && orbit clone "$SHARED_REMOTE" --name backend >/dev/null 2>&1
  run git -C "$proj/.repos/backend" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/*:refs/remotes/origin/*" ]
  [ "$(git -C "$proj/.repos/backend" config --type=bool --get fetch.prune)" = "true" ]
  [ "$(git -C "$proj/.repos/backend" config --get push.default)" = "upstream" ]
}

@test "clone: never mode writes nothing — the single-branch entry stays, no prune key" {
  local proj="$SANDBOX/clone-fetch-off"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  orbit config git.fetchAllBranches never >/dev/null 2>&1
  orbit config git.fetchPrune never >/dev/null 2>&1
  orbit config git.pushUpstreamByDefault never >/dev/null 2>&1

  cd "$proj" && orbit clone "$SHARED_REMOTE" --name backend >/dev/null 2>&1
  run git -C "$proj/.repos/backend" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/main:refs/remotes/origin/main" ]
  run git -C "$proj/.repos/backend" config --get fetch.prune
  [ "$status" -ne 0 ]
  run git -C "$proj/.repos/backend" config --get push.default
  [ "$status" -ne 0 ]
}

@test "clone: writes url to .repos/.orbit index" {
  local proj="$SANDBOX/clone-test2"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && orbit clone "$SHARED_REMOTE" --name backend2 >/dev/null 2>&1
  local idx_url
  idx_url=$(git config --file "$proj/.repos/.orbit" --get repos.backend2.url)
  [ "$idx_url" = "$SHARED_REMOTE" ]
}

@test "clone: writes head to .repos/.orbit index (non-empty)" {
  local proj="$SANDBOX/clone-test3"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && orbit clone "$SHARED_REMOTE" --name backend3 >/dev/null 2>&1
  local idx_head
  idx_head=$(git config --file "$proj/.repos/.orbit" --get repos.backend3.head 2>/dev/null || echo "")
  [ -n "$idx_head" ]
}

@test "clone: --push sets pushurl on remote" {
  local proj="$SANDBOX/clone-push"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  local fork_url="$REMOTES/frontend-fork.git"
  git init --bare "$fork_url" >/dev/null 2>&1

  cd "$proj" && orbit clone "$SHARED_REMOTE" --name frontend --push "$fork_url" >/dev/null 2>&1
  local push_url
  push_url=$(git -C "$proj/.repos/frontend" remote get-url --push origin)
  [ "$push_url" = "$fork_url" ]
}

@test "clone: --push keeps original fetch url" {
  local proj="$SANDBOX/clone-push2"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  local fork_url="$REMOTES/frontend2-fork.git"
  git init --bare "$fork_url" >/dev/null 2>&1

  cd "$proj" && orbit clone "$SHARED_REMOTE" --name frontend2 --push "$fork_url" >/dev/null 2>&1
  local fetch_url
  fetch_url=$(git -C "$proj/.repos/frontend2" remote get-url origin)
  [ "$fetch_url" = "$SHARED_REMOTE" ]
}

@test "clone: duplicate repo name fails" {
  local proj="$SANDBOX/clone-dup"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && orbit clone "$SHARED_REMOTE" --name dup-repo >/dev/null 2>&1
  run bash -c "ORBIT_ROOT='$proj' bash '$ORBIT_CMD' clone '$SHARED_REMOTE' --name dup-repo"
  [ "$status" -ne 0 ]
}

@test "clone: URL basename outside the name contract points at --name" {
  local proj="$SANDBOX/clone-dot-basename"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  # An org's .github repo: legal on GitHub, outside the pool name contract.
  local remote="$SANDBOX/remotes/.github"
  mkdir -p "$remote" && git init --bare "$remote" >/dev/null 2>&1

  run bash -c "ORBIT_ROOT='$proj' bash '$ORBIT_CMD' clone '$remote'"
  [ "$status" -ne 0 ]
  assert_contains "$output" "pick a pool name with --name"

  cd "$proj" && orbit clone "$remote" --name org-github >/dev/null 2>&1
  assert_dir_exists "$proj/.repos/org-github"
}
