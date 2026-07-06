#!/usr/bin/env bats

setup() {
  load test_helper/common
  common_setup
}

teardown() {
  common_teardown
}

# --- new command ---

@test "new: auto-numbers workspaces as task-01, task-02" {
  local proj="$SANDBOX/new-test"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && orbit new "first task" >/dev/null 2>&1
  assert_dir_exists "$proj/task-01"

  cd "$proj" && orbit new "second task" >/dev/null 2>&1
  assert_dir_exists "$proj/task-02"
}

@test "new: writes goal to workspace .orbit file" {
  local proj="$SANDBOX/new-test2"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && orbit new "first task" >/dev/null 2>&1
  local goal
  goal=$(git config --file "$proj/task-01/.orbit" --get workspace.goal)
  [ "$goal" = "first task" ]
}

@test "new: writes created timestamp to .orbit (numeric)" {
  local proj="$SANDBOX/new-test3"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && orbit new "first task" >/dev/null 2>&1
  local created
  created=$(git config --file "$proj/task-01/.orbit" --get workspace.created)
  [[ "$created" =~ ^[0-9]+$ ]]
}

@test "new: --name creates custom-named workspace directory" {
  local proj="$SANDBOX/new-test4"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && orbit new "named task" --name my-ws >/dev/null 2>&1
  assert_dir_exists "$proj/my-ws"
}

@test "new: duplicate --name fails" {
  local proj="$SANDBOX/new-test5"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  cd "$proj" && orbit new "first" --name my-ws >/dev/null 2>&1
  run bash -c "ORBIT_ROOT='$proj' bash '$ORBIT_CMD' new 'dup' --name my-ws"
  [ "$status" -ne 0 ]
}

@test "new: rejects .repos as workspace name" {
  local proj="$SANDBOX/new-test6"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  run bash -c "ORBIT_ROOT='$proj' bash '$ORBIT_CMD' new 'bad' --name .repos"
  [ "$status" -ne 0 ]
}

@test "new: rejects dotfile workspace names" {
  local proj="$SANDBOX/new-test7"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  run bash -c "ORBIT_ROOT='$proj' bash '$ORBIT_CMD' new 'bad' --name .hidden"
  [ "$status" -ne 0 ]
}

@test "new: reads goal from stdin" {
  local proj="$SANDBOX/new-test8"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  echo "piped goal" | (cd "$proj" && orbit new --name pipe-ws) >/dev/null 2>&1
  local goal
  goal=$(git config --file "$proj/pipe-ws/.orbit" --get workspace.goal)
  [ "$goal" = "piped goal" ]
}

# --- done command ---

@test "done: sets status=done in workspace .orbit" {
  local proj="$SANDBOX/done-test"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "done test" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1
  local status_val
  status_val=$(git config --file "$proj/dev/.orbit" --get workspace.status)
  [ "$status_val" = "done" ]
}

@test "done: writes done-at timestamp (numeric)" {
  local proj="$SANDBOX/done-test2"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "done test" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1
  local done_at
  done_at=$(git config --file "$proj/dev/.orbit" --get workspace.done-at)
  [[ "$done_at" =~ ^[0-9]+$ ]]
}

@test "done: writes done-date in ISO format" {
  local proj="$SANDBOX/done-test3"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "done test" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit done >/dev/null 2>&1
  local done_date
  done_date=$(git config --file "$proj/dev/.orbit" --get workspace.done-date)
  [[ "$done_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

@test "done: --pr writes PR URL to [pr] section" {
  local proj="$SANDBOX/done-test4"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "done test" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit done --pr "https://github.com/org/repo/pull/1" >/dev/null 2>&1
  local pr_url
  pr_url=$(git config --file "$proj/dev/.orbit" --get-all pr.url | head -1)
  [ "$pr_url" = "https://github.com/org/repo/pull/1" ]
}

@test "done: idempotent --pr appends to PR list" {
  local proj="$SANDBOX/done-test5"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "done test" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit done --pr "https://github.com/org/repo/pull/1" >/dev/null 2>&1
  cd "$proj/dev" && orbit done --pr "https://github.com/org/repo/pull/2" >/dev/null 2>&1
  local pr_count
  pr_count=$(git config --file "$proj/dev/.orbit" --get-all pr.url | wc -l | tr -d ' ')
  [ "$pr_count" = "2" ]
}

@test "done: fails when executed at project root" {
  local proj="$SANDBOX/done-test6"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' done"
  [ "$status" -ne 0 ]
}

# --- goal command ---

@test "goal: sets goal with positional argument" {
  local proj="$SANDBOX/goal-test"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "initial goal" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit goal "updated goal" >/dev/null 2>&1
  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context goal"
  [ "$status" -eq 0 ]
  [ "$output" = "updated goal" ]
}

@test "goal: --clear removes goal" {
  local proj="$SANDBOX/goal-test3"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "initial goal" --name dev >/dev/null 2>&1

  cd "$proj/dev" && orbit goal --clear >/dev/null 2>&1
  run bash -c "cd '$proj/dev' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' context goal"
  [ "$output" = "" ]
}

@test "goal: fails when not in a workspace" {
  local proj="$SANDBOX/goal-test4"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' goal"
  [ "$status" -ne 0 ]
}

# --- goal reactivation (done workspace) ---

@test "goal: setting a goal on a done workspace clears status, done-at, done-date" {
  local proj="$SANDBOX/goal-react1"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "old goal" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1

  cd "$proj/dev" && orbit goal "new goal" >/dev/null 2>&1

  run git config --file "$proj/dev/.orbit" --get workspace.status
  [ "$output" = "" ]
  run git config --file "$proj/dev/.orbit" --get workspace.done-at
  [ "$output" = "" ]
  run git config --file "$proj/dev/.orbit" --get workspace.done-date
  [ "$output" = "" ]
}

@test "goal: setting a goal on a done workspace clears pr.url history" {
  local proj="$SANDBOX/goal-react2"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "old goal" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit done --pr "https://github.com/org/repo/pull/1" >/dev/null 2>&1

  cd "$proj/dev" && orbit goal "new goal" >/dev/null 2>&1

  run git config --file "$proj/dev/.orbit" --get-all pr.url
  [ "$output" = "" ]
}

@test "goal: --clear does not reactivate a done workspace" {
  local proj="$SANDBOX/goal-react3"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"
  cd "$proj" && orbit new "old goal" --name dev >/dev/null 2>&1
  cd "$proj/dev" && orbit done >/dev/null 2>&1

  cd "$proj/dev" && orbit goal --clear >/dev/null 2>&1

  local status_val
  status_val=$(git config --file "$proj/dev/.orbit" --get workspace.status)
  [ "$status_val" = "done" ]
}
