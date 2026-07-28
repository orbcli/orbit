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

# --- context command ---

@test "context: outputs workspace name and goal" {
  local proj="$SANDBOX/context-test"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "implement feature X" --name ws1 >/dev/null 2>&1

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context"
  [ "$status" -eq 0 ]
  assert_contains "$output" "ws1"
  assert_contains "$output" "implement feature X"
}

@test "context --reignite: shows memo content; bare context does not" {
  local proj="$SANDBOX/context-test2"
  clone_project "$proj"
  printf '# myrepo\n\nThis is the memo for context test.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1
  cd "$proj" && orbit new "context test" --name ws1 >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context --reignite"
  [ "$status" -eq 0 ]
  assert_contains "$output" "This is the memo for context test."

  # bare context is the cruise block: durables + conditional per-repo status, no memos
  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context"
  [ "$status" -eq 0 ]
  assert_contains "$output" "state: active"
  [[ "$output" != *"This is the memo for context test."* ]]
}

@test "context --json: bare form mirrors the cruise block (no memos)" {
  local proj="$SANDBOX/context-test3"
  clone_project "$proj"
  printf '# myrepo\n\nJSON context memo.\n\n## When to add (roles)\n- role one\n\n## How to use\n- src/main — entry\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1
  cd "$proj" && orbit new "json context goal" --name ws1 >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1

  # memo is fine and no jots → repo not listed (conditional output)
  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context --json"
  [ "$status" -eq 0 ]
  assert_contains "$output" '"workspace"'
  assert_contains "$output" '"goal"'
  assert_contains "$output" '"state"'
  assert_contains "$output" '"mode":"cruise"'
  assert_contains "$output" '"worktrees":[]'

  # --reignite --json carries the full worktrees array including memo
  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context --reignite --json"
  [ "$status" -eq 0 ]
  assert_contains "$output" '"worktrees"'
  assert_contains "$output" '"memoState":"ok"'
  assert_contains "$output" "JSON context memo."
}

@test "context <key>: returns single value for path" {
  local proj="$SANDBOX/context-key1"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "key test" --name ws1 >/dev/null 2>&1

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context path"
  [ "$status" -eq 0 ]
  [ "$output" = "$proj/ws1" ]
}

@test "context <key>: returns workspace name" {
  local proj="$SANDBOX/context-key2"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "key test" --name myws >/dev/null 2>&1

  run bash -c "cd '$proj/myws' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "myws" ]
}

@test "context <key>: returns goal" {
  local proj="$SANDBOX/context-key3"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "the goal text" --name ws1 >/dev/null 2>&1

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context goal"
  [ "$status" -eq 0 ]
  [ "$output" = "the goal text" ]
}

@test "context <key>: unknown key fails" {
  local proj="$SANDBOX/context-key4"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "test" --name ws1 >/dev/null 2>&1

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context badkey"
  [ "$status" -ne 0 ]
  assert_contains "$output" "unknown key"
}

@test "context: auto-recreates missing .orbit file" {
  local proj="$SANDBOX/context-rebuild"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "rebuild test" --name ws1 >/dev/null 2>&1

  rm -f "$proj/ws1/.orbit"
  [ ! -f "$proj/ws1/.orbit" ]

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context path"
  [ "$status" -eq 0 ]
  [ "$output" = "$proj/ws1" ]

  [ -f "$proj/ws1/.orbit" ]
}

@test "context: fails when run from project root" {
  local proj="$SANDBOX/context-test4"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context"
  [ "$status" -ne 0 ]
  assert_contains "$output" "cannot infer workspace from project root"
}

# --- cruise block: conditional per-repo status ---

@test "context: bare form lists a thin-memo repo; done warns per repo" {
  local proj="$SANDBOX/context-status"
  clone_project "$proj"
  cd "$proj" && orbit new --name ws1 --no-goal >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1

  # No memo → memo thin shows up in the cruise block.
  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context"
  [ "$status" -eq 0 ]
  assert_contains "$output" "repo myrepo: memo thin"

  # The done gate surfaces the same state per repo (advisory, still completes).
  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' done 2>&1"
  assert_contains "$output" "myrepo: memo thin, no capture this session — explore + write"
}

@test "context <key>: status key is retired (unknown key)" {
  local proj="$SANDBOX/context-retired"
  clone_project "$proj"
  cd "$proj" && orbit new --name ws1 --no-goal >/dev/null 2>&1

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context status"
  [ "$status" -ne 0 ]
  assert_contains "$output" "unknown key"

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context state"
  [ "$status" -eq 0 ]
  [ "$output" = "active" ]
}

# --- --startup routing: prime vs reignite ---

@test "context --startup: prime shows the pool roster on an empty workspace" {
  local proj="$SANDBOX/context-prime"
  clone_project "$proj"
  cd "$proj" && orbit new "prime test" --name ws1 >/dev/null 2>&1

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context --startup"
  [ "$status" -eq 0 ]
  assert_contains "$output" "state: active"
  assert_contains "$output" "available in pool"
  assert_contains "$output" "myrepo"
  # roster briefs follow the orbit repos fallback: no memo → README extract;
  # the memo-missing steering is inlined as a stdout section (hook injection
  # carries only stdout), not the repos-style stderr note
  assert_contains "$output" "A mock repository for testing."
  # fallback briefs are uncurated: the roster appends the remote URL as the
  # authoritative identity hint
  assert_contains "$output" "A mock repository for testing. ("
  assert_contains "$output" "no memo (write the card via orbit memo <repo>"
  [[ "$output" != *"has no memo, using README instead"* ]]
  # no stale header from the old format
  [[ "$output" != *"=== PRIME"* ]]
  [[ "$output" != *"primed"* ]]
}

@test "context --startup: reignite shows memos + per-repo status when populated" {
  local proj="$SANDBOX/context-reignite"
  clone_project "$proj"
  cd "$proj" && orbit new --name ws1 --no-goal >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1
  orbit jot myrepo "residual finding" 2>/dev/null

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context --startup"
  [ "$status" -eq 0 ]
  assert_contains "$output" "myrepo (branch:"
  assert_contains "$output" "status: 1 jots | memo thin"
  assert_contains "$output" "residual finding"
  # roster is prime-only
  [[ "$output" != *"available in pool"* ]]
}

@test "context: --startup and --prime are mutually exclusive" {
  local proj="$SANDBOX/context-mutex"
  clone_project "$proj"
  cd "$proj" && orbit new --name ws1 --no-goal >/dev/null 2>&1

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context --startup --prime"
  [ "$status" -ne 0 ]
  assert_contains "$output" "mutually exclusive"

  run bash -c "cd '$proj/ws1' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context goal --startup"
  [ "$status" -ne 0 ]
  assert_contains "$output" "cannot be combined"
}

@test "context --startup: registers refspec and materializes tracking ref after push" {
  local proj="$SANDBOX/context-refspec"
  local remote="$REMOTES/context-refspec.git"
  clone_remote "$remote"
  clone_project "$proj"
  git -C "$proj/.repos/myrepo" remote set-url origin "$remote" >/dev/null 2>&1
  cd "$proj" && orbit new --name ws1 --no-goal >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1

  cd "$proj/ws1/myrepo" && orbit switch -c feat-x >/dev/null 2>&1
  echo x > x.txt
  git add x.txt >/dev/null 2>&1
  git commit -m "x" >/dev/null 2>&1
  git push >/dev/null 2>&1

  # no refspec was registered at switch -c, so the push alone didn't materialize
  run git rev-parse --verify --quiet origin/feat-x
  [ "$status" -ne 0 ]

  # the startup block reconciles refspecs and fetches: the scoped branch's
  # tracking ref materializes at the first session start after the push
  run bash -c "cd '$proj/ws1/myrepo' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context --startup"
  [ "$status" -eq 0 ]
  assert_contains "$output" "orbit: myrepo: added fetch refspec: feat-x"
  git -C "$proj/.repos/myrepo" config --get-all remote.origin.fetch \
    | grep -Fqx "+refs/heads/feat-x:refs/remotes/origin/feat-x"
  git rev-parse --verify --quiet origin/feat-x >/dev/null
}
