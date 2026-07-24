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

# --- Helper: set up a project with a cloned repo and a done workspace ---

setup_project_with_done_workspace() {
  local proj="$1" ws_name="${2:-dev}" repo_name="${3:-myrepo}"
  local remote="$REMOTES/${repo_name}.git"
  clone_remote "$remote"
  clone_project "$proj"
  # Point pool repo to mutable remote copy
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  (cd "$proj" && TEST_PROJECT="$proj" orbit new "test goal" --name "$ws_name") >/dev/null 2>&1
  (cd "$proj/$ws_name" && TEST_PROJECT="$proj" orbit add "$repo_name") >/dev/null 2>&1
  (cd "$proj/$ws_name" && TEST_PROJECT="$proj" orbit done) >/dev/null 2>&1
}

# --- Basic prune ---

@test "prune: removes a single done workspace" {
  local proj="$SANDBOX/prune-basic"
  local remote="$REMOTES/prune-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "prune test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune"
  [ "$status" -eq 0 ]
  [ ! -d "$proj/dev" ]
  assert_contains "$output" "pruned: dev"
}

@test "prune: does NOT touch active workspaces" {
  local proj="$SANDBOX/prune-active"
  clone_project "$proj"
  cd "$proj" && orbit new "active goal" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune"
  [ "$status" -eq 0 ]
  assert_dir_exists "$proj/dev"
  assert_contains "$output" "nothing to prune"
}

# --- --older filtering ---

@test "prune: --older prunes expired workspace" {
  local proj="$SANDBOX/prune-older-expired"
  local remote="$REMOTES/prune-older-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "older test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1

  local ten_days_ago=$(( $(date +%s) - 864000 ))
  git config --file "$proj/dev/.orbit" workspace.done-at "$ten_days_ago"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --older 1d"
  [ "$status" -eq 0 ]
  [ ! -d "$proj/dev" ]
  assert_contains "$output" "pruned: dev"
}

@test "prune: --older does NOT prune recent workspace" {
  local proj="$SANDBOX/prune-older-recent"
  local remote="$REMOTES/prune-recent-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "recent test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --older 30d"
  [ "$status" -eq 0 ]
  assert_dir_exists "$proj/dev"
  assert_contains "$output" "nothing to prune"
}

# --- --dry-run ---

@test "prune: --dry-run does not delete workspace" {
  local proj="$SANDBOX/prune-dryrun"
  local remote="$REMOTES/prune-dryrun-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "dryrun test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run"
  [ "$status" -eq 0 ]
  assert_dir_exists "$proj/dev"
  assert_contains "$output" "would prune: dev"
}

# --- --force ---

@test "prune: --force deletes unmerged branch" {
  local proj="$SANDBOX/prune-force"
  local remote="$REMOTES/prune-force-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "force test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  echo "unmerged" > "$proj/dev/myrepo/unmerged.txt"
  git -C "$proj/dev/myrepo" add unmerged.txt
  git -C "$proj/dev/myrepo" commit -m "unmerged work" >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --force"
  [ "$status" -eq 0 ]
  [ ! -d "$proj/dev" ]
  assert_contains "$output" "force"

  run git -C "$proj/.repos/myrepo" branch --list "ws/dev/main"
  [ -z "$output" ]
}

# --- Specific workspace by name ---

@test "prune: specific workspace name prunes only that one" {
  local proj="$SANDBOX/prune-named"
  local remote="$REMOTES/prune-named-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  cd "$proj" && orbit new "ws one" --name ws-one >/dev/null 2>&1
  cd "$proj/ws-one" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/ws-one" && orbit done >/dev/null 2>&1

  cd "$proj" && orbit new "ws two" --name ws-two >/dev/null 2>&1
  cd "$proj/ws-two" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/ws-two" && orbit done >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune ws-one"
  [ "$status" -eq 0 ]
  [ ! -d "$proj/ws-one" ]
  assert_dir_exists "$proj/ws-two"
  assert_contains "$output" "pruned: ws-one"
}

@test "prune: error when pruning non-done workspace by name" {
  local proj="$SANDBOX/prune-nondone"
  clone_project "$proj"
  cd "$proj" && orbit new "active ws" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune dev"
  [ "$status" -ne 0 ]
  assert_contains "$output" "not found or not marked done"
}

# --- Branch protection: merged ---

@test "prune: merged branch gets deleted" {
  local proj="$SANDBOX/prune-merged"
  local remote="$REMOTES/prune-merged-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "merge test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  echo "feature" > "$proj/dev/myrepo/feature.txt"
  git -C "$proj/dev/myrepo" add feature.txt
  git -C "$proj/dev/myrepo" commit -m "add feature" >/dev/null 2>&1

  local ws_commit
  ws_commit=$(git -C "$proj/dev/myrepo" rev-parse HEAD)
  git -C "$proj/.repos/myrepo" update-ref refs/heads/main "$ws_commit"
  git -C "$proj/.repos/myrepo" push origin main >/dev/null 2>&1

  git -C "$proj/.repos/myrepo" fetch origin >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune"
  [ "$status" -eq 0 ]
  [ ! -d "$proj/dev" ]
  assert_contains "$output" "deleted branch (merged)"

  local branches
  branches=$(git -C "$proj/.repos/myrepo" branch --list "ws/dev/main" | tr -d ' ')
  [ -z "$branches" ]
}

# --- Branch protection: unmerged (no --force) ---

@test "prune: unmerged branch NOT deleted without --force" {
  local proj="$SANDBOX/prune-unmerged"
  local remote="$REMOTES/prune-unmerged-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "unmerged test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  echo "unmerged work" > "$proj/dev/myrepo/unmerged.txt"
  git -C "$proj/dev/myrepo" add unmerged.txt
  git -C "$proj/dev/myrepo" commit -m "unmerged work" >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  [ ! -d "$proj/dev" ]
  assert_contains "$output" "skipping unmerged branch"
}

# --- Worktree removal ---

@test "prune: worktree no longer listed after prune" {
  local proj="$SANDBOX/prune-worktree"
  local remote="$REMOTES/prune-wt-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "worktree test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run git -C "$proj/.repos/myrepo" worktree list
  assert_contains "$output" "dev/myrepo"

  cd "$proj/dev" && orbit done >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --force"
  [ "$status" -eq 0 ]

  run git -C "$proj/.repos/myrepo" worktree list
  if printf '%s' "$output" | grep -q "dev/myrepo"; then
    echo "worktree still listed: $output"
    return 1
  fi
}

# --- Multiple repos in workspace ---

@test "prune: workspace with multiple repos cleans all" {
  local proj="$SANDBOX/prune-multi"
  local remote1="$REMOTES/multi-repo1.git"
  local remote2="$REMOTES/multi-repo2.git"
  clone_remote "$remote1"
  clone_remote "$remote2"

  clone_project "$proj"
  # Add second repo to pool
  cd "$proj" && orbit clone "$remote2" --name repo2 >/dev/null 2>&1
  cd "$proj" && orbit new "multi repo test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit add repo2 >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --force"
  [ "$status" -eq 0 ]
  [ ! -d "$proj/dev" ]
  assert_contains "$output" "pruned: dev"

  run git -C "$proj/.repos/myrepo" worktree list
  if printf '%s' "$output" | grep -q "dev/myrepo"; then
    echo "myrepo worktree still listed"
    return 1
  fi
  run git -C "$proj/.repos/repo2" worktree list
  if printf '%s' "$output" | grep -q "dev/repo2"; then
    echo "repo2 worktree still listed"
    return 1
  fi
}

# --- Edge cases ---

@test "prune: nothing to prune when project has no workspaces" {
  local proj="$SANDBOX/prune-empty"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune"
  [ "$status" -eq 0 ]
  assert_contains "$output" "nothing to prune"
}

@test "prune: error on nonexistent workspace name" {
  local proj="$SANDBOX/prune-noexist"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune nonexist"
  [ "$status" -ne 0 ]
  assert_contains "$output" "not found or not marked done"
}

@test "prune: --dry-run with --force shows force-delete message" {
  local proj="$SANDBOX/prune-dryforce"
  local remote="$REMOTES/prune-dryforce-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "dryforce test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  echo "work" > "$proj/dev/myrepo/work.txt"
  git -C "$proj/dev/myrepo" add work.txt
  git -C "$proj/dev/myrepo" commit -m "work" >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run --force"
  [ "$status" -eq 0 ]
  assert_dir_exists "$proj/dev"
  assert_contains "$output" "would prune: dev"
  assert_contains "$output" "would force-delete branch"
}

# --- Readable report format (human-facing output proposal) ---

@test "prune: --dry-run report is header-first, repo-grouped, single-stream" {
  local proj="$SANDBOX/prune-dryfmt"
  local remote="$REMOTES/prune-dryfmt-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "dryfmt test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  echo "unmerged" > "$proj/dev/myrepo/unmerged.txt"
  git -C "$proj/dev/myrepo" add unmerged.txt
  git -C "$proj/dev/myrepo" commit -m "unmerged work" >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1

  # stderr discarded: a dry-run report must be complete on stdout alone
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run 2>/dev/null"
  [ "$status" -eq 0 ]
  assert_dir_exists "$proj/dev"
  assert_contains "$output" "would prune: dev (1 repo)"
  assert_contains "$output" "  myrepo:"
  assert_contains "$output" "    would remove worktree"
  assert_contains "$output" "    would skip unmerged branch: ws/dev/main"
  assert_contains "$output" "would remove workspace directory"
  # branch config cleanup is coupled to deletion and never printed
  case "$output" in
    *"would remove branch config"*) false ;;
  esac
  # header precedes all detail lines
  local header_line detail_line
  header_line=$(printf '%s\n' "$output" | grep -n "would prune: dev" | head -1 | cut -d: -f1)
  detail_line=$(printf '%s\n' "$output" | grep -n "would skip unmerged branch" | head -1 | cut -d: -f1)
  [ "$header_line" -lt "$detail_line" ]
}

@test "prune: real run ends with a summary count" {
  local proj="$SANDBOX/prune-summary"
  local remote="$REMOTES/prune-summary-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "summary test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  echo "feature" > "$proj/dev/myrepo/feature.txt"
  git -C "$proj/dev/myrepo" add feature.txt
  git -C "$proj/dev/myrepo" commit -m "add feature" >/dev/null 2>&1

  local ws_commit
  ws_commit=$(git -C "$proj/dev/myrepo" rev-parse HEAD)
  git -C "$proj/.repos/myrepo" update-ref refs/heads/main "$ws_commit"
  git -C "$proj/.repos/myrepo" push origin main >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" fetch origin >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune"
  [ "$status" -eq 0 ]
  [ ! -d "$proj/dev" ]
  assert_contains "$output" "pruned: dev (1 worktree removed, 1 branch deleted, 0 skipped)"
}

# --- Stale fetch refspec cleanup ---

@test "prune: removes stale fetch refspec left by a remote-deleted branch" {
  local proj="$SANDBOX/prune-refspec"
  local remote="$REMOTES/prune-refspec-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "refspec test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1

  # Simulate residue: refspec + stale tracking ref for a branch the remote no
  # longer has (typical: branch auto-deleted on PR merge)
  git -C "$proj/.repos/myrepo" config --add remote.origin.fetch \
    "+refs/heads/gone:refs/remotes/origin/gone"
  git -C "$proj/.repos/myrepo" update-ref refs/remotes/origin/gone \
    "$(git -C "$proj/.repos/myrepo" rev-parse HEAD)"

  # the residue breaks every bare fetch (the bug being fixed)
  run git -C "$proj/.repos/myrepo" fetch origin
  [ "$status" -ne 0 ]

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune"
  [ "$status" -eq 0 ]
  assert_contains "$output" "    removed stale fetch refspec: gone"

  # refspec and stale ref are gone; the live main refspec is untouched
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/main:refs/remotes/origin/main" ]
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/remotes/origin/gone
  [ "$status" -ne 0 ]

  # bare fetch works again
  run git -C "$proj/.repos/myrepo" fetch origin
  [ "$status" -eq 0 ]
}

@test "prune --dry-run: reports stale fetch refspec without removing it" {
  local proj="$SANDBOX/prune-refspec-dry"
  local remote="$REMOTES/prune-refspec-dry-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "refspec dry test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1

  git -C "$proj/.repos/myrepo" config --add remote.origin.fetch \
    "+refs/heads/gone:refs/remotes/origin/gone"
  git -C "$proj/.repos/myrepo" update-ref refs/remotes/origin/gone \
    "$(git -C "$proj/.repos/myrepo" rev-parse HEAD)"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run"
  [ "$status" -eq 0 ]
  assert_contains "$output" "    would remove stale fetch refspec: gone"

  # nothing was removed
  git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch \
    | grep -Fqx "+refs/heads/gone:refs/remotes/origin/gone"
  git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/remotes/origin/gone >/dev/null
}

@test "prune: removes legacy pre-registered refspec for a never-pushed branch" {
  local proj="$SANDBOX/prune-legacy-refspec"
  local remote="$REMOTES/prune-legacy-refspec-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  # active workspace with a scoped branch that was never pushed
  cd "$proj" && orbit new "live work" --name live >/dev/null 2>&1
  cd "$proj/live" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/live/myrepo" && orbit switch -c feat-live >/dev/null 2>&1

  # a second, done workspace over the same pool repo
  cd "$proj" && orbit new "old work" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1

  # Legacy residue (older orbit pre-registered refspecs at switch -c): a local
  # branch tracks feat-live but the remote has never had it — every bare fetch
  # fails while this entry exists.
  git -C "$proj/.repos/myrepo" config --add remote.origin.fetch \
    "+refs/heads/feat-live:refs/remotes/origin/feat-live"
  run git -C "$proj/.repos/myrepo" fetch origin
  [ "$status" -ne 0 ]

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune"
  [ "$status" -eq 0 ]
  assert_dir_exists "$proj/live"
  assert_contains "$output" "    removed stale fetch refspec: feat-live"

  # the local branch itself is untouched; only the fetch-breaking entry is gone
  git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/live/feat-live >/dev/null
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/main:refs/remotes/origin/main" ]
  run git -C "$proj/.repos/myrepo" fetch origin
  [ "$status" -eq 0 ]
}
