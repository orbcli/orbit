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

# --- Readable sync output (human-facing output proposal) ---

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

# --- Stale fetch refspec cleanup ---

@test "sync: removes stale fetch refspec left by a remote-deleted branch" {
  local proj="$SANDBOX/sync-refspec"
  local remote="$REMOTES/sync-refspec.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  # Simulate residue: refspec + stale tracking ref for a branch the remote no
  # longer has (typical: branch auto-deleted on PR merge)
  git -C "$proj/.repos/myrepo" config --add remote.origin.fetch \
    "+refs/heads/gone:refs/remotes/origin/gone"
  git -C "$proj/.repos/myrepo" update-ref refs/remotes/origin/gone \
    "$(git -C "$proj/.repos/myrepo" rev-parse HEAD)"

  # the residue breaks every bare fetch (the bug being fixed)
  run git -C "$proj/.repos/myrepo" fetch origin
  [ "$status" -ne 0 ]

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo"
  [ "$status" -eq 0 ]
  assert_contains "$output" "myrepo: removed stale fetch refspec: gone"

  # only the live main refspec remains; the stale tracking ref is gone
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/main:refs/remotes/origin/main" ]
  run git -C "$proj/.repos/myrepo" rev-parse --verify --quiet refs/remotes/origin/gone
  [ "$status" -ne 0 ]

  # bare fetch works again
  run git -C "$proj/.repos/myrepo" fetch origin
  [ "$status" -eq 0 ]
}

@test "sync: leaves a user-configured wildcard fetch refspec untouched" {
  local proj="$SANDBOX/sync-wildcard"
  local remote="$REMOTES/sync-wildcard.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  # User converted the pool to full fetch (a wildcard entry orbit never
  # writes), plus a stale exact entry. Reconcile must remove the stale one
  # but leave the wildcard alone.
  git -C "$proj/.repos/myrepo" config --add remote.origin.fetch \
    "+refs/heads/*:refs/remotes/origin/*"
  git -C "$proj/.repos/myrepo" config --add remote.origin.fetch \
    "+refs/heads/gone:refs/remotes/origin/gone"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo"
  [ "$status" -eq 0 ]
  assert_contains "$output" "myrepo: removed stale fetch refspec: gone"

  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  assert_contains "$output" "+refs/heads/*:refs/remotes/origin/*"
  [[ "$output" != *"refs/heads/gone"* ]]
}

# --- Pool-wide scope: --branch is root-only ---

@test "sync --branch: refuses to run from inside a workspace" {
  local proj="$SANDBOX/sync-branch-inside-ws"
  clone_project "$proj"
  (cd "$proj" && orbit new "scope test" --name dev >/dev/null 2>&1)
  (cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1)

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo --branch feature"
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

@test "sync --branch: keeps fetch refspecs other branches registered" {
  local proj="$SANDBOX/sync-branch-refspecs"
  local remote="$REMOTES/sync-branch-refspecs.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  # A branch another workspace pushed and registered, plus a user wildcard.
  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_srs_XXXXXX")
  git clone "$remote" "$tmp" >/dev/null 2>&1
  (
    cd "$tmp"
    git checkout -q -b feat-b
    echo b > b.txt && git add b.txt
    git -c user.email=t@t -c user.name=t commit -q -m "feat b"
    git push -q origin feat-b
    git checkout -q -b dev main 2>/dev/null || git checkout -q -b dev
    echo d > d.txt && git add d.txt
    git -c user.email=t@t -c user.name=t commit -q -m "dev"
    git push -q origin dev
  )
  git -C "$proj/.repos/myrepo" config --add remote.origin.fetch \
    "+refs/heads/feat-b:refs/remotes/origin/feat-b"
  git -C "$proj/.repos/myrepo" config --add remote.origin.fetch \
    "+refs/heads/*:refs/remotes/origin/*"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo --branch dev"
  [ "$status" -eq 0 ]
  assert_contains "$output" "pool: switched myrepo to branch dev"

  # --unset-all used to wipe every entry here, breaking bare fetch in the
  # worktrees of whoever registered feat-b.
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  assert_contains "$output" "+refs/heads/feat-b:refs/remotes/origin/feat-b"
  assert_contains "$output" "+refs/heads/*:refs/remotes/origin/*"
  assert_contains "$output" "+refs/heads/dev:refs/remotes/origin/dev"

  run git -C "$proj/.repos/myrepo" fetch origin
  [ "$status" -eq 0 ]
}

@test "sync --branch: rolls back the refspec change when the fetch fails" {
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

  # The refspec set is exactly what it was before the failed switch — no
  # residue pointing at the missing branch, and the old branch still fetchable.
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "$before" ]
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
  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo --force"
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

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' sync myrepo --force --branch feature"
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
