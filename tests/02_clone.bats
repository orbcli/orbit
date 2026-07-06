#!/usr/bin/env bats

setup_file() {
  load test_helper/common
  ensure_shared_remote
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
