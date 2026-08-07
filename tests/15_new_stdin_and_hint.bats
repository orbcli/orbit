#!/usr/bin/env bats

setup() {
  load test_helper/common
  common_setup
}

teardown() {
  common_teardown
}

# --- stdin goal ---

@test "new: reads goal from stdin pipe" {
  local proj="$SANDBOX/stdin-test"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && echo "piped goal" | orbit new --name from-pipe >/dev/null 2>&1
  local goal
  goal=$(git config --file "$proj/from-pipe/.orbit" --get workspace.goal)
  [ "$goal" = "piped goal" ]
}

@test "new: fails when no goal and stdin is terminal" {
  local proj="$SANDBOX/stdin-test2"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  # Simulate terminal stdin by not piping (but bats runs non-interactively, so
  # we pass no goal and no stdin pipe — the read will get empty input)
  cd "$proj" && run bash -c 'echo "" | ORBIT_ROOT="'"$proj"'" bash "'"$ORBIT_CMD"'" new --name no-goal'
  [ "$status" -ne 0 ]
}

# --- agent.recommend hint ---

@test "new: shows agent.recommend in hint when configured" {
  local proj="$SANDBOX/hint-test"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  orbit config agent.recommend 'claude "开始"' >/dev/null

  cd "$proj" && run orbit new "test goal" --name hinted
  [ "$status" -eq 0 ]
  assert_contains "$output" 'claude "开始"'
}

@test "new: shows only cd when no agent.recommend configured" {
  local proj="$SANDBOX/hint-test2"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && run orbit new "test goal" --name plain
  [ "$status" -eq 0 ]
  assert_contains "$output" "cd plain"
  ! printf '%s' "$output" | grep -q "claude"
}

# --- farewell message ---

@test "new: prints a farewell message" {
  local proj="$SANDBOX/happy-test"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && run orbit new "test goal"
  [ "$status" -eq 0 ]
  # one of the random farewell messages should appear
  echo "$output" | grep -qE "Godspeed\.|Ad astra\.|Go for orbit\.|Fly true\.|All systems nominal\.|Good hunting\."
}

# --- cd path from non-root ---

@test "new: shows absolute path when run from inside another workspace" {
  local proj="$SANDBOX/path-test"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  mkdir -p "$proj/existing-ws"
  TEST_PROJECT="$proj"

  cd "$proj/existing-ws" && run orbit new "another task" --name new-ws
  [ "$status" -eq 0 ]
  assert_contains "$output" "$proj/new-ws"
}

@test "new: rejects workspace names that violate git ref rules" {
  local proj="$SANDBOX/new-bad-names"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  local bad
  for bad in "foo bar" "dev*" "a?b" "x[y" 'x\y' "a..b" ".dot" "trail/" "a/b"; do
    run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' new 'goal' --name '$bad' 2>&1"
    [ "$status" -ne 0 ]
    assert_contains "$output" "invalid workspace name"
  done

  # sanity: normal names still pass validation (fail later only on dup/goal rules)
  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' new 'goal' --name ok-name_1.2 2>&1"
  [ "$status" -eq 0 ]
  [ -d "$proj/ok-name_1.2" ]
}
