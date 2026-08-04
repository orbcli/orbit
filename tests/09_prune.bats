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

  # session running prune must not be parked inside a workspace
  cd "$SANDBOX"
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

  # session running prune must not be parked inside a workspace
  cd "$SANDBOX"
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

  cd "$SANDBOX"
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

  cd "$SANDBOX"
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

  cd "$SANDBOX"
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

  cd "$SANDBOX"
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

  cd "$SANDBOX"
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

  cd "$SANDBOX"
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

  # session running prune must not be parked inside a workspace
  cd "$SANDBOX"
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

  cd "$SANDBOX"
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

  cd "$SANDBOX"
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

  cd "$SANDBOX"
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

  # session running prune must not be parked inside a workspace
  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune"
  [ "$status" -eq 0 ]
  assert_contains "$output" "nothing to prune"
}

@test "prune: error on nonexistent workspace name" {
  local proj="$SANDBOX/prune-noexist"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$SANDBOX"
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

  cd "$SANDBOX"
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
  cd "$SANDBOX"
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

  # session running prune must not be parked inside a workspace
  cd "$SANDBOX"
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

  # session running prune must not be parked inside a workspace
  cd "$SANDBOX"
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

  cd "$SANDBOX"
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

  # session running prune must not be parked inside a workspace
  cd "$SANDBOX"
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

# --- Root-level isolation (workspace = scope boundary) ---

@test "prune: refuses to run from inside a workspace" {
  local proj="$SANDBOX/prune-inside-ws"
  clone_project "$proj"
  (cd "$proj" && orbit new "inside test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  # Parked-ancestor topology: the trailing exit keeps bash from exec-collapsing
  # the last command (Linux), which would replace this shell with orbit and
  # leave a clean ancestry — the assertion is platform-dependent without it.
  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune; rc=\$?; exit \$rc"
  [ "$status" -ne 0 ]
  assert_contains "$output" "prune should not be initiated from inside workspace dev"
  assert_dir_exists "$proj/dev"
}

# --- Session protection via process ancestry ---

@test "prune: refuses named target when the session is rooted in it, even from project root" {
  local proj="$SANDBOX/prune-rooted"
  clone_project "$proj"
  (cd "$proj" && orbit new "rooted test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  # the incident shape: a process parked inside the workspace spawns a child
  # that cds to the project root and prunes the workspace — cwd checks pass,
  # ancestry must catch it. The trailing exit keeps bash from exec-collapsing
  # the subshell (which would erase the parked ancestor).
  # Do NOT "simplify" this into a flat cd chain: the outer shell must stay
  # parked in dev as a live ancestor, or the test silently stops covering
  # the ancestry guard.
  run bash -c "cd '$proj/dev' && (cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune dev); rc=\$?; exit \$rc"
  [ "$status" -ne 0 ]
  assert_contains "$output" "prune should not be initiated from inside workspace dev"
  assert_dir_exists "$proj/dev"
}

@test "prune: refuses enumeration outright when a shell ancestor is rooted in a workspace" {
  local proj="$SANDBOX/prune-rooted-enum"
  clone_project "$proj"
  (cd "$proj" && orbit new "rooted enum test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  # same parked-ancestor topology as above — keep the subshell + trailing exit.
  # Initiation-context guard: the whole invocation is invalid (no per-candidate
  # skip-and-continue), because the process tree stands inside a workspace.
  run bash -c "cd '$proj/dev' && (cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1); rc=\$?; exit \$rc"
  [ "$status" -ne 0 ]
  assert_contains "$output" "prune should not be initiated from inside workspace dev"
  assert_dir_exists "$proj/dev"
}

@test "prune: refuses to prune ANOTHER workspace when rooted in one (target-independent guard)" {
  local proj="$SANDBOX/prune-rooted-other"
  clone_project "$proj"
  (cd "$proj" && orbit new "home" --name dev >/dev/null 2>&1)
  (cd "$proj" && orbit new "other" --name other >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  (cd "$proj/other" && orbit add myrepo >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)
  (cd "$proj/other" && orbit done >/dev/null 2>&1)

  # parked in dev, pruning done "other" from the root: the guard no longer
  # asks WHICH workspace is targeted — standing inside any workspace is enough
  run bash -c "cd '$proj/dev' && (cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune other); rc=\$?; exit \$rc"
  [ "$status" -ne 0 ]
  assert_contains "$output" "prune should not be initiated from inside workspace dev"
  assert_dir_exists "$proj/other"
  assert_dir_exists "$proj/dev"
}

@test "prune: announces an inactive initiation guard when ancestry is unreadable" {
  # On a /proc host the ancestry is always readable — the blind-spot path
  # cannot be constructed there.
  [ ! -d "/proc/$$" ] || skip "/proc present: ancestry is readable on this host"

  local proj="$SANDBOX/prune-no-ancestry"
  clone_project "$proj"
  (cd "$proj" && orbit new "blind guard" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  # Shadow every cwd-reading facility this host has: with nothing readable the
  # guard must say it is inactive instead of silently checking nothing.
  local stubs="$SANDBOX/no-ancestry-bin"
  mkdir -p "$stubs"
  printf '#!/bin/sh\nexit 1\n' > "$stubs/ps"
  printf '#!/bin/sh\nexit 1\n' > "$stubs/lsof"
  chmod +x "$stubs/ps" "$stubs/lsof"

  cd "$SANDBOX"
  run bash -c "cd '$proj' && PATH='$stubs':\$PATH ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "cannot read process ancestry on this host: the initiation guard is inactive"
}

@test "prune: blind ancestry withholds the cd replay and states the fact alone" {
  [ ! -d "/proc/$$" ] || skip "/proc present: ancestry is readable on this host"

  local proj="$SANDBOX/prune-blind-no-replay"
  clone_project "$proj"
  (cd "$proj" && orbit new "replay" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  local stubs="$SANDBOX/no-ancestry-bin"
  mkdir -p "$stubs"
  printf '#!/bin/sh\nexit 1\n' > "$stubs/ps"
  printf '#!/bin/sh\nexit 1\n' > "$stubs/lsof"
  chmod +x "$stubs/ps" "$stubs/lsof"

  # cwd misplaced AND ancestry blind: the guard cannot vouch the session is
  # clean, so it must NOT hand back a ready-to-run `cd <root> && orbit ...`.
  run bash -c "cd '$proj/dev' && PATH='$stubs':\$PATH ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run 2>&1"
  [ "$status" -ne 0 ]
  assert_contains "$output" "prune must be run from the project root"
  [[ "$output" != *"&&"* ]]
  [[ "$output" != *"cd $proj"* ]]
  assert_dir_exists "$proj/dev"
}

@test "prune: root-level guard replays the intended command when the session is clean" {
  # Construct "orbit's own cwd misplaced, ancestry readable and clean" via a
  # cd-then-exec: the outer shell stays at the root, only orbit's cwd is inside
  # the workspace. Needs some ancestry facility — with none, the blind path
  # (previous test) applies instead.
  { [ -d "/proc/$$" ] || command -v lsof >/dev/null 2>&1; } || skip "no ancestry facility to prove a clean session"

  local proj="$SANDBOX/prune-cd-replay"
  clone_project "$proj"
  (cd "$proj" && orbit new "replay" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  run bash -c "cd '$proj' && (cd '$proj/dev' && ORBIT_ROOT='$proj' exec bash '$ORBIT_CMD' prune dev) 2>&1"
  [ "$status" -ne 0 ]
  assert_contains "$output" "prune must be run from the project root — cd $proj && orbit prune dev"
  assert_dir_exists "$proj/dev"
}

@test "prune: refuses when the cwd itself is unreadable (deleted directory)" {
  local proj="$SANDBOX/prune-deleted-cwd"
  clone_project "$proj"
  (cd "$proj" && orbit new "deleted cwd" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)
  mkdir -p "$proj/dev/sub"

  # An unreadable cwd cannot be proven to be outside a workspace: `pwd -P` fails,
  # so the guard must answer "inside" rather than guess "outside" and proceed.
  cd "$SANDBOX"
  run bash -c "cd '$proj/dev/sub' && rmdir '$proj/dev/sub' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -ne 0 ]
  assert_contains "$output" "prune must be run from the project root"
  assert_dir_exists "$proj/dev"
}

@test "prune: refuses from a non-workspace junk dir at the root (structural, no .orbit needed)" {
  local proj="$SANDBOX/prune-junk-dir"
  clone_project "$proj"
  # a plain directory at the project root — never an orbit workspace, no .orbit.
  # Metadata is disposable, so the guard is structural: a non-reserved child of
  # the root is refused regardless of any marker.
  mkdir -p "$proj/notes"
  run bash -c "cd '$proj/notes' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -ne 0 ]
  assert_contains "$output" "should not be initiated from inside workspace notes"
  assert_dir_exists "$proj/notes"
}

# --- Data protection: uncommitted changes ---

@test "prune: skips workspace with uncommitted changes (no --force)" {
  local proj="$SANDBOX/prune-dirty"
  clone_project "$proj"
  (cd "$proj" && orbit new "dirty test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  echo "dirty" > "$proj/dev/myrepo/dirty.txt"
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "skipping dev: uncommitted changes in: myrepo"
  assert_dir_exists "$proj/dev"
  assert_file_exists "$proj/dev/myrepo/dirty.txt"
}

@test "prune: --dry-run reports uncommitted changes as would skip" {
  local proj="$SANDBOX/prune-dirty-dry"
  clone_project "$proj"
  (cd "$proj" && orbit new "dirty dry test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  echo "dirty" > "$proj/dev/myrepo/dirty.txt"
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run"
  [ "$status" -eq 0 ]
  assert_contains "$output" "would skip: dev (uncommitted changes in: myrepo)"
  assert_dir_exists "$proj/dev"
}

@test "prune: squash-merged branch skip names the content-upstream cleanup" {
  local proj="$SANDBOX/prune-squash"
  local remote="$REMOTES/prune-squash-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  (cd "$proj" && orbit new "squash test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)

  echo "feature" > "$proj/dev/myrepo/feature.txt"
  git -C "$proj/dev/myrepo" add feature.txt
  git -C "$proj/dev/myrepo" commit -m "feature" >/dev/null 2>&1

  # squash-merge simulation: the branch's exact tree lands on master under a
  # new SHA — content upstream, form diverged (ancestor check must fail)
  local branch_tree new_master
  branch_tree=$(git -C "$proj/dev/myrepo" rev-parse 'HEAD^{tree}')
  new_master=$(git -C "$proj/.repos/myrepo" commit-tree "$branch_tree" \
    -p "$(git -C "$proj/.repos/myrepo" rev-parse main)" -m "squashed feature")
  git -C "$proj/.repos/myrepo" update-ref refs/heads/main "$new_master"
  git -C "$proj/.repos/myrepo" push origin main >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" fetch origin >/dev/null 2>&1

  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  [ ! -d "$proj/dev" ]
  assert_contains "$output" "skipping unmerged branch: ws/dev/main (content already upstream"
  assert_contains "$output" "git -C \"$proj/.repos/myrepo\" branch -D \"ws/dev/main\""
}

@test "prune: no content-upstream hint when the upstream ref is unresolvable" {
  local proj="$SANDBOX/prune-squash-noref"
  local remote="$REMOTES/prune-squash-noref-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  (cd "$proj" && orbit new "noref test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)

  echo "feature" > "$proj/dev/myrepo/feature.txt"
  git -C "$proj/dev/myrepo" add feature.txt
  git -C "$proj/dev/myrepo" commit -m "feature" >/dev/null 2>&1
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  # origin/HEAD still names main, but the tracking ref is gone and the remote
  # is unreachable: content equivalence cannot be verified. "Cannot tell" must
  # not read as "content upstream" — the hint hands out branch -D verbatim.
  git -C "$proj/.repos/myrepo" update-ref -d refs/remotes/origin/main
  git -C "$proj/.repos/myrepo" remote set-url origin "$REMOTES/definitely-gone.git" >/dev/null 2>&1

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "skipping unmerged branch: ws/dev/main"
  [[ "$output" != *"content already upstream"* ]]
}

@test "prune: --force removes workspace with uncommitted changes" {
  local proj="$SANDBOX/prune-dirty-force"
  local remote="$REMOTES/prune-dirty-force-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  (cd "$proj" && orbit new "dirty force test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  echo "dirty" > "$proj/dev/myrepo/dirty.txt"
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --force"
  [ "$status" -eq 0 ]
  [ ! -d "$proj/dev" ]
  assert_contains "$output" "pruned: dev"
}

# --- Data protection: git repos not from the pool ---

@test "prune: skips workspace holding a git repo that isn't from the pool" {
  local proj="$SANDBOX/prune-foreign"
  clone_project "$proj"
  (cd "$proj" && orbit new "foreign test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  # the incident shape: an agent git-clones a helper repo straight into the
  # workspace. Its objects live in its own .git, so rm -rf would take history
  # that exists nowhere else — the pool-backed worktree guards never see it.
  git init -q "$proj/dev/helper"
  (cd "$proj/dev/helper" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "unpushed work")
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  # session running prune must not be parked inside a workspace
  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "skipping dev: git repos not from the pool: helper"
  assert_dir_exists "$proj/dev/helper/.git"
}

@test "prune: --dry-run reports a non-pool git repo as would skip" {
  local proj="$SANDBOX/prune-foreign-dry"
  clone_project "$proj"
  (cd "$proj" && orbit new "foreign dry" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  git init -q "$proj/dev/helper"
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run"
  [ "$status" -eq 0 ]
  assert_contains "$output" "would skip: dev (git repos not from the pool: helper)"
  assert_dir_exists "$proj/dev"
}

@test "prune: --force removes workspace holding a non-pool git repo" {
  local proj="$SANDBOX/prune-foreign-force"
  clone_project "$proj"
  (cd "$proj" && orbit new "foreign force" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  git init -q "$proj/dev/helper"
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --force"
  [ "$status" -eq 0 ]
  [ ! -d "$proj/dev" ]
  assert_contains "$output" "pruned: dev"
}

@test "prune: a .git directory under a pool repo's name is foreign, not a worktree" {
  local proj="$SANDBOX/prune-name-collision"
  clone_project "$proj"
  (cd "$proj" && orbit new "collision test" --name dev >/dev/null 2>&1)
  # An independent clone that happens to carry the pool repo's name: it has a
  # .git *directory* (a pool worktree has a .git file), so its history lives
  # here and nowhere else — the name match must not disguise it as pool-backed.
  git init -q "$proj/dev/myrepo"
  (cd "$proj/dev/myrepo" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "unpushed work")
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "skipping dev: git repos not from the pool: myrepo"
  assert_dir_exists "$proj/dev/myrepo/.git"
}

# --- Knowledge protection: unmerged jots ---

@test "prune: skips workspace with jots that were never merged into memo" {
  local proj="$SANDBOX/prune-jots"
  clone_project "$proj"
  (cd "$proj" && orbit new "jot test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  (cd "$proj/dev" && orbit jot myrepo "only place that signs release artifacts" >/dev/null 2>&1)
  (cd "$proj/dev" && orbit jot myrepo "real entry is scripts/sign.sh" >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "skipping dev: unmerged jots in: myrepo (2)"
  assert_dir_exists "$proj/dev"
}

@test "prune: --dry-run reports unmerged jots as would skip with counts" {
  local proj="$SANDBOX/prune-jots-dry"
  clone_project "$proj"
  (cd "$proj" && orbit new "jot dry" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  (cd "$proj/dev" && orbit jot myrepo "a discovery" >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run"
  [ "$status" -eq 0 ]
  assert_contains "$output" "would skip: dev (unmerged jots in: myrepo (1))"
  assert_dir_exists "$proj/dev"
}

@test "prune: proceeds after jots are popped" {
  local proj="$SANDBOX/prune-jots-popped"
  clone_project "$proj"
  (cd "$proj" && orbit new "jot popped" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  (cd "$proj/dev" && orbit jot myrepo "a discovery" >/dev/null 2>&1)
  (cd "$proj/dev" && orbit jot myrepo --pop >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune"
  [ "$status" -eq 0 ]
  [ ! -d "$proj/dev" ]
  assert_contains "$output" "pruned: dev"
}

@test "prune: --force removes workspace with unmerged jots" {
  local proj="$SANDBOX/prune-jots-force"
  clone_project "$proj"
  (cd "$proj" && orbit new "jot force" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  (cd "$proj/dev" && orbit jot myrepo "a discovery" >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --force"
  [ "$status" -eq 0 ]
  [ ! -d "$proj/dev" ]
  assert_contains "$output" "pruned: dev"
}

# --- Guard invariants ---

@test "prune: --force does not bypass the cwd guard" {
  local proj="$SANDBOX/prune-force-session"
  clone_project "$proj"
  (cd "$proj" && orbit new "force session" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  # --force releases the DATA guards (dirty / foreign / jots) by design; it must
  # never release the initiation guard — that one protects the session's own footing.
  # Parked-ancestor topology: keep the subshell + trailing exit.
  run bash -c "cd '$proj/dev' && (cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune dev --force); rc=\$?; exit \$rc"
  [ "$status" -ne 0 ]
  assert_contains "$output" "prune should not be initiated from inside workspace dev"
  assert_dir_exists "$proj/dev"
}

@test "prune: --force does not bypass the root-level guard" {
  local proj="$SANDBOX/prune-force-root"
  clone_project "$proj"
  (cd "$proj" && orbit new "force root" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  # Parked-ancestor topology: keep the trailing exit (see above).
  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --force; rc=\$?; exit \$rc"
  [ "$status" -ne 0 ]
  assert_contains "$output" "prune should not be initiated from inside workspace dev"
  assert_dir_exists "$proj/dev"
}

@test "prune: root-level guard fires through a symlinked path" {
  local proj="$SANDBOX/prune-symlink"
  clone_project "$proj"
  (cd "$proj" && orbit new "symlink test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)
  # A cwd reached through a symlink has a logical path that shares no prefix
  # with the root — a logical comparison would let prune run inside the workspace.
  ln -s "$proj/dev" "$SANDBOX/dev-link"

  # Parked-ancestor topology: keep the trailing exit (see above). The guard's
  # physical normalization must see through the symlink either way.
  run bash -c "cd -L '$SANDBOX/dev-link' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune; rc=\$?; exit \$rc"
  [ "$status" -ne 0 ]
  assert_contains "$output" "prune should not be initiated from inside workspace dev"
  assert_dir_exists "$proj/dev"
}

@test "prune: reclaims a done workspace that never had a repo added" {
  local proj="$SANDBOX/prune-empty-ws"
  clone_project "$proj"
  (cd "$proj" && orbit new "empty workspace" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  # The data guards enumerate arrays that are empty here; under bash 3.2 a naked
  # "${arr[@]}" expansion on an empty array aborts the whole run via set -u.
  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune"
  [ "$status" -eq 0 ]
  assert_contains "$output" "pruned: dev"
  [ ! -d "$proj/dev" ]
}

@test "prune --dry-run: handles a done workspace with no repos" {
  local proj="$SANDBOX/prune-empty-ws-dry"
  clone_project "$proj"
  (cd "$proj" && orbit new "empty dry" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run"
  [ "$status" -eq 0 ]
  assert_contains "$output" "would prune: dev"
  assert_dir_exists "$proj/dev"
}

@test "prune: reports every skip reason at once, not one per run" {
  local proj="$SANDBOX/prune-all-reasons"
  clone_project "$proj"
  (cd "$proj" && orbit new "all reasons" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  echo "dirty" > "$proj/dev/myrepo/wip.txt"
  git init -q "$proj/dev/helper"
  (cd "$proj/dev" && orbit jot myrepo "a discovery" >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  # --force releases all three data guards as one decision, so the operator has
  # to see the whole set at once instead of discovering them one run at a time.
  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run"
  [ "$status" -eq 0 ]
  assert_contains "$output" "uncommitted changes in: myrepo"
  assert_contains "$output" "git repos not from the pool: helper"
  assert_contains "$output" "unmerged jots in: myrepo (1)"
}

@test "prune: names branches left outside branch.prefix instead of leaking them" {
  local proj="$SANDBOX/prune-left-behind"
  clone_project "$proj"
  (cd "$proj" && orbit new "left behind" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  # A branch created while branch.prefix held another value: losing the config
  # (it is cache) reverts the prefix and would orphan this branch silently.
  git -C "$proj/.repos/myrepo" branch "team/dev/feature" >/dev/null 2>&1
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "left branch outside branch.prefix: team/dev/feature"

  run git -C "$proj/.repos/myrepo" for-each-ref --format='%(refname:short)' refs/heads/team/
  assert_contains "$output" "team/dev/feature"
}

# --- Residue: ghost workspaces & untraceable branches ---

@test "prune: ghost residue — unmerged scoped branch of a reclaimed workspace is named and kept" {
  local proj="$SANDBOX/prune-ghost"
  local remote="$REMOTES/prune-ghost-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "ghost test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  git -C "$proj/dev/myrepo" checkout -b ws/dev/feat >/dev/null 2>&1
  echo "wip" > "$proj/dev/myrepo/wip.txt"
  git -C "$proj/dev/myrepo" add wip.txt
  git -C "$proj/dev/myrepo" commit -m "wip" >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout ws/dev/main >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  # first prune: dir removed; ws/dev/main merged-deleted; feat kept + closing hint
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  [ ! -d "$proj/dev" ]
  assert_contains "$output" "skipping unmerged branch: ws/dev/feat"
  assert_contains "$output" "orbit prune dev --force"

  # second prune: dev is a ghost — residue group, feat named and kept
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "residue: dev (reclaimed workspace)"
  assert_contains "$output" "skipping unmerged branch: ws/dev/feat"
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/feat
  [ "$status" -eq 0 ]
}

@test "prune: targeted ghost prune --force deletes the residue branches" {
  local proj="$SANDBOX/prune-ghost-force"
  local remote="$REMOTES/prune-ghost-force-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "ghost force" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  git -C "$proj/dev/myrepo" checkout -b ws/dev/feat >/dev/null 2>&1
  echo "wip" > "$proj/dev/myrepo/wip.txt"
  git -C "$proj/dev/myrepo" add wip.txt
  git -C "$proj/dev/myrepo" commit -m "wip" >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout ws/dev/main >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune >/dev/null 2>&1"
  [ "$status" -eq 0 ]

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune dev --force 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "deleted branch (force): ws/dev/feat"
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/feat
  [ "$status" -ne 0 ]
}

@test "prune: reports untraceable raw branches with status and delete command" {
  local proj="$SANDBOX/prune-raw-residue"
  local remote="$REMOTES/prune-raw-residue-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "raw residue" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  # untraceable: raw name, no remote copy, not checked out
  git -C "$proj/dev/myrepo" checkout -b raw-orphan >/dev/null 2>&1
  echo "x" > "$proj/dev/myrepo/x.txt"
  git -C "$proj/dev/myrepo" add x.txt
  git -C "$proj/dev/myrepo" commit -m "x" >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout ws/dev/main >/dev/null 2>&1

  # excluded: has a remote copy
  git -C "$proj/.repos/myrepo" branch raw-pushed origin/main >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" update-ref refs/remotes/origin/raw-pushed origin/main

  # excluded: upstream under a DIFFERENT name (release-style tracked branch)
  git -C "$proj/.repos/myrepo" branch release-1.2 origin/main >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" update-ref refs/remotes/origin/release-x origin/main
  git -C "$proj/.repos/myrepo" config branch.release-1.2.remote origin
  git -C "$proj/.repos/myrepo" config branch.release-1.2.merge refs/heads/release-x

  # excluded: checked out in a live workspace's worktree
  cd "$proj" && orbit new "active" --name live >/dev/null 2>&1
  cd "$proj/live" && orbit add myrepo >/dev/null 2>&1
  git -C "$proj/live/myrepo" checkout -b raw-active >/dev/null 2>&1

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "untraceable branches (raw, no remote, no workspace)"
  assert_contains "$output" "myrepo: raw-orphan (unmerged)"
  assert_contains "$output" 'git -C ".repos/myrepo" branch -D raw-orphan'
  [[ "$output" != *"raw-pushed"* ]]
  [[ "$output" != *"raw-active"* ]]
  [[ "$output" != *"release-1.2"* ]]
}

@test "prune: report does not leak git's native branch-deletion output" {
  local proj="$SANDBOX/prune-no-native-leak"
  clone_project "$proj"
  cd "$proj" && orbit new "no leak" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "deleted branch (merged): ws/dev/main"
  [[ "$output" != *"Deleted branch"* ]]
}

@test "prune --dry-run: ghost residue reported with would-forms, nothing deleted" {
  local proj="$SANDBOX/prune-ghost-dry"
  local remote="$REMOTES/prune-ghost-dry-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "ghost dry" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  git -C "$proj/dev/myrepo" checkout -b ws/dev/feat >/dev/null 2>&1
  echo "wip" > "$proj/dev/myrepo/wip.txt"
  git -C "$proj/dev/myrepo" add wip.txt
  git -C "$proj/dev/myrepo" commit -m "wip" >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout ws/dev/main >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune >/dev/null 2>&1"
  [ "$status" -eq 0 ]

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run"
  [ "$status" -eq 0 ]
  assert_contains "$output" "residue: dev (reclaimed workspace)"
  assert_contains "$output" "would skip unmerged branch: ws/dev/feat"
  assert_contains "$output" "would keep 1 branch"
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/feat
  [ "$status" -eq 0 ]
}

@test "prune: single-segment prefixed branch is raw residue, not a ghost that aborts the run" {
  local proj="$SANDBOX/prune-single-segment"
  local remote="$REMOTES/prune-single-segment-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  # hand-made branch under the prefix but without the <prefix>/<ws>/<name>
  # shape; --no-track keeps it untraceable (no configured upstream)
  git -C "$proj/.repos/myrepo" branch --no-track ws/lonely origin/main >/dev/null 2>&1

  # the run must complete (exit 0) and file the branch under raw residue
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "untraceable branches (raw, no remote, no workspace)"
  assert_contains "$output" "myrepo: ws/lonely (merged)"
  # raw arm of the three-condition: residue present ⇒ NOT "nothing to prune"
  [[ "$output" != *"nothing to prune"* ]]
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/lonely
  [ "$status" -eq 0 ]

  # no workspace named lonely exists — targeting it is a plain not-found
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune lonely 2>&1"
  [ "$status" -ne 0 ]
  assert_contains "$output" "workspace not found or not marked done: lonely"
}

@test "prune: raw residue disposal commands are shell-quoted" {
  local proj="$SANDBOX/prune-quoted-cmds"
  local remote="$REMOTES/prune-quoted-cmds-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "quoted" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  # git allows shell metacharacters in ref names; an agent copy-pasting the
  # disposal command must not execute them
  git -C "$proj/dev/myrepo" checkout -b 'evil;name' >/dev/null 2>&1
  echo "x" > "$proj/dev/myrepo/x.txt"
  git -C "$proj/dev/myrepo" add x.txt
  git -C "$proj/dev/myrepo" commit -m "x" >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout ws/dev/main >/dev/null 2>&1

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" 'git -C ".repos/myrepo" branch -D evil\;name'
  [[ "$output" != *'branch -D evil;name'* ]]
}

@test "prune: raw current-branch skip does NOT feed the closing block (scoped only)" {
  local proj="$SANDBOX/prune-raw-skip"
  local remote="$REMOTES/prune-raw-skip-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "raw skip" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  git -C "$proj/dev/myrepo" checkout -b wip-raw >/dev/null 2>&1
  echo "wip" > "$proj/dev/myrepo/wip.txt"
  git -C "$proj/dev/myrepo" add wip.txt
  git -C "$proj/dev/myrepo" commit -m "wip" >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "skipping unmerged branch: wip-raw"
  assert_contains "$output" "untraceable branches (raw, no remote, no workspace)"
  assert_contains "$output" "myrepo: wip-raw"
  # a raw skip must not produce a scoped force suggestion — the suggested
  # command would error out (no ghost residue exists for a raw branch)
  [[ "$output" != *"branch kept"* ]]
  [[ "$output" != *"orbit prune dev --force"* ]]
  [[ "$output" != *"nothing to prune"* ]]
}

@test "prune: closing block streams to stderr in a real run, stdout in dry-run" {
  local proj="$SANDBOX/prune-streams"
  local remote="$REMOTES/prune-streams-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "streams" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  git -C "$proj/dev/myrepo" checkout -b ws/dev/feat >/dev/null 2>&1
  echo "wip" > "$proj/dev/myrepo/wip.txt"
  git -C "$proj/dev/myrepo" add wip.txt
  git -C "$proj/dev/myrepo" commit -m "wip" >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout ws/dev/main >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune >/dev/null 2>&1"
  [ "$status" -eq 0 ]

  # real run: report on stdout, diagnostics (skip + closing block) on stderr
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune >'$SANDBOX/o.txt' 2>'$SANDBOX/e.txt'"
  [ "$status" -eq 0 ]
  run cat "$SANDBOX/o.txt"
  assert_contains "$output" "residue: dev (reclaimed workspace)"
  [[ "$output" != *"branch kept"* ]]
  run cat "$SANDBOX/e.txt"
  assert_contains "$output" "skipping unmerged branch: ws/dev/feat"
  assert_contains "$output" "branch kept"
  assert_contains "$output" "orbit prune dev --force"

  # dry-run: everything is report → stdout
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run >'$SANDBOX/o2.txt' 2>'$SANDBOX/e2.txt'"
  [ "$status" -eq 0 ]
  run cat "$SANDBOX/o2.txt"
  assert_contains "$output" "would keep 1 branch"
  run cat "$SANDBOX/e2.txt"
  [[ "$output" != *"would keep"* ]]
}

@test "prune: targeted ghost prune without --force processes residue, keeps unmerged" {
  local proj="$SANDBOX/prune-ghost-targeted"
  local remote="$REMOTES/prune-ghost-targeted-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "targeted" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  git -C "$proj/dev/myrepo" checkout -b ws/dev/feat >/dev/null 2>&1
  echo "wip" > "$proj/dev/myrepo/wip.txt"
  git -C "$proj/dev/myrepo" add wip.txt
  git -C "$proj/dev/myrepo" commit -m "wip" >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout ws/dev/main >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune >/dev/null 2>&1"
  [ "$status" -eq 0 ]

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune dev 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "residue: dev (reclaimed workspace)"
  assert_contains "$output" "skipping unmerged branch: ws/dev/feat"
  [[ "$output" != *"not found"* ]]
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/feat
  [ "$status" -eq 0 ]
}

@test "prune: raw residue report streams to stderr in a real run, stdout in dry-run" {
  local proj="$SANDBOX/prune-raw-streams"
  local remote="$REMOTES/prune-raw-streams-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "raw streams" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  git -C "$proj/dev/myrepo" checkout -b raw-orphan >/dev/null 2>&1
  echo "x" > "$proj/dev/myrepo/x.txt"
  git -C "$proj/dev/myrepo" add x.txt
  git -C "$proj/dev/myrepo" commit -m "x" >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout ws/dev/main >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  # real run: raw report is a diagnostic → stderr
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune >'$SANDBOX/o.txt' 2>'$SANDBOX/e.txt'"
  [ "$status" -eq 0 ]
  run cat "$SANDBOX/e.txt"
  assert_contains "$output" "untraceable branches (raw, no remote, no workspace)"
  run cat "$SANDBOX/o.txt"
  [[ "$output" != *"untraceable branches"* ]]

  # dry-run: everything is report → stdout
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run >'$SANDBOX/o2.txt' 2>'$SANDBOX/e2.txt'"
  [ "$status" -eq 0 ]
  run cat "$SANDBOX/o2.txt"
  assert_contains "$output" "untraceable branches (raw, no remote, no workspace)"
  run cat "$SANDBOX/e2.txt"
  [[ "$output" != *"untraceable branches"* ]]
}
