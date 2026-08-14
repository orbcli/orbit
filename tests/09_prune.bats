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
  assert_contains "$output" "dev exists but is not marked done"
}

@test "prune: targeted refusal — missing or unreadable workspace metadata" {
  local proj="$SANDBOX/prune-nometa"
  clone_project "$proj"
  cd "$proj" && orbit new "active ws" --name dev >/dev/null 2>&1
  rm "$proj/dev/.orbit"

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune dev"
  [ "$status" -ne 0 ]
  assert_contains "$output" "dev exists but workspace metadata is missing or unreadable"
  # a lost cache never becomes a deletion: the directory is untouched
  [ -d "$proj/dev" ]
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

@test "prune: unmerged branch blocks the whole workspace — all-or-nothing" {
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
  # a validation refusal is expected operation: exit 0, zero mutation
  [ "$status" -eq 0 ]
  assert_contains "$output" "keeping unmerged branch: ws/dev/main"
  assert_contains "$output" "workspaces kept: dev"
  refute_contains "$output" "skipping unmerged branch"
  # zero mutation: directory, worktree registration and branch all intact
  [ -d "$proj/dev/myrepo" ]
  git -C "$proj/.repos/myrepo" worktree list | grep -q "dev/myrepo"
  git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/main >/dev/null
  # no report header for a workspace that was never touched
  refute_contains "$output" "pruned: dev"
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
  assert_contains "$output" "no such workspace: nonexist"
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

# --- Readable report format ---

@test "prune: --dry-run report is header-first, repo-grouped, single-stream" {
  local proj="$SANDBOX/prune-dryfmt"
  local remote="$REMOTES/prune-dryfmt-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "dryfmt test" --name dev >/dev/null 2>&1
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

  # stderr discarded: a dry-run report must be complete on stdout alone
  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run 2>/dev/null"
  [ "$status" -eq 0 ]
  assert_dir_exists "$proj/dev"
  assert_contains "$output" "would prune: dev (1 worktree)"
  assert_contains "$output" "  myrepo:"
  assert_contains "$output" "    would delete branch (merged): ws/dev/main"
  assert_contains "$output" "would remove workspace directory (via .prune-trash)"
  # branch config cleanup is coupled to deletion and never printed
  refute_contains "$output" "would remove branch config"
  # header precedes all detail lines
  local header_line detail_line
  header_line=$(printf '%s\n' "$output" | grep -n "would prune: dev" | head -1 | cut -d: -f1)
  detail_line=$(printf '%s\n' "$output" | grep -n "would delete branch" | head -1 | cut -d: -f1)
  [ "$header_line" -lt "$detail_line" ]
}

@test "prune --dry-run: a blocked workspace reports the blockers, no plan" {
  local proj="$SANDBOX/prune-dryblocked"
  local remote="$REMOTES/prune-dryblocked-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "dryblocked test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  echo "unmerged" > "$proj/dev/myrepo/unmerged.txt"
  git -C "$proj/dev/myrepo" add unmerged.txt
  git -C "$proj/dev/myrepo" commit -m "unmerged work" >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run 2>/dev/null"
  [ "$status" -eq 0 ]
  assert_dir_exists "$proj/dev"
  # the would-prune plan never prints for a workspace that would be refused
  refute_contains "$output" "would prune: dev"
  assert_contains "$output" "keeping unmerged branch: ws/dev/main"
  assert_contains "$output" "would keep workspaces: dev"
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
  assert_contains "$output" "pruned: dev (1 worktree removed, 1 branch deleted)"
  # steady state: the trash is transient — created lazily, self-cleaned
  [ ! -e "$proj/.prune-trash" ]
}

# --- Remote-deleted branches & fetch-config maintenance ---

@test "prune: cleans the tracking ref of a remote-deleted tracked branch, zero fatal leak" {
  local proj="$SANDBOX/prune-gone"
  local remote="$REMOTES/prune-gone-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "gone test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev/myrepo" && orbit switch -c feat-gone >/dev/null 2>&1
  echo g > g.txt && git add g.txt && git commit -m "g" >/dev/null 2>&1
  git push >/dev/null 2>&1
  git rev-parse --verify --quiet origin/feat-gone >/dev/null

  # the remote deletes the branch (PR merged + auto-deleted)
  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_pg_XXXXXX")
  git clone "$remote" "$tmp" >/dev/null 2>&1
  git -C "$tmp" push origin --delete feat-gone >/dev/null 2>&1
  rm -rf "$tmp"

  # session running prune must not be parked inside a workspace
  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  # the fatal this model exists to kill never leaks out of the touchpoint
  refute_contains "$output" "couldn't find remote ref"
  # the tracked-but-gone ref is converged natively (conditional remote prune)
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/remotes/origin/feat-gone
  [ "$status" -ne 0 ]
  # the workspace and its local branch are untouched
  assert_dir_exists "$proj/dev"
  git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/feat-gone >/dev/null
  # config untouched: exactly the wildcard
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/*:refs/remotes/origin/*" ]
}

@test "prune --dry-run: previews fetch-config convergence without touching it" {
  local proj="$SANDBOX/prune-converge-dry"
  local remote="$REMOTES/prune-converge-dry-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  # legacy shape: exact default entry plus a stale one, no prune key
  git -C "$proj/.repos/myrepo" config --replace-all remote.origin.fetch \
    "+refs/heads/main:refs/remotes/origin/main"
  git -C "$proj/.repos/myrepo" config --add remote.origin.fetch \
    "+refs/heads/gone:refs/remotes/origin/gone"
  git -C "$proj/.repos/myrepo" config --unset-all fetch.prune 2>/dev/null || true
  git -C "$proj/.repos/myrepo" config push.default simple

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "pool maintenance:"
  assert_contains "$output" 'would converge fetch config: git remote set-branches origin "*"'
  assert_contains "$output" 'would converge fetch config: git config fetch.prune true'
  assert_contains "$output" 'would converge push routing: git config push.default upstream'

  # preview only: config and refs untouched
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  assert_contains "$output" "refs/heads/gone"
  [ "$(git -C "$proj/.repos/myrepo" config --get push.default)" = "simple" ]
}

@test "prune: converges a legacy pre-registration config; local branches untouched" {
  local proj="$SANDBOX/prune-legacy-converge"
  local remote="$REMOTES/prune-legacy-converge-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  # active workspace with a scoped branch that was never pushed
  cd "$proj" && orbit new "live work" --name live >/dev/null 2>&1
  cd "$proj/live" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/live/myrepo" && orbit switch -c feat-live >/dev/null 2>&1

  # Legacy residue (older orbit pre-registered exact refspecs at switch -c):
  # the entry points at a branch the remote never had — every bare fetch
  # fails while it exists.
  git -C "$proj/.repos/myrepo" config --replace-all remote.origin.fetch \
    "+refs/heads/main:refs/remotes/origin/main"
  git -C "$proj/.repos/myrepo" config --add remote.origin.fetch \
    "+refs/heads/feat-live:refs/remotes/origin/feat-live"
  run git -C "$proj/.repos/myrepo" fetch origin
  [ "$status" -ne 0 ]

  # session running prune must not be parked inside a workspace
  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_dir_exists "$proj/live"
  assert_contains "$output" 'orbit: myrepo: fetch config converged: git remote set-branches origin "*" (stop converging and re-apply yours: orbit config git.fetchAllBranches once)'

  # the local branch itself is untouched; the config is exactly the wildcard
  git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/live/feat-live >/dev/null
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/*:refs/remotes/origin/*" ]
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
  refute_contains "$output" "&&"
  refute_contains "$output" "cd $proj"
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

@test "prune: squash-merged branch is a layer-3 delete verdict (content upstream)" {
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
  # tree-level proof is a delete verdict, not a keep hint
  assert_contains "$output" "deleted branch (content upstream): ws/dev/main"
  refute_contains "$output" "keeping unmerged branch"
  git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/main >/dev/null \
    && { echo "branch still exists"; return 1; }
  return 0
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
  assert_contains "$output" "keeping unmerged branch: ws/dev/main"
  refute_contains "$output" "content reads as already upstream"
  refute_contains "$output" "review:"
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

  # residue is produced EXTERNALLY (a manual rm -rf) — prune itself never
  # produces it: all-or-nothing keeps the whole workspace on any blocker
  rm -rf "$proj/dev"

  # ghost group: merged main deleted, unmerged feat kept — deleted and kept
  # lines adjacent in the same stdout report block
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "pruning: dev (residue)"
  assert_contains "$output" "deleted branch (merged): ws/dev/main"
  assert_contains "$output" 'kept branch (unmerged): ws/dev/feat — review: git -C ".repos/myrepo" log origin/main..ws/dev/feat'
  assert_contains "$output" "pruned: dev (residue) (1 branch deleted, 1 kept)"
  assert_contains "$output" "orbit prune dev --force"
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/feat
  [ "$status" -eq 0 ]
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/main
  [ "$status" -ne 0 ]
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
  # manufacture the ghost externally
  rm -rf "$proj/dev"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune dev --force 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "pruning: dev (residue)"
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

  # excluded: has a remote copy. Real remote branches now — a faked local
  # ref would be converged by the touchpoint's conditional prune, not
  # misread as traceable.
  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_prr_XXXXXX")
  git clone "$remote" "$tmp" >/dev/null 2>&1
  (
    cd "$tmp"
    git checkout -q -b raw-pushed && git push -q origin raw-pushed
    git checkout -q -b release-x && git push -q origin release-x
  )
  rm -rf "$tmp"
  git -C "$proj/.repos/myrepo" branch raw-pushed origin/main >/dev/null 2>&1
  # materialize the way a user's lightweight fetch would (bare-name fetch
  # under the wildcard map)
  git -C "$proj/.repos/myrepo" fetch origin raw-pushed >/dev/null 2>&1

  # excluded: upstream under a DIFFERENT name (release-style tracked branch)
  git -C "$proj/.repos/myrepo" branch release-1.2 origin/main >/dev/null 2>&1
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
  assert_contains "$output" "  myrepo:"
  assert_contains "$output" "    raw-orphan (unmerged)"
  assert_contains "$output" 'git -C ".repos/myrepo" branch -D raw-orphan'
  refute_contains "$output" "raw-pushed"
  refute_contains "$output" "raw-active"
  refute_contains "$output" "release-1.2"
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
  refute_contains "$output" "Deleted branch"
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
  # residue is produced externally; --dry-run then previews the ghost group
  rm -rf "$proj/dev"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run"
  [ "$status" -eq 0 ]
  assert_contains "$output" "would prune: dev (residue)"
  assert_contains "$output" "would keep unmerged branch: ws/dev/feat"
  assert_contains "$output" "would keep workspaces: dev"
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
  assert_contains "$output" "    ws/lonely (merged)"
  # raw arm of the three-condition: residue present ⇒ NOT "nothing to prune"
  refute_contains "$output" "nothing to prune"
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/lonely
  [ "$status" -eq 0 ]

  # no workspace named lonely exists — targeting it is a plain not-found
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune lonely 2>&1"
  [ "$status" -ne 0 ]
  assert_contains "$output" "no such workspace: lonely"
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
  refute_contains "$output" 'branch -D evil;name'
}

@test "prune: raw current branch never enters the branch pipeline — raw report only" {
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
  # the scoped branch is merged and deleted; the dir is reclaimed
  assert_contains "$output" "pruned: dev (1 worktree removed, 1 branch deleted)"
  [ ! -d "$proj/dev" ]
  # the raw branch is reported as untraceable residue — never a scoped
  # verdict, never a force suggestion (the suggested command would error out:
  # no ghost residue exists for a raw branch)
  assert_contains "$output" "untraceable branches (raw, no remote, no workspace)"
  assert_contains "$output" "    wip-raw"
  refute_contains "$output" "workspaces kept"
  refute_contains "$output" "orbit prune dev --force"
  refute_contains "$output" "nothing to prune"
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
  # manufacture the ghost externally
  rm -rf "$proj/dev"

  # real run: the ghost group is a reconciliation report — header, deletion
  # AND kept lines on stdout; the keeping diagnostic + closing block on stderr
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune >'$SANDBOX/o.txt' 2>'$SANDBOX/e.txt'"
  [ "$status" -eq 0 ]
  run cat "$SANDBOX/o.txt"
  assert_contains "$output" "pruning: dev (residue)"
  assert_contains "$output" "  myrepo:"
  assert_contains "$output" "deleted branch (merged): ws/dev/main"
  assert_contains "$output" "kept branch (unmerged): ws/dev/feat"
  refute_contains "$output" "workspaces kept"
  run cat "$SANDBOX/e.txt"
  # the ghost's kept branch is report content only — no stderr duplicate
  refute_contains "$output" "keeping unmerged branch"
  assert_contains "$output" "workspaces kept: dev"
  assert_contains "$output" "orbit prune dev --force"

  # dry-run: everything is report → stdout
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run >'$SANDBOX/o2.txt' 2>'$SANDBOX/e2.txt'"
  [ "$status" -eq 0 ]
  run cat "$SANDBOX/o2.txt"
  assert_contains "$output" "would keep workspaces: dev"
  run cat "$SANDBOX/e2.txt"
  refute_contains "$output" "would keep"
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
  # manufacture the ghost externally
  rm -rf "$proj/dev"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune dev 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "pruning: dev (residue)"
  assert_contains "$output" "deleted branch (merged): ws/dev/main"
  assert_contains "$output" "kept branch (unmerged): ws/dev/feat"
  refute_contains "$output" "no such workspace"
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
  refute_contains "$output" "untraceable branches"

  # dry-run: everything is report → stdout
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run >'$SANDBOX/o2.txt' 2>'$SANDBOX/e2.txt'"
  [ "$status" -eq 0 ]
  run cat "$SANDBOX/o2.txt"
  assert_contains "$output" "untraceable branches (raw, no remote, no workspace)"
  run cat "$SANDBOX/e2.txt"
  refute_contains "$output" "untraceable branches"
}

@test "prune: closing block — single caveat, scoped suggestions before raw commands" {
  local proj="$SANDBOX/prune-closing-order"
  local remote="$REMOTES/prune-closing-order-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "order" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  git -C "$proj/dev/myrepo" checkout -b ws/dev/feat >/dev/null 2>&1
  echo "wip" > "$proj/dev/myrepo/wip.txt"
  git -C "$proj/dev/myrepo" add wip.txt
  git -C "$proj/dev/myrepo" commit -m "wip" >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout ws/dev/main >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout -b raw-orphan >/dev/null 2>&1
  echo "x" > "$proj/dev/myrepo/x.txt"
  git -C "$proj/dev/myrepo" add x.txt
  git -C "$proj/dev/myrepo" commit -m "x" >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout ws/dev/main >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  # caveat exactly once
  [ "$(printf '%s\n' "$output" | grep -c "after confirming the content is no longer needed")" -eq 1 ]
  # scoped suggestion precedes the raw command
  local scoped_line raw_line
  scoped_line=$(printf '%s\n' "$output" | grep -n "orbit prune dev --force" | head -1 | cut -d: -f1)
  raw_line=$(printf '%s\n' "$output" | grep -n "branch -D raw-orphan" | head -1 | cut -d: -f1)
  [ -n "$scoped_line" ] && [ -n "$raw_line" ] && [ "$scoped_line" -lt "$raw_line" ]
}

@test "prune: empty workspace header shows (no worktrees)" {
  local proj="$SANDBOX/prune-no-worktrees"
  clone_project "$proj"
  (cd "$proj" && orbit new "empty" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "would prune: dev (0 worktrees)"
  assert_contains "$output" "  (no worktrees)"
}

@test "prune: a slash-bearing target is not a workspace — live branches untouched" {
  local proj="$SANDBOX/prune-slash-target"
  local remote="$REMOTES/prune-slash-target-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "alive" --name alive >/dev/null 2>&1
  cd "$proj/alive" && orbit add myrepo >/dev/null 2>&1
  git -C "$proj/alive/myrepo" checkout -b ws/alive/feat/x >/dev/null 2>&1
  echo "wip" > "$proj/alive/myrepo/wip.txt"
  git -C "$proj/alive/myrepo" add wip.txt
  git -C "$proj/alive/myrepo" commit -m "wip" >/dev/null 2>&1
  git -C "$proj/alive/myrepo" checkout ws/alive/main >/dev/null 2>&1
  cd "$SANDBOX"

  # targeted ghost lookup must not pattern into a LIVE workspace's branches
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune alive/feat --force 2>&1"
  [ "$status" -ne 0 ]
  assert_contains "$output" "no such workspace: alive/feat"
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/alive/feat/x
  [ "$status" -eq 0 ]
}

@test "prune: unregistered worktree warns and leaves it to directory removal" {
  local proj="$SANDBOX/prune-unregistered"
  clone_project "$proj"
  cd "$proj" && orbit new "unreg" --name dev >/dev/null 2>&1
  mkdir -p "$proj/dev/myrepo"
  printf 'gitdir: /nonexistent\n' > "$proj/dev/myrepo/.git"
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)
  cd "$SANDBOX"

  # --force releases the data guards (the fake .git reads as unverifiable)
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune dev --force 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "orbit: myrepo: worktree not registered to the pool repo; left to directory removal"
  [ ! -d "$proj/dev" ]
}

@test "prune: raw residue with undeterminable default branch shows (unknown), no review" {
  local proj="$SANDBOX/prune-raw-unknown"
  clone_project "$proj"
  cd "$proj" && orbit new "unknown" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  git -C "$proj/dev/myrepo" checkout -b raw-orphan >/dev/null 2>&1
  echo "x" > "$proj/dev/myrepo/x.txt"
  git -C "$proj/dev/myrepo" add x.txt
  git -C "$proj/dev/myrepo" commit -m "x" >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout ws/dev/main >/dev/null 2>&1
  # no remote at all → default branch undeterminable
  git -C "$proj/.repos/myrepo" remote remove origin
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "    raw-orphan (unknown)"
  refute_contains "$output" "raw-orphan (unknown) — review"
}

@test "prune: branch checked out in another workspace is NOT deleted — failure surfaces, no false 'deleted'" {
  local proj="$SANDBOX/prune-checked-out-elsewhere"
  local remote="$REMOTES/prune-checked-out-elsewhere-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "done task" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout -b ws/dev/feat >/dev/null 2>&1
  echo "work" > "$proj/dev/myrepo/work.txt"
  git -C "$proj/dev/myrepo" add work.txt
  git -C "$proj/dev/myrepo" commit -m "work" >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout ws/dev/main >/dev/null 2>&1
  git -C "$proj/dev/myrepo" merge ws/dev/feat >/dev/null 2>&1
  git -C "$proj/dev/myrepo" push origin ws/dev/main:main >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" fetch origin >/dev/null 2>&1

  # the branch is checked out in ANOTHER live workspace's worktree
  cd "$proj" && orbit new "active" --name live >/dev/null 2>&1
  cd "$proj/live" && orbit add myrepo >/dev/null 2>&1
  git -C "$proj/live/myrepo" checkout ws/dev/feat >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  # a branch-deletion refusal is an execution failure: exit non-zero, the
  # whole workspace kept (no rename), git's own first line on stderr
  [ "$status" -ne 0 ]
  refute_contains "$output" "deleted branch (merged): ws/dev/feat"
  refute_contains "$output" "pruned: dev"
  assert_contains "$output" "cannot delete branch"
  assert_dir_exists "$proj/dev"
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/feat
  [ "$status" -eq 0 ]
}

@test "prune: stale worktree registration is cleaned, ghost branch deletes fine" {
  local proj="$SANDBOX/prune-stale-registration"
  local remote="$REMOTES/prune-stale-registration-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "stale" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  # branch that is merged upstream (fast-forward main into it and push)
  git -C "$proj/dev/myrepo" checkout -b ws/dev/feat >/dev/null 2>&1
  echo "w" > "$proj/dev/myrepo/w.txt"
  git -C "$proj/dev/myrepo" add w.txt
  git -C "$proj/dev/myrepo" commit -m "w" >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout ws/dev/main >/dev/null 2>&1
  git -C "$proj/dev/myrepo" merge ws/dev/feat >/dev/null 2>&1
  git -C "$proj/dev/myrepo" push origin ws/dev/main:main >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" fetch origin >/dev/null 2>&1

  # simulate manual deletion: dir removed, worktree registration left stale
  (cd "$proj/dev" && orbit done >/dev/null 2>&1)
  cd "$SANDBOX"
  rm -rf "$proj/dev"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "deleted branch (merged): ws/dev/feat"
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/feat
  [ "$status" -ne 0 ]
}

@test "prune: worktree removal failure keeps the workspace (no rm -rf while git tracks it)" {
  local proj="$SANDBOX/prune-removal-fails"
  local remote="$REMOTES/prune-removal-fails-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "locked" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" worktree lock "$proj/dev/myrepo"
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  # a worktree-removal failure is a step failure: exit non-zero, ws kept
  [ "$status" -ne 0 ]
  assert_contains "$output" "worktree removal failed"
  assert_dir_exists "$proj/dev"
  assert_dir_exists "$proj/dev/myrepo"
}

# --- Interruption resumability (the invariant: an interrupted non-force run
# is always continuable by a non-force re-run) ---

@test "prune: resume after D1 — worktree gone, branch and directory remain" {
  local proj="$SANDBOX/prune-resume-d1"
  local remote="$REMOTES/prune-resume-d1-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "resume d1" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  # interrupted right after D1: worktree removed, branch + dir still there
  git -C "$proj/.repos/myrepo" worktree remove --force "$proj/dev/myrepo" >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "pruned: dev (0 worktrees removed, 1 branch deleted)"
  # deletion lines carry the recovery handle
  assert_matches "$output" 'deleted\ branch\ \(merged\):\ ws/dev/main\ \(was\ [0-9a-f]+\)'
  [ ! -d "$proj/dev" ]
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/main
  [ "$status" -ne 0 ]
}

@test "prune: resume after D2 — directory remains, branches gone" {
  local proj="$SANDBOX/prune-resume-d2"
  local remote="$REMOTES/prune-resume-d2-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "resume d2" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  # interrupted right after D2: worktree and branch both gone, dir remains
  git -C "$proj/.repos/myrepo" worktree remove --force "$proj/dev/myrepo" >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" branch -D ws/dev/main >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "pruned: dev (0 worktrees removed, 0 branches deleted)"
  [ ! -d "$proj/dev" ]
}

@test "prune: resume after D4a — the opening sweep finishes a trashed workspace" {
  local proj="$SANDBOX/prune-resume-d4"
  clone_project "$proj"
  cd "$proj" && orbit new "resume d4" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  # interrupted right after the rename: the workspace sits in the trash
  mkdir -p "$proj/.prune-trash"
  mv "$proj/dev" "$proj/.prune-trash/dev"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" ".prune-trash: cleared 1 interrupted deletion(s)"
  [ ! -d "$proj/dev" ]
  # steady state = zero trace: the trash is transient, not layout
  [ ! -e "$proj/.prune-trash" ]
  # the sweep's own line reported the work — no "nothing to prune"
  refute_contains "$output" "nothing to prune"
}

@test "prune --dry-run: reports the sweep as a would-line, touches nothing" {
  local proj="$SANDBOX/prune-sweep-dry"
  clone_project "$proj"
  mkdir -p "$proj/.prune-trash/old-ws"
  cd "$SANDBOX"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --dry-run"
  [ "$status" -eq 0 ]
  assert_contains "$output" "would clear 1 interrupted deletion(s)"
  assert_dir_exists "$proj/.prune-trash/old-ws"
}

@test "prune: D1 file-level partial failure reads as dirty — refuse, then --force exits" {
  local proj="$SANDBOX/prune-partial-d1"
  local remote="$REMOTES/prune-partial-d1-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "partial d1" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  # a worktree remove that died half-way leaves a dirty tree — indistinguishable
  # from genuine uncommitted work, so non-force refuses (strategy 1: force exits)
  rm "$proj/dev/myrepo/README.md" 2>/dev/null || rm "$proj/dev/myrepo/"*.md

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "skipping dev: uncommitted changes in: myrepo"
  assert_dir_exists "$proj/dev"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --force 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "--force discards un-persisted work in myrepo"
  assert_contains "$output" "pruned: dev"
  [ ! -d "$proj/dev" ]
}

# --- Pool-driven branch collection ---

@test "prune: worktree dir deleted by hand — branch still collected via pool refs" {
  local proj="$SANDBOX/prune-pool-driven"
  local remote="$REMOTES/prune-pool-driven-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "pool driven" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  # agent rm -rf'd just the worktree: dir + done marker live, registration
  # stale, branch present — same run must collect the branch from pool refs
  rm -rf "$proj/dev/myrepo"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "pruned: dev (0 worktrees removed, 1 branch deleted)"
  [ ! -d "$proj/dev" ]
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/main
  [ "$status" -ne 0 ]
  # the stale registration is gone too (cleaned on the delete path)
  run git -C "$proj/.repos/myrepo" worktree list
  refute_contains "$output" "dev/myrepo"
}

# --- Damaged worktree guard ---

@test "prune: damaged worktree refuses non-force, --force proceeds with notice" {
  local proj="$SANDBOX/prune-damaged"
  local remote="$REMOTES/prune-damaged-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "damaged" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  # gitdir pointer deleted: the pool registration names a path orbit cannot read
  rm "$proj/dev/myrepo/.git"
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "skipping dev: damaged worktree in myrepo (gitdir pointer unusable, pool registration intact)"
  assert_dir_exists "$proj/dev"
  # the registration is deliberately left intact — it is the only evidence
  run git -C "$proj/.repos/myrepo" worktree list
  assert_contains "$output" "dev/myrepo"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --force 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "--force removes myrepo whose state cannot be read"
  assert_contains "$output" "pruned: dev"
  [ ! -d "$proj/dev" ]
  # the registration went with the same run (repair + remove on the force path)
  run git -C "$proj/.repos/myrepo" worktree list
  refute_contains "$output" "dev/myrepo"
}

# --- Layer-1 PR evidence (auto-activated, per-branch) ---

@test "prune: recorded merged PR covering the branch deletes it (PR merged)" {
  local proj="$SANDBOX/prune-pr-merged"
  local remote="$REMOTES/prune-pr-merged-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "https://github.com/acme/myrepo.git" >/dev/null 2>&1
  cd "$proj" && orbit new "pr merged" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  git -C "$proj/dev/myrepo" checkout -b ws/dev/feat >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" config branch.ws/dev/feat.remote origin
  git -C "$proj/.repos/myrepo" config branch.ws/dev/feat.merge refs/heads/feat
  echo "work" > "$proj/dev/myrepo/work.txt"
  git -C "$proj/dev/myrepo" add work.txt
  git -C "$proj/dev/myrepo" commit -m "work" >/dev/null 2>&1
  local tip
  tip=$(git -C "$proj/dev/myrepo" rev-parse HEAD)

  git config --file "$proj/dev/.orbit" --add pr.url "https://github.com/acme/myrepo/pull/7"
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  local bin="$SANDBOX/ghbin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'EOF'
#!/bin/sh
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  printf '{"state":"%s","headRefName":"%s","headRefOid":"%s"}\n' "$STUB_STATE" "$STUB_HEAD" "$STUB_OID"
  exit "${STUB_RC:-0}"
fi
exit 1
EOF
  chmod +x "$bin/gh"

  run bash -c "export PATH='$bin':\$PATH STUB_STATE=MERGED STUB_HEAD=feat STUB_OID='$tip'; cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "deleted branch (PR merged): ws/dev/feat"
  [ ! -d "$proj/dev" ]
}

@test "prune: merged PR does NOT bless post-push local commits (containment)" {
  local proj="$SANDBOX/prune-pr-contain"
  local remote="$REMOTES/prune-pr-contain-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "https://github.com/acme/myrepo.git" >/dev/null 2>&1
  cd "$proj" && orbit new "pr contain" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  git -C "$proj/dev/myrepo" checkout -b ws/dev/feat >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" config branch.ws/dev/feat.remote origin
  git -C "$proj/.repos/myrepo" config branch.ws/dev/feat.merge refs/heads/feat
  echo "v1" > "$proj/dev/myrepo/work.txt"
  git -C "$proj/dev/myrepo" add work.txt
  git -C "$proj/dev/myrepo" commit -m "v1" >/dev/null 2>&1
  local pushed_tip
  pushed_tip=$(git -C "$proj/dev/myrepo" rev-parse HEAD)
  # unpushed local commit on top of the PR head
  echo "v2" >> "$proj/dev/myrepo/work.txt"
  git -C "$proj/dev/myrepo" commit -qam "v2" >/dev/null 2>&1

  git config --file "$proj/dev/.orbit" --add pr.url "https://github.com/acme/myrepo/pull/7"
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  local bin="$SANDBOX/ghbin2"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'EOF'
#!/bin/sh
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  printf '{"state":"%s","headRefName":"%s","headRefOid":"%s"}\n' "$STUB_STATE" "$STUB_HEAD" "$STUB_OID"
  exit "${STUB_RC:-0}"
fi
exit 1
EOF
  chmod +x "$bin/gh"

  run bash -c "export PATH='$bin':\$PATH STUB_STATE=MERGED STUB_HEAD=feat STUB_OID='$pushed_tip'; cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  refute_contains "$output" "deleted branch (PR merged)"
  assert_contains "$output" "keeping unmerged branch: ws/dev/feat"
  assert_dir_exists "$proj/dev"
}

@test "prune: gh failure degrades layer 1 with ONE warning for the whole run" {
  local proj="$SANDBOX/prune-gh-down"
  local remote="$REMOTES/prune-gh-down-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "https://github.com/acme/myrepo.git" >/dev/null 2>&1
  cd "$proj" && orbit new "gh down" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  git -C "$proj/dev/myrepo" checkout -b ws/dev/feat1 >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" config branch.ws/dev/feat1.remote origin
  git -C "$proj/.repos/myrepo" config branch.ws/dev/feat1.merge refs/heads/feat1
  echo a > "$proj/dev/myrepo/a.txt"
  git -C "$proj/dev/myrepo" add a.txt && git -C "$proj/dev/myrepo" commit -qm a
  git -C "$proj/dev/myrepo" checkout -b ws/dev/feat2 >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" config branch.ws/dev/feat2.remote origin
  git -C "$proj/.repos/myrepo" config branch.ws/dev/feat2.merge refs/heads/feat2
  echo b > "$proj/dev/myrepo/b.txt"
  git -C "$proj/dev/myrepo" add b.txt && git -C "$proj/dev/myrepo" commit -qm b

  git config --file "$proj/dev/.orbit" --add pr.url "https://github.com/acme/myrepo/pull/7"
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  local bin="$SANDBOX/ghbin3"
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 1\n' > "$bin/gh"
  chmod +x "$bin/gh"

  run bash -c "export PATH='$bin':\$PATH; cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  local warns
  warns=$(printf '%s' "$output" | grep -c "PR evidence recorded but gh unavailable")
  [ "$warns" -eq 1 ]
  assert_contains "$output" "keeping unmerged branch: ws/dev/feat1"
  assert_contains "$output" "keeping unmerged branch: ws/dev/feat2"
  assert_dir_exists "$proj/dev"
}

@test "prune: a PR URL for another repo is ignored — gh never called" {
  local proj="$SANDBOX/prune-pr-foreign"
  local remote="$REMOTES/prune-pr-foreign-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "https://github.com/acme/myrepo.git" >/dev/null 2>&1
  cd "$proj" && orbit new "pr foreign" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  git -C "$proj/dev/myrepo" checkout -b ws/dev/feat >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" config branch.ws/dev/feat.remote origin
  git -C "$proj/.repos/myrepo" config branch.ws/dev/feat.merge refs/heads/feat
  echo x > "$proj/dev/myrepo/x.txt"
  git -C "$proj/dev/myrepo" add x.txt && git -C "$proj/dev/myrepo" commit -qm x

  # recorded PR points at a DIFFERENT repo — no evidence for this pool
  git config --file "$proj/dev/.orbit" --add pr.url "https://github.com/acme/other/pull/7"
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  local bin="$SANDBOX/ghbin4"
  mkdir -p "$bin"
  cat > "$bin/gh" <<EOF
#!/bin/sh
echo called >> '$SANDBOX/gh-calls'
exit 1
EOF
  chmod +x "$bin/gh"

  run bash -c "export PATH='$bin':\$PATH; cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/gh-calls" ]
  assert_contains "$output" "keeping unmerged branch: ws/dev/feat"
}

# --- Review follow-ups: multi-segment names, dotted config, scan failure,
# garbage pointer ---

@test "prune: layer 1 maps multi-segment branch names via the recorded upstream" {
  local proj="$SANDBOX/prune-pr-multiseg"
  local remote="$REMOTES/prune-pr-multiseg-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "https://github.com/acme/myrepo.git" >/dev/null 2>&1
  cd "$proj" && orbit new "pr multiseg" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  # feat/login is the mainstream branch-naming convention: the local scoped
  # name is ws/dev/feat/login, the PR head is feat/login — a last-segment
  # mapping would never fire
  git -C "$proj/dev/myrepo" checkout -b ws/dev/feat/login >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" config branch.ws/dev/feat/login.remote origin
  git -C "$proj/.repos/myrepo" config branch.ws/dev/feat/login.merge refs/heads/feat/login
  echo "work" > "$proj/dev/myrepo/work.txt"
  git -C "$proj/dev/myrepo" add work.txt
  git -C "$proj/dev/myrepo" commit -m "work" >/dev/null 2>&1
  local tip
  tip=$(git -C "$proj/dev/myrepo" rev-parse HEAD)

  git config --file "$proj/dev/.orbit" --add pr.url "https://github.com/acme/myrepo/pull/9"
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  local bin="$SANDBOX/ghbin-ms"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'EOF'
#!/bin/sh
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  printf '{"state":"%s","headRefName":"%s","headRefOid":"%s"}\n' "$STUB_STATE" "$STUB_HEAD" "$STUB_OID"
  exit 0
fi
exit 1
EOF
  chmod +x "$bin/gh"

  run bash -c "export PATH='$bin':\$PATH STUB_STATE=MERGED STUB_HEAD=feat/login STUB_OID='$tip'; cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "deleted branch (PR merged): ws/dev/feat/login"
  [ ! -d "$proj/dev" ]
}

@test "prune: orphan branch config with a dotted name is reaped, not stuck forever" {
  local proj="$SANDBOX/prune-orphan-dotted"
  local remote="$REMOTES/prune-orphan-dotted-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  # an orphan section for a branch that never existed — with a DOT in the
  # name: branch.feat.v2.merge parses as name=feat.v2, key=merge
  git -C "$proj/.repos/myrepo" config branch.feat.v2.remote origin
  git -C "$proj/.repos/myrepo" config branch.feat.v2.merge refs/heads/feat.v2

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "1 orphan branch config section(s)"
  run git -C "$proj/.repos/myrepo" config --get branch.feat.v2.merge
  [ -z "$output" ]
}

@test "prune: live orphan-worktree upstream config survives pool maintenance (empty repo)" {
  local proj="$SANDBOX/prune-empty-live"
  local remote="$SANDBOX/empty_remote_prune-empty-live.git"
  create_empty_bare_repo "$remote"
  TEST_PROJECT="$proj"
  mkdir -p "$proj"
  cd "$proj" && orbit clone "$remote" --name emptyrepo >/dev/null 2>&1
  cd "$proj" && orbit new "empty prune" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add emptyrepo >/dev/null 2>&1
  cd "$SANDBOX"

  # Both unborn sections are alive: the worktree's scoped branch (checked out)
  # and the pool HEAD's target (clone-written default — first-push routing).
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  refute_contains "$output" "orphan branch config section(s)"
  local merge
  merge=$(git -C "$proj/.repos/emptyrepo" config --get branch.ws/dev/main.merge)
  [ "$merge" = "refs/heads/main" ]
  merge=$(git -C "$proj/.repos/emptyrepo" config --get branch.main.merge)
  [ "$merge" = "refs/heads/main" ]
}

@test "prune: done empty-repo workspace reclaims cleanly — worktree unborn config reaped, pool default survives" {
  local proj="$SANDBOX/prune-empty-done"
  local remote="$SANDBOX/empty_remote_prune-empty-done.git"
  create_empty_bare_repo "$remote"
  TEST_PROJECT="$proj"
  mkdir -p "$proj"
  cd "$proj" && orbit clone "$remote" --name emptyrepo >/dev/null 2>&1
  cd "$proj" && orbit new "empty done" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add emptyrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "pruned: dev (1 worktree removed, 0 branches deleted)"
  [ ! -d "$proj/dev" ]
  # D1 removed the worktree first, so the scoped branch's unborn config is
  # reaped — but the pool HEAD's target (the empty repo's clone-written
  # default) stays protected: it is first-push routing for the pool's next
  # worktree.
  run git -C "$proj/.repos/emptyrepo" config --get branch.ws/dev/main.merge
  [ -z "$output" ]
  local merge
  merge=$(git -C "$proj/.repos/emptyrepo" config --get branch.main.merge)
  [ "$merge" = "refs/heads/main" ]
}

@test "prune: empty-repo default-branch config is protected whatever its name (dev)" {
  local proj="$SANDBOX/prune-empty-dev-default"
  local remote="$SANDBOX/empty_remote_prune-empty-dev-default.git"
  git init --bare "$remote" >/dev/null 2>&1
  git -C "$remote" symbolic-ref HEAD refs/heads/dev
  TEST_PROJECT="$proj"
  mkdir -p "$proj"
  cd "$proj" && orbit clone "$remote" --name emptyrepo >/dev/null 2>&1
  cd "$proj" && orbit new "empty dev default" --name ws1 >/dev/null 2>&1
  cd "$proj/ws1" && orbit add emptyrepo >/dev/null 2>&1
  cd "$SANDBOX"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  refute_contains "$output" "orphan branch config section(s)"
  local merge
  merge=$(git -C "$proj/.repos/emptyrepo" config --get branch.dev.merge)
  [ "$merge" = "refs/heads/dev" ]
}

@test "prune: a pool that cannot scan branches blocks the live workspace — both modes" {
  local proj="$SANDBOX/prune-scan-fail"
  local remote="$REMOTES/prune-scan-fail-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "scan fail" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  # fail for-each-ref only: a blind scan must never pass as empty on the
  # live path — and --force cannot supply the branch set git failed to read
  local bin="$SANDBOX/gitbin" real_git
  real_git=$(command -v git)
  mkdir -p "$bin"
  cat > "$bin/git" <<EOF
#!/bin/sh
case "\$*" in
  *for-each-ref*) exit 128 ;;
esac
exec "$real_git" "\$@"
EOF
  chmod +x "$bin/git"

  run bash -c "export PATH='$bin':\$PATH; cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "skipping dev: cannot scan branches in: myrepo"
  assert_dir_exists "$proj/dev"
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/main
  [ "$status" -eq 0 ]

  run bash -c "export PATH='$bin':\$PATH; cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --force 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "skipping dev: cannot scan branches in: myrepo"
  assert_dir_exists "$proj/dev"
}

@test "prune: damaged worktree with a garbage .git pointer — --force clears it" {
  local proj="$SANDBOX/prune-damaged-garbage"
  local remote="$REMOTES/prune-damaged-garbage-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "damaged garbage" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  # the pointer is a file but unusable: truncated or overwritten with garbage
  printf 'not a gitdir\n' > "$proj/dev/myrepo/.git"
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "damaged worktree in myrepo"
  assert_dir_exists "$proj/dev"

  # force: repair re-links the pointer, the ordinary remove then works
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune --force 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "--force removes myrepo whose state cannot be read"
  assert_contains "$output" "pruned: dev"
  [ ! -d "$proj/dev" ]
  run git -C "$proj/.repos/myrepo" worktree list
  refute_contains "$output" "dev/myrepo"
}

@test "prune: merged PR but branch has NO recorded upstream — layer 1 stays out" {
  local proj="$SANDBOX/prune-pr-noupstream"
  local remote="$REMOTES/prune-pr-noupstream-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "https://github.com/acme/myrepo.git" >/dev/null 2>&1
  cd "$proj" && orbit new "pr noupstream" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  # raw-git created the scoped branch: no branch.*.merge — the name-mapping
  # heuristic would fire, the recorded-upstream mapping must not
  git -C "$proj/dev/myrepo" checkout -b ws/dev/feat >/dev/null 2>&1
  echo "work" > "$proj/dev/myrepo/work.txt"
  git -C "$proj/dev/myrepo" add work.txt
  git -C "$proj/dev/myrepo" commit -m "work" >/dev/null 2>&1
  local tip
  tip=$(git -C "$proj/dev/myrepo" rev-parse HEAD)

  git config --file "$proj/dev/.orbit" --add pr.url "https://github.com/acme/myrepo/pull/7"
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  local bin="$SANDBOX/ghbin-nu"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'EOF'
#!/bin/sh
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  printf '{"state":"%s","headRefName":"%s","headRefOid":"%s"}\n' "$STUB_STATE" "$STUB_HEAD" "$STUB_OID"
  exit 0
fi
exit 1
EOF
  chmod +x "$bin/gh"

  run bash -c "export PATH='$bin':\$PATH STUB_STATE=MERGED STUB_HEAD=feat STUB_OID='$tip'; cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  refute_contains "$output" "deleted branch (PR merged)"
  assert_contains "$output" "keeping unmerged branch: ws/dev/feat"
  assert_dir_exists "$proj/dev"
}

@test "prune: a pr.url with glob characters is treated literally" {
  local proj="$SANDBOX/prune-pr-glob"
  local remote="$REMOTES/prune-pr-glob-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "https://github.com/acme/myrepo.git" >/dev/null 2>&1
  cd "$proj" && orbit new "pr glob" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout -b ws/dev/feat >/dev/null 2>&1
  echo x > "$proj/dev/myrepo/x.txt"
  git -C "$proj/dev/myrepo" add x.txt && git -C "$proj/dev/myrepo" commit -qm x

  # .orbit is agent-writable: a hostile/garbage URL must not pathname-expand
  # against the cwd nor crash the run
  git config --file "$proj/dev/.orbit" --add pr.url "https://github.com/acme/*/pull/7"
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "keeping unmerged branch: ws/dev/feat"
  assert_dir_exists "$proj/dev"
}

@test "prune: ghost branch deletion refused by git — exit non-zero, no false keep, no doomed suggestion" {
  local proj="$SANDBOX/prune-ghost-refused"
  local remote="$REMOTES/prune-ghost-refused-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "gone" --name gone >/dev/null 2>&1
  cd "$proj/gone" && orbit add myrepo >/dev/null 2>&1
  git -C "$proj/gone/myrepo" checkout -b ws/gone/feat >/dev/null 2>&1
  echo "work" > "$proj/gone/myrepo/work.txt"
  git -C "$proj/gone/myrepo" add work.txt
  git -C "$proj/gone/myrepo" commit -m "work" >/dev/null 2>&1
  git -C "$proj/gone/myrepo" checkout ws/gone/main >/dev/null 2>&1
  git -C "$proj/gone/myrepo" merge ws/gone/feat >/dev/null 2>&1
  git -C "$proj/gone/myrepo" push origin ws/gone/main:main >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" fetch origin >/dev/null 2>&1
  cd "$proj/gone" && orbit done >/dev/null 2>&1

  # a live workspace checks out the merged branch — its deletion must refuse
  cd "$proj" && orbit new "live" --name live >/dev/null 2>&1
  cd "$proj/live" && orbit add myrepo >/dev/null 2>&1
  git -C "$proj/live/myrepo" checkout ws/gone/feat >/dev/null 2>&1
  cd "$SANDBOX"
  rm -rf "$proj/gone"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  # a step FAILED (branch deletion refused) — not a validation refusal
  [ "$status" -ne 0 ]
  assert_contains "$output" "cannot delete branch"
  # the branch IS merged — it must not be mislabeled as a kept unmerged one
  refute_contains "$output" "kept branch (unmerged): ws/gone/feat"
  # and the closing block must not suggest a force rerun that would fail again
  refute_contains "$output" "orbit prune gone --force"
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/gone/feat
  [ "$status" -eq 0 ]
}

@test "prune: targeted --older refusal states the age fact, not 'not marked done'" {
  local proj="$SANDBOX/prune-older-targeted"
  clone_project "$proj"
  cd "$proj" && orbit new "young" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune dev --older 30d 2>&1"
  [ "$status" -ne 0 ]
  assert_contains "$output" "dev is marked done but not older than 30d"
  refute_contains "$output" "not marked done"
  assert_dir_exists "$proj/dev"
}

@test "prune: a non-standard fetch config is converged even with no workspaces at all" {
  local proj="$SANDBOX/prune-config-empty"
  local remote="$REMOTES/prune-config-empty-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  # legacy shape: exact default entry plus a stale one, no prune key
  git -C "$proj/.repos/myrepo" config --replace-all remote.origin.fetch \
    "+refs/heads/main:refs/remotes/origin/main"
  git -C "$proj/.repos/myrepo" config --add remote.origin.fetch \
    "+refs/heads/gone:refs/remotes/origin/gone"
  git -C "$proj/.repos/myrepo" config --unset-all fetch.prune 2>/dev/null || true

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" 'orbit: myrepo: fetch config converged: git remote set-branches origin "*" (stop converging and re-apply yours: orbit config git.fetchAllBranches once)'
  assert_contains "$output" 'orbit: myrepo: fetch config converged: git config fetch.prune true (stop converging and re-apply yours: orbit config git.fetchPrune once)'
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/*:refs/remotes/origin/*" ]
  [ "$(git -C "$proj/.repos/myrepo" config --type=bool --get fetch.prune)" = "true" ]
}

@test "prune --dry-run: targeted ghost previews fetch-config convergence" {
  local proj="$SANDBOX/prune-ghost-dry-converge"
  local remote="$REMOTES/prune-ghost-dry-converge-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "ghost dry converge" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"
  rm -rf "$proj/dev"

  # legacy config the default mode owns
  git -C "$proj/.repos/myrepo" config --replace-all remote.origin.fetch \
    "+refs/heads/main:refs/remotes/origin/main"
  git -C "$proj/.repos/myrepo" config --add remote.origin.fetch \
    "+refs/heads/gone:refs/remotes/origin/gone"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune dev --dry-run 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "would prune: dev (residue)"
  # pool-level accounts report under their own section, not inside the ghost block
  assert_contains "$output" "pool maintenance:"
  assert_contains "$output" 'would converge fetch config: git remote set-branches origin "*"'
  # preview only: the config is still there
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  assert_contains "$output" "refs/heads/gone"
}

@test "prune: default-branch fetch failure alarms only when the remote answers" {
  local proj="$SANDBOX/prune-default-gone"
  local remote="$REMOTES/prune-default-gone-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  local bin="$SANDBOX/gitbin-probe" real_git
  real_git=$(command -v git)
  mkdir -p "$bin"
  cat > "$bin/git" <<EOF
#!/bin/sh
case "\$*" in
  *ls-remote*) printf '%s\n' "\$*" >> '$SANDBOX/lsremote-calls' ;;
esac
exec "$real_git" "\$@"
EOF
  chmod +x "$bin/git"

  # control: remote intact — a quiet prune makes no probe and no alarm
  run bash -c "export PATH='$bin':\$PATH; cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/lsremote-calls" ]
  refute_contains "$output" "may have lost its default branch"

  # the remote loses its default branch
  git -C "$remote" config receive.denyDeleteCurrent ignore
  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_pdg_XXXXXX")
  git clone "$remote" "$tmp" >/dev/null 2>&1
  git -C "$tmp" push origin --delete main >/dev/null 2>&1
  rm -rf "$tmp"

  run bash -c "export PATH='$bin':\$PATH; cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  # the alarm fires, and the discriminator was one probe — not a scan
  assert_contains "$output" "WARNING: cannot fetch default branch origin/main though the remote answers"
  assert_contains "$output" "may have lost its default branch"
  grep -q -- "--exit-code" "$SANDBOX/lsremote-calls"
}

@test "prune: default-branch fetch failure stays silent when the remote does not answer" {
  local proj="$SANDBOX/prune-offline"
  clone_project "$proj"
  # offline shape: origin points at a path that does not exist — the default
  # fetch fails and the probe fails with it (rc 128), which must read as
  # routine, not as a repo-level event
  git -C "$proj/.repos/myrepo" remote set-url origin "$SANDBOX/no-such-remote.git" >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  refute_contains "$output" "may have lost its default branch"
}

@test "prune: rename into an unwritable trash fails closed — workspace kept, exit non-zero" {
  local proj="$SANDBOX/prune-rename-fails"
  clone_project "$proj"
  cd "$proj" && orbit new "rename fails" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"

  mkdir -p "$proj/.prune-trash"
  chmod 555 "$proj/.prune-trash"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  # restore for teardown — the closing rmdir may already have removed the
  # (empty) trash, so guard the restore
  [ ! -e "$proj/.prune-trash" ] || chmod 755 "$proj/.prune-trash"
  [ "$status" -ne 0 ]
  assert_contains "$output" "rename to .prune-trash failed"
  assert_contains "$output" "workspace kept"
  assert_dir_exists "$proj/dev"
}

@test "prune: an unclearable trash entry is reported and the run exits non-zero" {
  local proj="$SANDBOX/prune-sweep-fails"
  clone_project "$proj"
  mkdir -p "$proj/.prune-trash/old-ws"
  touch "$proj/.prune-trash/old-ws/content"
  chmod 555 "$proj/.prune-trash/old-ws"
  cd "$SANDBOX"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  chmod 755 "$proj/.prune-trash/old-ws"   # restore for teardown
  [ "$status" -ne 0 ]
  assert_contains "$output" "trash removal incomplete"
  assert_contains "$output" "resumed on the next run"
  assert_dir_exists "$proj/.prune-trash/old-ws"
}

@test "prune: -d refusal against a lagging local default retries with -D" {
  local proj="$SANDBOX/prune-lagging-default"
  local remote="$REMOTES/prune-lagging-default-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "lagging" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  echo "work" > "$proj/dev/myrepo/work.txt"
  git -C "$proj/dev/myrepo" add work.txt
  git -C "$proj/dev/myrepo" commit -m "work" >/dev/null 2>&1
  # push the work upstream but keep the pool's LOCAL main behind: layer 2
  # passes (ancestor of origin/main), git -d measures against the lagging
  # local checkout and refuses — the one -D retry must delete it
  git -C "$proj/dev/myrepo" push origin HEAD:main >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" fetch origin >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1
  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "deleted branch (merged): ws/dev/main"
  [ ! -d "$proj/dev" ]
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/dev/main
  [ "$status" -ne 0 ]
}

@test "prune: residue verdicts read this touchpoint's converged refs" {
  local proj="$SANDBOX/prune-residue-order"
  local remote="$REMOTES/prune-residue-order-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  # a raw branch with a configured upstream whose remote branch is gone; the
  # stale ref would mask it as "traceable" if the residue scan ran before
  # the touchpoint's conditional prune
  git -C "$proj/.repos/myrepo" branch ghost-x main
  git -C "$proj/.repos/myrepo" config branch.ghost-x.remote origin
  git -C "$proj/.repos/myrepo" config branch.ghost-x.merge refs/heads/gone-x
  git -C "$proj/.repos/myrepo" update-ref refs/remotes/origin/gone-x \
    "$(git -C "$proj/.repos/myrepo" rev-parse main)"

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  # fetch fails for gone-x (swallowed) → conditional prune deletes the stale
  # ref → the residue scan then sees ghost-x as the untraceable branch it is
  refute_contains "$output" "couldn't find remote ref"
  assert_contains "$output" "    ghost-x (merged)"
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/remotes/origin/gone-x
  [ "$status" -ne 0 ]
}

@test "prune: two local branches sharing one dead upstream are cleaned in one pass" {
  local proj="$SANDBOX/prune-shared-upstream"
  local remote="$REMOTES/prune-shared-upstream-repo.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new "shared one" --name ws1 >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/ws1/myrepo" && orbit switch -c feat-shared >/dev/null 2>&1
  echo s > s.txt && git add s.txt && git commit -m "s" >/dev/null 2>&1
  git push >/dev/null 2>&1

  # a second workspace branch tracks the same upstream
  cd "$proj" && orbit new "shared two" --name ws2 >/dev/null 2>&1
  cd "$proj/ws2" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/ws2/myrepo" && orbit switch feat-shared >/dev/null 2>&1
  git rev-parse --verify --quiet origin/feat-shared >/dev/null

  # the remote deletes the shared upstream
  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_psu_XXXXXX")
  git clone "$remote" "$tmp" >/dev/null 2>&1
  git -C "$tmp" push origin --delete feat-shared >/dev/null 2>&1
  rm -rf "$tmp"

  cd "$SANDBOX"
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' prune 2>&1"
  [ "$status" -eq 0 ]
  refute_contains "$output" "couldn't find remote ref"
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/remotes/origin/feat-shared
  [ "$status" -ne 0 ]
  # both local branches stay
  git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/ws1/feat-shared >/dev/null
  git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/heads/ws/ws2/feat-shared >/dev/null
}
