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

_push_update_to() {
  # push a new commit to the given remote so sync can fast-forward
  local remote="$1"
  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_sync_XXXXXX")
  git clone "$remote" "$tmp" >/dev/null 2>&1
  (
    cd "$tmp"
    echo "update" > update.txt
    git add update.txt >/dev/null 2>&1
    git commit -m "update" >/dev/null 2>&1
    git push origin main >/dev/null 2>&1
  )
  rm -rf "$tmp"
}

@test "sync: hints pull when worktree tracks the branch sync advanced" {
  local proj="$SANDBOX/sync-hint-ws"
  local remote="$REMOTES/sync-hint-ws.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  cd "$proj" && orbit new "hint test" --name ws1 >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1

  _push_update_to "$remote"

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" "untouched by sync"
}

@test "sync: no hint when worktree is on a non-matching branch" {
  local proj="$SANDBOX/sync-hint-feat"
  local remote="$REMOTES/sync-hint-feat.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  cd "$proj" && orbit new "hint test" --name ws1 >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1
  # raw-mode feature branch: no upstream, does not track origin/main
  git -C "$proj/ws1/myrepo" checkout -b feature/x >/dev/null 2>&1

  _push_update_to "$remote"

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo 2>&1"
  [ "$status" -eq 0 ]
  ! assert_contains "$output" "untouched by sync"
}

@test "sync: no worktree hint at project root" {
  local proj="$SANDBOX/sync-hint-root"
  local remote="$REMOTES/sync-hint-root.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  _push_update_to "$remote"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo 2>&1"
  [ "$status" -eq 0 ]
  ! assert_contains "$output" "untouched by sync"
}

# --- info behavior (purely local — no fetch touchpoint) ---

@test "info: never fetches — upstream warning reflects last-fetched refs" {
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

  # purely local: the push is invisible to info until some fetch refreshes
  # the tracking refs
  local stderr_output
  stderr_output=$(cd "$proj" && orbit info myrepo 2>&1 >/dev/null || true)
  refute_contains "$stderr_output" "new commits on origin/main"

  # after any fetch (a fetching touchpoint, or the user's own), info reads
  # the refreshed refs
  git -C "$proj/.repos/myrepo" fetch origin main >/dev/null 2>&1
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

# --- Readable sync output ---

@test "sync: reports already up to date when nothing changed" {
  local proj="$SANDBOX/sync-noop"
  local remote="$REMOTES/sync-noop.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo"
  [ "$status" -eq 0 ]
  assert_contains "$output" "myrepo: already up to date"
  # no false fast-forward claim when HEAD did not move
  [[ "$output" != *"fast-forwarded"* ]]
}

@test "sync: batch mode distinguishes fast-forwarded vs up-to-date and tallies" {
  local proj="$SANDBOX/sync-batch"
  local remote1="$REMOTES/sync-batch1.git"
  local remote2="$REMOTES/sync-batch2.git"
  clone_remote "$remote1"
  clone_remote "$remote2"
  clone_project "$proj"
  cd "$proj" && orbit clone "$remote2" --name repo2 >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote1" >/dev/null 2>&1
  git -C "$proj/.repos/repo2" remote set-url origin "$remote2" >/dev/null 2>&1

  # Advance only remote1; remote2 stays put
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

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync"
  [ "$status" -eq 0 ]
  assert_contains "$output" "myrepo: fast-forwarded 1 commit → origin/main"
  assert_contains "$output" "repo2: already up to date"
  assert_contains "$output" "sync complete: 2 ok, 0 failed"
}

# --- Remote-deleted branches & fetch-config maintenance ---

@test "sync: cleans the tracking ref of a remote-deleted tracked branch, zero fatal leak" {
  local proj="$SANDBOX/sync-gone"
  local remote="$REMOTES/sync-gone.git"
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
  tmp=$(mktemp -d "$SANDBOX/_tmp_sg_XXXXXX")
  git clone "$remote" "$tmp" >/dev/null 2>&1
  git -C "$tmp" push origin --delete feat-gone >/dev/null 2>&1
  rm -rf "$tmp"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo 2>&1"
  [ "$status" -eq 0 ]
  # the fatal this model exists to kill never leaks out of the touchpoint
  refute_contains "$output" "couldn't find remote ref"
  # the tracked-but-gone ref is converged natively (conditional remote prune)
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/remotes/origin/feat-gone
  [ "$status" -ne 0 ]
  # config untouched: exactly the wildcard
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/*:refs/remotes/origin/*" ]
}

@test "sync: converges a legacy exact-entry config, reports once on stderr" {
  local proj="$SANDBOX/sync-converge"
  clone_project "$proj"

  # legacy shape: exact default entry only, no prune key
  git -C "$proj/.repos/myrepo" config --replace-all remote.origin.fetch \
    "+refs/heads/main:refs/remotes/origin/main"
  git -C "$proj/.repos/myrepo" config --unset-all fetch.prune 2>/dev/null || true

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" 'orbit: myrepo: fetch config converged: git remote set-branches origin "*" (stop converging and re-apply yours: orbit config git.fetchAllBranches once)'
  assert_contains "$output" 'orbit: myrepo: fetch config converged: git config fetch.prune true (stop converging and re-apply yours: orbit config git.fetchPrune once)'
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/*:refs/remotes/origin/*" ]
  [ "$(git -C "$proj/.repos/myrepo" config --type=bool --get fetch.prune)" = "true" ]

  # one-shot: the next touchpoint has nothing to converge and stays quiet
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo 2>&1"
  refute_contains "$output" "fetch config converged"
}

@test "sync: converges push.default, reports once on stderr" {
  local proj="$SANDBOX/sync-converge-push"
  clone_project "$proj"

  git -C "$proj/.repos/myrepo" config push.default simple

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" 'orbit: myrepo: push routing converged: git config push.default upstream (stop converging and re-apply yours: orbit config git.pushUpstreamByDefault once)'
  [ "$(git -C "$proj/.repos/myrepo" config --get push.default)" = "upstream" ]

  # one-shot: the next touchpoint has nothing to converge and stays quiet
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo 2>&1"
  refute_contains "$output" "push routing converged"
}

@test "sync: git.pushUpstreamByDefault=once leaves a custom push.default untouched and unreported" {
  local proj="$SANDBOX/sync-push-clone"
  clone_project "$proj"
  orbit config git.pushUpstreamByDefault once >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" config push.default simple

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo 2>&1"
  [ "$status" -eq 0 ]
  refute_contains "$output" "push routing converged"
  [ "$(git -C "$proj/.repos/myrepo" config --get push.default)" = "simple" ]
}

@test "sync: git.fetchAllBranches=once leaves a custom layout untouched and unreported" {
  local proj="$SANDBOX/sync-custom-layout"
  clone_project "$proj"
  # a custom layout is opted out per key: the map AND the prune key
  orbit config git.fetchAllBranches once >/dev/null 2>&1
  orbit config git.fetchPrune once >/dev/null 2>&1

  # a team-narrowed layout: scoped wildcard only, no prune key
  git -C "$proj/.repos/myrepo" config --replace-all remote.origin.fetch \
    "+refs/heads/feat/*:refs/remotes/origin/feat/*"
  git -C "$proj/.repos/myrepo" config --unset-all fetch.prune 2>/dev/null || true

  # a tracked branch the remote never had: its stale ref is the user's
  # territory under a narrowed layout — the conditional prune is gated on
  # the full wildcard being in place
  git -C "$proj/.repos/myrepo" branch demo main
  git -C "$proj/.repos/myrepo" config branch.demo.remote origin
  git -C "$proj/.repos/myrepo" config branch.demo.merge refs/heads/demo-gone
  git -C "$proj/.repos/myrepo" update-ref refs/remotes/origin/demo-gone \
    "$(git -C "$proj/.repos/myrepo" rev-parse main)"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo 2>&1"
  [ "$status" -eq 0 ]
  refute_contains "$output" "fetch config converged"
  refute_contains "$output" "couldn't find remote ref"
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/feat/*:refs/remotes/origin/feat/*" ]
  run git -C "$proj/.repos/myrepo" config --get fetch.prune
  [ "$status" -ne 0 ]
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/remotes/origin/demo-gone
  [ "$status" -eq 0 ]
}

@test "sync: git.fetchPrune=never leaves the prune key unset while the map is maintained" {
  local proj="$SANDBOX/sync-prune-off"
  clone_project "$proj"
  orbit config git.fetchPrune never >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" config --unset-all fetch.prune 2>/dev/null || true

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo 2>&1"
  [ "$status" -eq 0 ]
  run git -C "$proj/.repos/myrepo" config --get fetch.prune
  [ "$status" -ne 0 ]
  # the map is a different key: still maintained
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/*:refs/remotes/origin/*" ]
}

@test "sync: a never pool is user territory — zero writes, zero reports" {
  local proj="$SANDBOX/sync-never-pool"
  clone_project "$proj"
  # the never-from-birth shape: single-branch entry, no prune key, no push key
  orbit config git.fetchAllBranches never >/dev/null 2>&1
  orbit config git.fetchPrune never >/dev/null 2>&1
  orbit config git.pushUpstreamByDefault never >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" config --replace-all remote.origin.fetch \
    "+refs/heads/main:refs/remotes/origin/main"
  git -C "$proj/.repos/myrepo" config --unset-all fetch.prune 2>/dev/null || true
  git -C "$proj/.repos/myrepo" config --unset-all push.default 2>/dev/null || true

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo 2>&1"
  [ "$status" -eq 0 ]
  refute_contains "$output" "converged"
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/main:refs/remotes/origin/main" ]
  run git -C "$proj/.repos/myrepo" config --get fetch.prune
  [ "$status" -ne 0 ]
  run git -C "$proj/.repos/myrepo" config --get push.default
  [ "$status" -ne 0 ]
}

@test "sync: converges an emptied fetch config (the count=0 shape)" {
  local proj="$SANDBOX/sync-empty-config"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" config --unset-all remote.origin.fetch

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo 2>&1"
  [ "$status" -eq 0 ]
  assert_contains "$output" 'orbit: myrepo: fetch config converged: git remote set-branches origin "*" (stop converging and re-apply yours: orbit config git.fetchAllBranches once)'
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/*:refs/remotes/origin/*" ]
}

@test "info: purely local — a remote-lost tracked branch's stale ref stays put" {
  local proj="$SANDBOX/info-gone"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" branch demo main
  git -C "$proj/.repos/myrepo" config branch.demo.remote origin
  git -C "$proj/.repos/myrepo" config branch.demo.merge refs/heads/demo-gone
  git -C "$proj/.repos/myrepo" update-ref refs/remotes/origin/demo-gone \
    "$(git -C "$proj/.repos/myrepo" rev-parse main)"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' info myrepo 2>&1"
  [ "$status" -eq 0 ]
  refute_contains "$output" "couldn't find remote ref"
  # no fetch touchpoint here: converging the stale ref is the fetching
  # touchpoints' business (the sync variant above), not a screening command's
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/remotes/origin/demo-gone
  [ "$status" -eq 0 ]
}

# --- Pool-wide scope: --branch is root-only ---

@test "sync --branch: refuses to run from inside a workspace" {
  local proj="$SANDBOX/sync-branch-inside-ws"
  clone_project "$proj"
  (cd "$proj" && orbit new "scope test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)

  # Parked-ancestor topology: the trailing exit keeps bash from exec-collapsing
  # the last command (Linux), which would leave a clean ancestry and flip the
  # guard to the cd-replay variant — the assertion is platform-dependent without it.
  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo --branch feature; rc=\$?; exit \$rc"
  [ "$status" -ne 0 ]
  assert_contains "$output" "sync --branch should not be initiated from inside workspace dev"
}

@test "sync --branch: bare sync still works from inside a workspace" {
  local proj="$SANDBOX/sync-bare-inside-ws"
  clone_project "$proj"
  (cd "$proj" && orbit new "scope test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo"
  [ "$status" -eq 0 ]
}

@test "sync --branch: no config writes; origin/HEAD migrates" {
  local proj="$SANDBOX/sync-branch-refspecs"
  local remote="$REMOTES/sync-branch-refspecs.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  # another branch on the remote to switch the pool to
  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_srs_XXXXXX")
  git clone "$remote" "$tmp" >/dev/null 2>&1
  (
    cd "$tmp"
    git checkout -q -b dev
    echo d > d.txt && git add d.txt
    git commit -q -m "dev"
    git push -q origin dev
  )
  rm -rf "$tmp"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo --branch dev"
  [ "$status" -eq 0 ]
  assert_contains "$output" "pool: switched myrepo to branch dev"

  # the wildcard map covered the new default branch — nothing registered,
  # nothing retargeted
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/*:refs/remotes/origin/*" ]
  [ "$(git -C "$proj/.repos/myrepo" symbolic-ref refs/remotes/origin/HEAD)" = "refs/remotes/origin/dev" ]
  [ "$(git -C "$proj/.repos/myrepo" branch --show-current)" = "dev" ]

  run git -C "$proj/.repos/myrepo" fetch origin
  [ "$status" -eq 0 ]
}

@test "sync --branch: failed fetch leaves config and origin/HEAD untouched" {
  local proj="$SANDBOX/sync-branch-rollback"
  local remote="$REMOTES/sync-branch-rollback.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  local before
  before=$(git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch)

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo --branch does-not-exist 2>&1"
  [ "$status" -ne 0 ]
  assert_contains "$output" "cannot fetch branch: does-not-exist"

  # no residue pointing at the missing branch, and the pool's checkout and
  # origin/HEAD stay on the live branch
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "$before" ]
  [ "$(git -C "$proj/.repos/myrepo" symbolic-ref refs/remotes/origin/HEAD)" = "refs/remotes/origin/main" ]
  [ "$(git -C "$proj/.repos/myrepo" branch --show-current)" = "main" ]
  run git -C "$proj/.repos/myrepo" fetch origin
  [ "$status" -eq 0 ]
}

# --- Repo name is a pool basename, never a path ---

@test "sync: refuses a traversing repo name instead of resolving it" {
  local proj="$SANDBOX/sync-traversal"
  clone_project "$proj"
  (cd "$proj" && orbit new "traversal test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)
  echo "work in progress" > "$proj/dev/myrepo/wip.txt"

  # ../dev/myrepo lands on the workspace worktree; --force would reset --hard
  # someone's working branch. The name must be rejected as a name.
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync ../dev/myrepo --force 2>&1"
  [ "$status" -ne 0 ]
  assert_contains "$output" "invalid repo name"
  assert_file_exists "$proj/dev/myrepo/wip.txt"
}

@test "info/memo: refuse a traversing repo name" {
  local proj="$SANDBOX/name-traversal"
  clone_project "$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' info ../.repos/myrepo"
  [ "$status" -ne 0 ]
  assert_contains "$output" "invalid repo name"

  run bash -c "cd '$proj' && printf '# x\n\nbrief\n' | ORBIT_ROOT='$proj' bash '$ORBIT_CMD' memo ../.repos/myrepo"
  [ "$status" -ne 0 ]
  assert_contains "$output" "invalid repo name"
}

@test "repo names: GitHub charset accepted, other characters refused" {
  local proj="$SANDBOX/name-charset"
  clone_project "$proj"

  # Dots and mixed case are legal GitHub names and must pass name validation
  # (the repo just isn't in the pool yet).
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' info My.Repo.io"
  [ "$status" -ne 0 ]
  assert_contains "$output" "not in pool"

  # Spaces, leading '.' and leading '-' are outside the contract.
  for bad in 'my repo' '.github' 'my^repo'; do
    run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' info '$bad'"
    [ "$status" -ne 0 ]
    assert_contains "$output" "invalid repo name"
  done
}

@test "sync --force: refuses to run from inside a workspace" {
  local proj="$SANDBOX/sync-force-inside-ws"
  clone_project "$proj"
  (cd "$proj" && orbit new "scope test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)

  # --force resets the shared pool, which the calling workspace does not own —
  # same shape as --branch, so it carries the same scope requirement.
  # Parked-ancestor topology: keep the trailing exit (see above).
  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo --force; rc=\$?; exit \$rc"
  [ "$status" -ne 0 ]
  assert_contains "$output" "sync --force should not be initiated from inside workspace dev"
}

@test "sync --force: blind ancestry withholds the cd replay and states the fact alone" {
  [ ! -d "/proc/$$" ] || skip "/proc present: ancestry is readable on this host"

  local proj="$SANDBOX/sync-force-blind-no-replay"
  clone_project "$proj"
  (cd "$proj" && orbit new "replay" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)

  local stubs="$SANDBOX/no-ancestry-bin-sync"
  mkdir -p "$stubs"
  printf '#!/bin/sh\nexit 1\n' > "$stubs/ps"
  printf '#!/bin/sh\nexit 1\n' > "$stubs/lsof"
  chmod +x "$stubs/ps" "$stubs/lsof"

  # cwd misplaced AND ancestry blind: shared guard withholds the replay so a
  # blind guard never hands back a ready-to-run destructive command.
  run bash -c "cd '$proj/dev' && PATH='$stubs':\$PATH ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo --force 2>&1"
  [ "$status" -ne 0 ]
  assert_contains "$output" "sync --force must be run from the project root"
  [[ "$output" != *"&&"* ]]
  [[ "$output" != *"cd $proj"* ]]
}

@test "sync --force: replays the intended command when the session is clean" {
  # cwd misplaced but ancestry readable and clean (cd-then-exec) — mirror of the
  # prune replay test; see tests/09_prune.bats for the topology rationale.
  { [ -d "/proc/$$" ] || command -v lsof >/dev/null 2>&1; } || skip "no ancestry facility to prove a clean session"

  local proj="$SANDBOX/sync-force-cd-replay"
  clone_project "$proj"
  (cd "$proj" && orbit new "replay" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)

  run bash -c "cd '$proj' && (cd '$proj/dev' && ORBIT_ROOT='$proj' exec bash '$ORBIT_CMD' sync myrepo --force) 2>&1"
  [ "$status" -ne 0 ]
  assert_contains "$output" "sync --force must be run from the project root — cd $proj && orbit sync myrepo --force"
}

@test "sync --force --branch: names both flags when both are given" {
  local proj="$SANDBOX/sync-both-flags"
  clone_project "$proj"
  (cd "$proj" && orbit new "scope test" --name dev >/dev/null 2>&1)

  # Parked-ancestor topology: keep the trailing exit (see above).
  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo --force --branch feature; rc=\$?; exit \$rc"
  [ "$status" -ne 0 ]
  assert_contains "$output" "sync --force/--branch should not be initiated from inside workspace dev"
}

@test "sync --force: still works from the project root" {
  local proj="$SANDBOX/sync-force-at-root"
  local remote="$REMOTES/sync-force-at-root.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo --force"
  [ "$status" -eq 0 ]
  assert_contains "$output" "myrepo: reset to origin/"
}

@test "sync: fetches named branches only — untracked remote branches never materialize" {
  local proj="$SANDBOX/sync-named-only"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "named only" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  # the remote has feature-x/feature-y; nothing local tracks them. orbit's
  # touchpoints must not pull them in — the whole-map pull is reserved for
  # the user's own bare fetch/pull.
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo 2>&1"
  [ "$status" -eq 0 ]
  run git -C "$proj/.repos/myrepo" branch -r
  assert_contains "$output" "origin/main"
  refute_contains "$output" "origin/feature-x"
  refute_contains "$output" "origin/feature-y"
}
