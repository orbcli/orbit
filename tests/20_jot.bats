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

# Helper: create a project with one repo cloned and added to a workspace.
# `orbit add` seeds a [seed] jot for the memo-less mock repo; these tests exercise
# jot push/pop mechanics in isolation, so clear that seed for a clean slate.
setup_workspace_with_repo() {
  local proj="$1"
  clone_project "$proj"
  cd "$proj" && orbit new --name ws1 --no-goal >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1
  git config --file "$proj/ws1/.orbit" --unset-all jot.myrepo 2>/dev/null || true
}

# --- push mode ---

@test "jot: push with explicit repo and text" {
  local proj="$SANDBOX/jot-push1"
  setup_workspace_with_repo "$proj"
  cd "$proj/ws1"
  orbit jot myrepo "entry point is cmd/main.go" 2>/dev/null
  local entries
  entries=$(git config --file "$proj/ws1/.orbit" --get-all jot.myrepo 2>/dev/null)
  assert_contains "$entries" "entry point is cmd/main.go"
}

@test "jot: push with repo inferred from CWD" {
  local proj="$SANDBOX/jot-push2"
  setup_workspace_with_repo "$proj"
  cd "$proj/ws1/myrepo"
  orbit jot "uses Echo router" 2>/dev/null
  local entries
  entries=$(git config --file "$proj/ws1/.orbit" --get-all jot.myrepo 2>/dev/null)
  assert_contains "$entries" "uses Echo router"
}

@test "jot: push from stdin" {
  local proj="$SANDBOX/jot-push3"
  setup_workspace_with_repo "$proj"
  cd "$proj/ws1"
  echo "stdin note" | orbit jot myrepo 2>/dev/null
  local entries
  entries=$(git config --file "$proj/ws1/.orbit" --get-all jot.myrepo 2>/dev/null)
  assert_contains "$entries" "stdin note"
}

@test "jot: multiple pushes accumulate" {
  local proj="$SANDBOX/jot-push4"
  setup_workspace_with_repo "$proj"
  cd "$proj/ws1"
  orbit jot myrepo "note one" 2>/dev/null
  orbit jot myrepo "note two" 2>/dev/null
  orbit jot myrepo "note three" 2>/dev/null
  local count
  count=$(git config --file "$proj/ws1/.orbit" --get-all jot.myrepo 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 3 ]
}

# --- pop mode ---

@test "jot: pop outputs all entries and clears them" {
  local proj="$SANDBOX/jot-pop1"
  setup_workspace_with_repo "$proj"
  cd "$proj/ws1"
  orbit jot myrepo "note A" 2>/dev/null
  orbit jot myrepo "note B" 2>/dev/null

  local output
  output=$(orbit jot myrepo --pop 2>/dev/null)
  assert_contains "$output" "note A"
  assert_contains "$output" "note B"

  local remaining
  remaining=$(git config --file "$proj/ws1/.orbit" --get-all jot.myrepo 2>/dev/null || true)
  [ -z "$remaining" ]
}

@test "jot: pop with no entries produces empty output, no error" {
  local proj="$SANDBOX/jot-pop2"
  setup_workspace_with_repo "$proj"
  cd "$proj/ws1"
  run orbit jot myrepo --pop
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "jot: pop only affects specified repo" {
  local proj="$SANDBOX/jot-pop3"
  setup_workspace_with_repo "$proj"
  cd "$proj" && orbit clone "$SHARED_REMOTE" --name frontend >/dev/null 2>&1
  cd "$proj/ws1" && orbit add frontend >/dev/null 2>&1

  orbit jot myrepo "myrepo note" 2>/dev/null
  orbit jot frontend "frontend note" 2>/dev/null

  orbit jot myrepo --pop >/dev/null 2>/dev/null

  local be
  be=$(git config --file "$proj/ws1/.orbit" --get-all jot.myrepo 2>/dev/null || true)
  [ -z "$be" ]
  local fe
  fe=$(git config --file "$proj/ws1/.orbit" --get-all jot.frontend 2>/dev/null)
  assert_contains "$fe" "frontend note"
}

# --- overflow warning ---

@test "jot: overflow warning on stderr when >10 entries" {
  local proj="$SANDBOX/jot-overflow"
  setup_workspace_with_repo "$proj"
  cd "$proj/ws1"
  for i in $(seq 1 10); do
    orbit jot myrepo "note $i" 2>/dev/null
  done
  local stderr_output
  stderr_output=$(orbit jot myrepo "note 11" 2>&1 >/dev/null)
  assert_contains "$stderr_output" "jot entries: run jot --pop"
}

# --- error cases ---

@test "jot: errors when not in a workspace" {
  local proj="$SANDBOX/jot-err1"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj"
  run orbit jot myrepo "test"
  [ "$status" -ne 0 ]
}

@test "jot: errors when repo not specified and not in worktree" {
  local proj="$SANDBOX/jot-err2"
  setup_workspace_with_repo "$proj"
  cd "$proj/ws1"
  run orbit jot "some text"
  [ "$status" -ne 0 ]
}

# --- seed jot (no/low memo) ---

@test "add: seeds a [seed] jot for a repo with no memo" {
  local proj="$SANDBOX/jot-seed1"
  clone_project "$proj"
  cd "$proj" && orbit new --name ws1 --no-goal >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1
  local entries
  entries=$(git config --file "$proj/ws1/.orbit" --get-all jot.myrepo 2>/dev/null)
  assert_contains "$entries" "[seed]"
}

@test "add: does not seed when the repo already has a memo" {
  local proj="$SANDBOX/jot-seed2"
  clone_project "$proj"
  # Write a memo above the thin threshold so add treats it as sufficient.
  { for i in $(seq 1 15); do printf 'line %s content here\n' "$i"; done; } | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1
  cd "$proj" && orbit new --name ws1 --no-goal >/dev/null 2>&1
  cd "$proj/ws1" && orbit add myrepo >/dev/null 2>&1
  local entries
  entries=$(git config --file "$proj/ws1/.orbit" --get-all jot.myrepo 2>/dev/null || true)
  [ -z "$entries" ]
}

# --- over-length seed (memo past the max+min curate buffer) ---

@test "memo: seeds a curate-down jot when the card is over budget" {
  local proj="$SANDBOX/jot-overlong1"
  setup_workspace_with_repo "$proj"
  git config --file "$proj/.repos/.orbit" memo.minLines 2
  git config --file "$proj/.repos/.orbit" memo.maxLines 3
  cd "$proj/ws1"
  # 7 non-blank lines > threshold (max 3 + min 2 = 5)
  printf '# myrepo\n\nBrief.\n- a\n- b\n- c\n- d\n' | orbit memo myrepo >/dev/null 2>&1
  local entries
  entries=$(git config --file "$proj/ws1/.orbit" --get-all jot.myrepo 2>/dev/null)
  assert_contains "$entries" "[seed]"
  assert_contains "$entries" "over budget"
}

@test "memo: over-budget throttle prevents a second seed" {
  local proj="$SANDBOX/jot-overlong2"
  setup_workspace_with_repo "$proj"
  git config --file "$proj/.repos/.orbit" memo.minLines 2
  git config --file "$proj/.repos/.orbit" memo.maxLines 3
  cd "$proj/ws1"
  printf '# myrepo\n\nBrief.\n- a\n- b\n- c\n- d\n' | orbit memo myrepo >/dev/null 2>&1
  printf '# myrepo\n\nBrief.\n- a\n- b\n- c\n- d\n- e\n' | orbit memo myrepo >/dev/null 2>&1
  local count
  count=$(git config --file "$proj/ws1/.orbit" --get-all jot.myrepo 2>/dev/null | grep -c "over budget")
  [ "$count" -eq 1 ]
}

@test "memo: dropping back under budget clears the over-length throttle" {
  local proj="$SANDBOX/jot-overlong3"
  setup_workspace_with_repo "$proj"
  git config --file "$proj/.repos/.orbit" memo.minLines 2
  git config --file "$proj/.repos/.orbit" memo.maxLines 3
  cd "$proj/ws1"
  printf '# myrepo\n\nBrief.\n- a\n- b\n- c\n- d\n' | orbit memo myrepo >/dev/null 2>&1
  printf '# myrepo\n\nBrief.\n' | orbit memo myrepo >/dev/null 2>&1
  run git config --file "$proj/ws1/.orbit" --get overlong.myrepo.seen
  [ "$status" -ne 0 ]
}

@test "memo: no over-budget seed when run from project root" {
  local proj="$SANDBOX/jot-overlong4"
  setup_workspace_with_repo "$proj"
  git config --file "$proj/.repos/.orbit" memo.minLines 2
  git config --file "$proj/.repos/.orbit" memo.maxLines 3
  cd "$proj"
  printf '# myrepo\n\nBrief.\n- a\n- b\n- c\n- d\n' | orbit memo myrepo >/dev/null 2>&1
  local entries
  entries=$(git config --file "$proj/ws1/.orbit" --get-all jot.myrepo 2>/dev/null || true)
  [ -z "$entries" ]
}
