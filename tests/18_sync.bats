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

# --- sync command ---

@test "sync: fast-forwards pool repo to latest upstream" {
  local proj="$SANDBOX/sync-ff"
  local remote="$REMOTES/sync-ff.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_sync_XXXXXX")
  git clone "$remote" "$tmp" >/dev/null 2>&1
  (
    cd "$tmp"
    echo "new content" > newfile.txt
    git add newfile.txt >/dev/null 2>&1
    git commit -m "second commit" >/dev/null 2>&1
    git push origin main >/dev/null 2>&1
  )
  local remote_head
  remote_head=$(git -C "$tmp" rev-parse HEAD)
  rm -rf "$tmp"

  cd "$proj" && orbit sync myrepo >/dev/null 2>&1

  local pool_head
  pool_head=$(git -C "$proj/.repos/myrepo" rev-parse HEAD)
  [ "$pool_head" = "$remote_head" ]
}

@test "sync: warns on ff-only conflict" {
  local proj="$SANDBOX/sync-conflict"
  local remote="$REMOTES/sync-conflict.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  # Create divergence: local commit
  (
    cd "$proj/.repos/myrepo"
    echo "local" > local.txt
    git add local.txt >/dev/null 2>&1
    git commit -m "local commit" >/dev/null 2>&1
  )

  # Remote commit
  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_sync_XXXXXX")
  git clone "$remote" "$tmp" >/dev/null 2>&1
  (
    cd "$tmp"
    echo "remote" > remote.txt
    git add remote.txt >/dev/null 2>&1
    git commit -m "remote commit" >/dev/null 2>&1
    git push origin main >/dev/null 2>&1
  )
  rm -rf "$tmp"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo 2>&1"
  [ "$status" -ne 0 ]
  assert_contains "$output" "fast-forward failed"
}

@test "sync --force: resets to upstream" {
  local proj="$SANDBOX/sync-force"
  local remote="$REMOTES/sync-force.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  # Create divergence
  (
    cd "$proj/.repos/myrepo"
    echo "local" > local.txt
    git add local.txt >/dev/null 2>&1
    git commit -m "local commit" >/dev/null 2>&1
  )

  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_sync_XXXXXX")
  git clone "$remote" "$tmp" >/dev/null 2>&1
  (
    cd "$tmp"
    echo "remote" > remote.txt
    git add remote.txt >/dev/null 2>&1
    git commit -m "remote commit" >/dev/null 2>&1
    git push origin main >/dev/null 2>&1
  )
  local remote_head
  remote_head=$(git -C "$tmp" rev-parse HEAD)
  rm -rf "$tmp"

  cd "$proj" && orbit sync myrepo --force >/dev/null 2>&1

  local pool_head
  pool_head=$(git -C "$proj/.repos/myrepo" rev-parse HEAD)
  [ "$pool_head" = "$remote_head" ]
}

@test "sync --branch: switches tracking branch" {
  local proj="$SANDBOX/sync-branch"
  local remote="$REMOTES/sync-branch.git"
  clone_remote "$remote" "$SHARED_REMOTE_WITH_BRANCH"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  cd "$proj" && orbit sync myrepo --branch feature-x >/dev/null 2>&1

  local current_branch
  current_branch=$(git -C "$proj/.repos/myrepo" branch --show-current)
  [ "$current_branch" = "feature-x" ]
}

@test "sync: infers all repos at project root" {
  local proj="$SANDBOX/sync-root"
  local remote1="$REMOTES/sync-root1.git"
  local remote2="$REMOTES/sync-root2.git"
  clone_remote "$remote1"
  clone_remote "$remote2"
  clone_project "$proj"
  cd "$proj" && orbit clone "$remote2" --name repo2 >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote1" >/dev/null 2>&1
  git -C "$proj/.repos/repo2" remote set-url origin "$remote2" >/dev/null 2>&1

  # Push new commits to both remotes
  for r in "$remote1" "$remote2"; do
    local tmp
    tmp=$(mktemp -d "$SANDBOX/_tmp_sync_XXXXXX")
    git clone "$r" "$tmp" >/dev/null 2>&1
    (
      cd "$tmp"
      echo "update" > update.txt
      git add update.txt >/dev/null 2>&1
      git commit -m "update" >/dev/null 2>&1
      git push origin main >/dev/null 2>&1
    )
    rm -rf "$tmp"
  done

  local old_head1 old_head2
  old_head1=$(git -C "$proj/.repos/myrepo" rev-parse HEAD)
  old_head2=$(git -C "$proj/.repos/repo2" rev-parse HEAD)

  cd "$proj" && orbit sync >/dev/null 2>&1

  local new_head1 new_head2
  new_head1=$(git -C "$proj/.repos/myrepo" rev-parse HEAD)
  new_head2=$(git -C "$proj/.repos/repo2" rev-parse HEAD)

  [ "$new_head1" != "$old_head1" ]
  [ "$new_head2" != "$old_head2" ]
}

@test "sync: infers workspace repos when in workspace" {
  local proj="$SANDBOX/sync-ws"
  local remote1="$REMOTES/sync-ws1.git"
  local remote2="$REMOTES/sync-ws2.git"
  clone_remote "$remote1"
  clone_remote "$remote2"
  clone_project "$proj"
  cd "$proj" && orbit clone "$remote2" --name repo2 >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote1" >/dev/null 2>&1
  git -C "$proj/.repos/repo2" remote set-url origin "$remote2" >/dev/null 2>&1

  cd "$proj" && orbit new "test sync" --name ws1 >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1

  # Push new commit to remote1 only
  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_sync_XXXXXX")
  git clone "$remote1" "$tmp" >/dev/null 2>&1
  (
    cd "$tmp"
    echo "update" > update.txt
    git add update.txt >/dev/null 2>&1
    git commit -m "update" >/dev/null 2>&1
    git push origin main >/dev/null 2>&1
  )
  rm -rf "$tmp"

  local old_head1 old_head2
  old_head1=$(git -C "$proj/.repos/myrepo" rev-parse HEAD)
  old_head2=$(git -C "$proj/.repos/repo2" rev-parse HEAD)

  cd "$proj/ws1" && orbit sync >/dev/null 2>&1

  local new_head1 new_head2
  new_head1=$(git -C "$proj/.repos/myrepo" rev-parse HEAD)
  new_head2=$(git -C "$proj/.repos/repo2" rev-parse HEAD)

  [ "$new_head1" != "$old_head1" ]
  [ "$new_head2" = "$old_head2" ]
}

# --- info fetch behavior ---

@test "info: shows upstream behind warning after fetch" {
  local proj="$SANDBOX/info-fetch"
  local remote="$REMOTES/info-fetch.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_info_XXXXXX")
  git clone "$remote" "$tmp" >/dev/null 2>&1
  (
    cd "$tmp"
    echo "new" > new.txt
    git add new.txt >/dev/null 2>&1
    git commit -m "new commit" >/dev/null 2>&1
    git push origin main >/dev/null 2>&1
  )
  rm -rf "$tmp"

  local stderr_output
  stderr_output=$(cd "$proj" && orbit info myrepo 2>&1 >/dev/null || true)
  assert_contains "$stderr_output" "1 new commits on origin/main"
}

@test "info --json: includes remoteAhead and memoBehind fields" {
  local proj="$SANDBOX/info-json"
  local remote="$REMOTES/info-json.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  printf '# myrepo\n\nTest repo.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' info myrepo --json 2>/dev/null"
  [ "$status" -eq 0 ]
  assert_contains "$output" '"remoteAhead":'
  assert_contains "$output" '"memoBehind":'
}
