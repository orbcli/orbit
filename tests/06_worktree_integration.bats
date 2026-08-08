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

# --- add command ---

@test "add: creates worktree directory in workspace" {
  local proj="$SANDBOX/add-test"
  clone_project "$proj"
  cd "$proj" && orbit new "add test" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  assert_dir_exists "$proj/dev/myrepo"
}

@test "add: creates .git file in worktree" {
  local proj="$SANDBOX/add-test2"
  clone_project "$proj"
  cd "$proj" && orbit new "add test" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  assert_file_exists "$proj/dev/myrepo/.git"
}

@test "add: creates ws/<workspace>/<default-branch> branch" {
  local proj="$SANDBOX/add-test3"
  clone_project "$proj"
  cd "$proj" && orbit new "add test" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  local branch
  branch=$(git -C "$proj/dev/myrepo" branch --show-current)
  [ "$branch" = "ws/dev/main" ]
}

@test "add: sets upstream tracking on worktree branch" {
  local proj="$SANDBOX/add-test4"
  clone_project "$proj"
  cd "$proj" && orbit new "add test" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  local upstream
  upstream=$(git -C "$proj/dev/myrepo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo "none")
  [ "$upstream" = "origin/main" ]
}

@test "add: ensures workspace .orbit file exists" {
  local proj="$SANDBOX/add-test5"
  clone_project "$proj"
  cd "$proj" && orbit new "add test" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  assert_file_exists "$proj/dev/.orbit"
}

@test "add: duplicate repo in same workspace fails" {
  local proj="$SANDBOX/add-test6"
  clone_project "$proj"
  cd "$proj" && orbit new "add test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' add myrepo"
  [ "$status" -ne 0 ]
}

@test "add: fails when executed at project root" {
  local proj="$SANDBOX/add-test7"
  clone_project "$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' add myrepo"
  [ "$status" -ne 0 ]
}

@test "add: non-existent repo in pool fails" {
  local proj="$SANDBOX/add-test8"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "add test" --name dev >/dev/null 2>&1

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' add nonexist"
  [ "$status" -ne 0 ]
}

# --- switch command ---

@test "switch: -c creates ws/<ws>/<name> branch from HEAD" {
  local proj="$SANDBOX/switch-test"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo" && orbit switch -c feat-new >/dev/null 2>&1
  local branch
  branch=$(git -C "$proj/dev/myrepo" branch --show-current)
  [ "$branch" = "ws/dev/feat-new" ]
}

@test "switch: -c sets upstream merge ref" {
  local proj="$SANDBOX/switch-test2"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo" && orbit switch -c feat-new >/dev/null 2>&1
  local merge_ref
  merge_ref=$(git -C "$proj/dev/myrepo" config --get "branch.ws/dev/feat-new.merge" 2>/dev/null || echo "")
  [ "$merge_ref" = "refs/heads/feat-new" ]
}

@test "switch: -c sets upstream remote to origin" {
  local proj="$SANDBOX/switch-test3"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo" && orbit switch -c feat-new >/dev/null 2>&1
  local remote_cfg
  remote_cfg=$(git -C "$proj/dev/myrepo" config --get "branch.ws/dev/feat-new.remote" 2>/dev/null || echo "")
  [ "$remote_cfg" = "origin" ]
}

@test "switch: ensures push.default=upstream on repo" {
  local proj="$SANDBOX/switch-test4"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo" && orbit switch -c feat-new >/dev/null 2>&1
  local push_default
  push_default=$(git -C "$proj/.repos/myrepo" config --get push.default)
  [ "$push_default" = "upstream" ]
}

@test "switch: writes no push config (touchpoint convergence owns push.default)" {
  local proj="$SANDBOX/switch-no-pushcfg"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  git -C "$proj/.repos/myrepo" config --unset push.default 2>/dev/null || true

  cd "$proj/dev/myrepo" && orbit switch -c feat-new >/dev/null 2>&1
  run git -C "$proj/.repos/myrepo" config --get push.default
  [ "$status" -ne 0 ]
}

@test "raw mode: explicit push creates the remote branch; bare push is native git's error" {
  local proj="$SANDBOX/raw-push"
  local remote="$REMOTES/raw-push.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  cd "$proj" && orbit new "raw push" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo"
  git checkout -b feature/raw >/dev/null 2>&1
  echo "raw" > raw.txt
  git add raw.txt >/dev/null 2>&1
  git commit -m "raw commit" >/dev/null 2>&1

  # no push.autoSetupRemote: a bare push on a branch with no upstream fails
  # with plain git's "no upstream branch" error — raw mode's contract
  run git push
  [ "$status" -ne 0 ]

  # the documented raw-mode path: explicit push needs no upstream config
  run git push origin feature/raw
  [ "$status" -eq 0 ]
  git ls-remote --heads "$remote" feature/raw | grep -q feature/raw

  # `-u` wires tracking for later bare pushes, exactly as in a native repo
  git push -u origin feature/raw >/dev/null 2>&1
  [ "$(git config --get branch.feature/raw.remote)" = "origin" ]
  [ "$(git config --get branch.feature/raw.merge)" = "refs/heads/feature/raw" ]
}

@test "switch: -c writes no per-branch fetch entry (the wildcard map covers it)" {
  local proj="$SANDBOX/switch-refspec"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo" && orbit switch -c feat-new >/dev/null 2>&1
  # The pool's fetch config is exactly the full wildcard — no per-branch
  # entries to go stale, and @{u} resolution covers feat-new the moment it
  # is pushed.
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/*:refs/remotes/origin/*" ]
  # upstream config is still wired up front
  [ "$(git config --get branch.ws/dev/feat-new.merge)" = "refs/heads/feat-new" ]
}

@test "scoped mode: push materializes the tracking ref under the wildcard map" {
  local proj="$SANDBOX/scoped-push"
  local remote="$REMOTES/scoped-push.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  cd "$proj" && orbit new "scoped push" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev/myrepo" && orbit switch -c feat-scoped >/dev/null 2>&1

  echo "s" > s.txt
  git add s.txt >/dev/null 2>&1
  git commit -m "scoped commit" >/dev/null 2>&1
  run git push
  [ "$status" -eq 0 ]

  # The push alone materializes the remote-tracking ref (the wildcard map
  # routes it) and @{u} resolves immediately — no touchpoint wait.
  git rev-parse --verify --quiet origin/feat-scoped >/dev/null
  local up
  up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')
  [ "$up" = "origin/feat-scoped" ]

  # A later sync keeps the config at exactly the wildcard — no per-branch
  # entry is ever registered.
  (cd "$proj" && orbit sync myrepo >/dev/null 2>&1)
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/*:refs/remotes/origin/*" ]
}

@test "switch: switches to existing remote branch with tracking" {
  local proj="$SANDBOX/switch-test5"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo" && orbit switch feature-x >/dev/null 2>&1
  local branch
  branch=$(git -C "$proj/dev/myrepo" branch --show-current)
  [ "$branch" = "ws/dev/feature-x" ]
}

@test "switch: sets merge ref when switching to remote branch" {
  local proj="$SANDBOX/switch-test6"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo" && orbit switch feature-x >/dev/null 2>&1
  local merge_ref
  merge_ref=$(git -C "$proj/dev/myrepo" config --get "branch.ws/dev/feature-x.merge" 2>/dev/null || echo "")
  [ "$merge_ref" = "refs/heads/feature-x" ]
}

@test "switch: re-switch after remote branch advanced checks out the new head" {
  local proj="$SANDBOX/switch-stale-ref"
  local remote="$REMOTES/switch-stale-ref.git"
  clone_remote "$remote" "$SHARED_REMOTE_WITH_BRANCH"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1

  cd "$proj" && orbit new "stale ref" --name ws1 >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1

  # first switch materializes origin/feature-x in the pool
  cd "$proj/ws1/myrepo" && orbit switch feature-x >/dev/null 2>&1
  local first_head
  first_head=$(git rev-parse HEAD)

  # rewrite the remote branch (rebase/force-push workflow)
  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_stale_XXXXXX")
  git clone "$remote" "$tmp" >/dev/null 2>&1
  (
    cd "$tmp"
    git checkout feature-x >/dev/null 2>&1
    git reset --hard origin/main >/dev/null 2>&1
    echo "rewritten" > rewritten.txt
    git add rewritten.txt
    git commit -m "rewritten history" >/dev/null 2>&1
    git push --force origin feature-x >/dev/null 2>&1
  )
  local new_head
  new_head=$(git -C "$tmp" rev-parse HEAD)
  rm -rf "$tmp"
  [ "$first_head" != "$new_head" ]

  # second workspace forces the ensure path with the stale ref present:
  # without the fix it checks out the abandoned first_head
  cd "$proj" && orbit new "stale ref 2" --name ws2 >/dev/null 2>&1
  cd "$proj/ws2" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/ws2/myrepo" && orbit switch feature-x >/dev/null 2>&1

  [ "$(git rev-parse HEAD)" = "$new_head" ]
  [ "$(git -C "$proj/.repos/myrepo" rev-parse refs/remotes/origin/feature-x)" = "$new_head" ]
}

@test "switch: non-existent remote branch fails and leaves the fetch config untouched" {
  local proj="$SANDBOX/switch-test7"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev/myrepo' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' switch nonexist-branch"
  [ "$status" -ne 0 ]

  # No per-branch entry is ever registered: the config stays exactly the
  # wildcard, and bare fetch keeps working.
  run git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch
  [ "$output" = "+refs/heads/*:refs/remotes/origin/*" ]
  run git -C "$proj/.repos/myrepo" fetch origin
  [ "$status" -eq 0 ]
}

@test "switch: -c with existing remote branch name succeeds (no remote check)" {
  local proj="$SANDBOX/switch-test8"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  # orbit switch -c no longer checks remote — creates from HEAD regardless.
  # stderr notes the conflict when remote already has the branch with different commits.
  run bash -c "cd '$proj/dev/myrepo' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' switch -c feature-x"
  [ "$status" -eq 0 ]
  assert_contains "$output" "created ws/dev/feature-x"
}

@test "switch: explicit repo argument from workspace root" {
  local proj="$SANDBOX/switch-test9"
  clone_project "$proj" "$SHARED_PROJECT_WITH_BRANCH"
  cd "$proj" && orbit new "switch test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  cd "$proj/dev/myrepo" && orbit switch -c feat-new >/dev/null 2>&1

  cd "$proj/dev" && orbit switch myrepo feat-new >/dev/null 2>&1 || true
  local branch
  branch=$(git -C "$proj/dev/myrepo" branch --show-current)
  [ "$branch" = "ws/dev/feat-new" ]
}

# --- status command ---

@test "status: shows workspace name from CWD" {
  local proj="$SANDBOX/status-test"
  clone_project "$proj"
  cd "$proj" && orbit new "status goal" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' status"
  assert_contains "$output" "dev"
}

@test "status: shows goal in output" {
  local proj="$SANDBOX/status-test2"
  clone_project "$proj"
  cd "$proj" && orbit new "status goal" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' status"
  assert_contains "$output" "status goal"
}

@test "status: shows repo name in output" {
  local proj="$SANDBOX/status-test3"
  clone_project "$proj"
  cd "$proj" && orbit new "status goal" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' status"
  assert_contains "$output" "myrepo"
}

@test "status: works with explicit workspace name from root" {
  local proj="$SANDBOX/status-test4"
  clone_project "$proj"
  cd "$proj" && orbit new "status goal" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' status dev"
  assert_contains "$output" "dev"
}

@test "status: shows branch info with explicit workspace" {
  local proj="$SANDBOX/status-test5"
  clone_project "$proj"
  cd "$proj" && orbit new "status goal" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' status dev"
  # scoped branch prints without the ws/<ws>/ prefix; clean repo folds to 'clean'
  assert_contains "$output" "myrepo"
  assert_contains "$output" "clean"
  [[ "$output" != *"ws/dev/main"* ]]
}

@test "status: raw mode branch gets the conversion steering line (parity with context/done)" {
  local proj="$SANDBOX/status-test6"
  clone_project "$proj"
  cd "$proj" && orbit new "status raw" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1
  git -C "$proj/dev/myrepo" checkout -b raw-branch >/dev/null 2>&1

  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' status"
  # stdout table keeps only the mark; the full steering goes to stderr
  assert_contains "$output" "raw-branch"
  assert_contains "$output" " raw"
  assert_contains "$output" "orbit: myrepo: raw mode branch — run: orbit switch -c raw-branch (convert to scoped)"
}

# --- CWD inference ---

@test "cwd-inference: goal works from worktree subdirectory" {
  local proj="$SANDBOX/cwd-test"
  clone_project "$proj"
  cd "$proj" && orbit new "cwd test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev/myrepo' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context goal"
  [ "$output" = "cwd test" ]
}

@test "cwd-inference: done works from worktree subdirectory" {
  local proj="$SANDBOX/cwd-test2"
  clone_project "$proj"
  cd "$proj" && orbit new "cwd test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/dev/myrepo" && orbit done >/dev/null 2>&1
  local st
  st=$(git config --file "$proj/dev/.orbit" --get workspace.status)
  [ "$st" = "done" ]
}

@test "cwd-inference: status works from worktree subdirectory" {
  local proj="$SANDBOX/cwd-test3"
  clone_project "$proj"
  cd "$proj" && orbit new "cwd test" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/dev/myrepo' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' status 2>/dev/null"
  assert_contains "$output" "dev"
}
