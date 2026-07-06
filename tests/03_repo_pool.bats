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

# --- repos command ---

@test "repos: shows NAME header in output" {
  local proj="$SANDBOX/repos-test"
  clone_project "$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' repos 2>/dev/null"
  assert_contains "$output" "NAME"
}

@test "repos: shows repo name in listing" {
  local proj="$SANDBOX/repos-test2"
  clone_project "$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' repos 2>/dev/null"
  assert_contains "$output" "myrepo"
}

@test "repos: warns about README fallback when no memo" {
  local proj="$SANDBOX/repos-test3"
  clone_project "$proj"

  local stderr_output
  stderr_output=$(cd "$proj" && orbit repos 2>&1 >/dev/null || true)
  assert_contains "$stderr_output" "no memo found"
}

@test "repos: shows brief from index after memo is written" {
  local proj="$SANDBOX/repos-test4"
  clone_project "$proj"
  printf '# myrepo\n\nProper brief here.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' repos 2>/dev/null"
  assert_contains "$output" "Proper brief here."
}

# --- info command ---

@test "info: outputs .md content when memo file exists" {
  local proj="$SANDBOX/info-test"
  clone_project "$proj"
  printf '# myrepo\n\nInfo test content.\n' > "$proj/.repos/.myrepo.md"
  git config --file "$proj/.repos/.orbit" repos.myrepo.head "$(git -C "$proj/.repos/myrepo" rev-parse --short HEAD)"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' info myrepo"
  assert_contains "$output" "Info test content."
}

@test "info: falls back to README when no .md file" {
  local proj="$SANDBOX/info-test2"
  clone_project "$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' info myrepo 2>/dev/null"
  assert_contains "$output" "A mock repository for testing."
}

@test "info: non-existent repo fails" {
  local proj="$SANDBOX/info-test3"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  run bash -c "ORBIT_ROOT='$proj' bash '$ORBIT_CMD' info nosuchrepo"
  [ "$status" -ne 0 ]
}

# --- memo command ---

@test "memo: writes per-repo .md file" {
  local proj="$SANDBOX/memo-test"
  clone_project "$proj"

  printf '# myrepo\n\nA test repository for memos.\n\n## Details\nSome details.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1
  assert_file_exists "$proj/.repos/.myrepo.md"
}

@test "memo: extracts brief to index" {
  local proj="$SANDBOX/memo-test2"
  clone_project "$proj"

  printf '# myrepo\n\nA test repository for memos.\n\n## Details\nSome details.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1
  local brief
  brief=$(git config --file "$proj/.repos/.orbit" --get repos.myrepo.brief)
  [ "$brief" = "A test repository for memos." ]
}

@test "memo: --refresh restores brief from existing .md file" {
  local proj="$SANDBOX/memo-test3"
  clone_project "$proj"
  printf '# myrepo\n\nA test repository for memos.\n\n## Details\nSome details.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1

  git config --file "$proj/.repos/.orbit" --unset repos.myrepo.brief 2>/dev/null || true
  cd "$proj" && orbit memo myrepo --refresh >/dev/null 2>&1
  local brief
  brief=$(git config --file "$proj/.repos/.orbit" --get repos.myrepo.brief)
  [ "$brief" = "A test repository for memos." ]
}

@test "memo: no-args refreshes all repos (head restored)" {
  local proj="$SANDBOX/memo-test4"
  clone_project "$proj"
  printf '# myrepo\n\nA test repository for memos.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1

  git config --file "$proj/.repos/.orbit" --unset repos.myrepo.head 2>/dev/null || true
  cd "$proj" && orbit memo >/dev/null 2>&1
  local head_after
  head_after=$(git config --file "$proj/.repos/.orbit" --get repos.myrepo.head 2>/dev/null || echo "")
  [ -n "$head_after" ]
}

@test "memo: rejects empty input" {
  local proj="$SANDBOX/memo-test5"
  clone_project "$proj"

  run bash -c "echo '' | ORBIT_ROOT='$proj' bash '$ORBIT_CMD' memo myrepo"
  [ "$status" -ne 0 ]
}

# --- repos --json staleness ---

@test "repos --json: complete repo shows incomplete false and memoBehind 0" {
  local proj="$SANDBOX/stale-test1"
  clone_project "$proj"
  printf '# myrepo\n\nFresh repo description.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' repos --json 2>/dev/null"
  [ "$status" -eq 0 ]
  assert_contains "$output" '"incomplete":false'
  assert_contains "$output" '"memoBehind":0'
}

@test "repos --json: stale repo shows memoBehind greater than 0" {
  local proj="$SANDBOX/stale-test2"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  # This test needs its own remote because it pushes new commits
  local remote="$REMOTES/stale-repo2.git"
  clone_remote "$remote"
  cd "$proj" && orbit clone "$remote" --name myrepo >/dev/null 2>&1
  printf '# myrepo\n\nStale repo description.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1

  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_stale_XXXXXX")
  git clone "$remote" "$tmp" >/dev/null 2>&1
  (
    cd "$tmp"
    echo "new content" > newfile.txt
    git add newfile.txt >/dev/null 2>&1
    git commit -m "second commit" >/dev/null 2>&1
    git push origin main >/dev/null 2>&1
  )
  rm -rf "$tmp"

  git -C "$proj/.repos/myrepo" fetch origin >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" merge --ff-only origin/main >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' repos --json 2>/dev/null"
  [ "$status" -eq 0 ]
  assert_contains "$output" '"memoBehind":1'
}

@test "repos --json: repo without memo shows incomplete true" {
  local proj="$SANDBOX/memo-test1"
  clone_project "$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' repos --json 2>/dev/null"
  [ "$status" -eq 0 ]
  assert_contains "$output" '"incomplete":true'
}
