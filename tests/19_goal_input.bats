#!/usr/bin/env bats

setup() {
  load test_helper/common
  common_setup
}

teardown() {
  common_teardown
}

# --- stdin ---

@test "goal: sets goal from stdin pipe" {
  local proj="$SANDBOX/goal-stdin"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && orbit new "initial goal" --name ws1 >/dev/null 2>&1

  cd "$proj/ws1" && echo "updated via pipe" | orbit goal >/dev/null 2>&1
  local goal
  goal=$(git config --file "$proj/ws1/.orbit" --get workspace.goal)
  [ "$goal" = "updated via pipe" ]
}

@test "goal: empty stdin pipe fails" {
  local proj="$SANDBOX/goal-stdin2"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && orbit new "my goal" --name ws2 >/dev/null 2>&1

  cd "$proj/ws2" && run bash -c 'echo "" | ORBIT_ROOT="'"$proj"'" bash "'"$ORBIT_CMD"'" goal'
  [ "$status" -ne 0 ]
  assert_contains "$output" "aborting"
}

@test "goal: set via argument still works" {
  local proj="$SANDBOX/goal-arg"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && orbit new "old goal" --name ws3 >/dev/null 2>&1

  cd "$proj/ws3" && orbit goal "new goal via arg" >/dev/null 2>&1
  local goal
  goal=$(git config --file "$proj/ws3/.orbit" --get workspace.goal)
  [ "$goal" = "new goal via arg" ]
}

# --- editor goal input ---

@test "goal: opens editor when no args in interactive mode" {
  local proj="$SANDBOX/goal-editor"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "initial" --name dev >/dev/null 2>&1

  local mock="$SANDBOX/mock-editor.sh"
  printf '#!/bin/sh\nprintf "goal from editor\\n" > "$1"\n' > "$mock"
  chmod +x "$mock"

  cd "$proj/dev" && ORBIT_EDITOR="$mock" orbit goal >/dev/null 2>&1
  local goal
  goal=$(git config --file "$proj/dev/.orbit" --get workspace.goal)
  [ "$goal" = "goal from editor" ]
}

@test "goal: editor pre-fills current goal" {
  local proj="$SANDBOX/goal-prefill"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "existing goal" --name dev >/dev/null 2>&1

  local mock="$SANDBOX/mock-editor.sh"
  cat > "$mock" <<'SCRIPT'
#!/bin/sh
grep -q "existing goal" "$1" && printf 'updated goal\n' > "$1"
SCRIPT
  chmod +x "$mock"

  cd "$proj/dev" && ORBIT_EDITOR="$mock" orbit goal >/dev/null 2>&1
  local goal
  goal=$(git config --file "$proj/dev/.orbit" --get workspace.goal)
  [ "$goal" = "updated goal" ]
}

@test "goal: editor keeps current goal when result is empty" {
  local proj="$SANDBOX/goal-keep"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "keep me" --name dev >/dev/null 2>&1

  local mock="$SANDBOX/mock-editor.sh"
  printf '#!/bin/sh\nprintf "# just a comment\\n" > "$1"\n' > "$mock"
  chmod +x "$mock"

  cd "$proj/dev" && ORBIT_EDITOR="$mock" orbit goal >/dev/null 2>&1
  local goal
  goal=$(git config --file "$proj/dev/.orbit" --get workspace.goal)
  [ "$goal" = "keep me" ]
}

@test "goal: editor aborts on empty when no existing goal" {
  local proj="$SANDBOX/goal-abort"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  mkdir -p "$proj/manual-ws"
  git config --file "$proj/manual-ws/.orbit" workspace.created "$(date +%s)"

  local mock="$SANDBOX/mock-editor.sh"
  printf '#!/bin/sh\ntrue\n' > "$mock"
  chmod +x "$mock"

  cd "$proj/manual-ws" && run bash -c 'ORBIT_EDITOR="'"$mock"'" ORBIT_ROOT="'"$proj"'" bash "'"$ORBIT_CMD"'" goal'
  [ "$status" -ne 0 ]
  assert_contains "$output" "aborting"
}

# --- slogans ---

@test "goal: prints slogan when setting goal via argument" {
  local proj="$SANDBOX/goal-slogan"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "initial" --name dev >/dev/null 2>&1

  cd "$proj/dev" && run orbit goal "new objective"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "Target locked\.|Course corrected\.|New heading confirmed\.|Objective updated\.|Coordinates set\.|Recalibrating\.\.\."
}

@test "goal: prints clear slogan on --clear" {
  local proj="$SANDBOX/goal-clear-slogan"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "initial" --name dev >/dev/null 2>&1

  cd "$proj/dev" && run orbit goal --clear
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "Target disengaged\.|Drifting free\.|Off the grid\.|Signal lost\. Standing by\."
}

# --- no-goal ---

@test "new: --no-goal creates workspace without goal" {
  local proj="$SANDBOX/no-goal-test"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && run orbit new --no-goal --name explore
  [ "$status" -eq 0 ]
  [ -d "$proj/explore" ]
  # goal should be empty/unset
  local goal
  goal=$(git config --file "$proj/explore/.orbit" --get workspace.goal 2>/dev/null || true)
  [ -z "$goal" ]
}
