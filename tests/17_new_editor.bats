#!/usr/bin/env bats

setup() {
  load test_helper/common
  common_setup
}

teardown() {
  common_teardown
}

# --- editor goal input ---

@test "new: opens editor when no goal provided" {
  local proj="$SANDBOX/editor-test"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  local mock="$SANDBOX/mock-editor.sh"
  printf '#!/bin/sh\nprintf "goal from editor\\n" > "$1"\n' > "$mock"
  chmod +x "$mock"

  cd "$proj" && ORBIT_EDITOR="$mock" orbit new --name from-editor >/dev/null 2>&1
  local goal
  goal=$(git config --file "$proj/from-editor/.orbit" --get workspace.goal)
  [ "$goal" = "goal from editor" ]
}

@test "new: editor strips comment lines" {
  local proj="$SANDBOX/editor-strip"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  local mock="$SANDBOX/mock-editor.sh"
  cat > "$mock" <<'SCRIPT'
#!/bin/sh
printf 'real goal\n# this is a comment\n# ignored\n' > "$1"
SCRIPT
  chmod +x "$mock"

  cd "$proj" && ORBIT_EDITOR="$mock" orbit new --name stripped >/dev/null 2>&1
  local goal
  goal=$(git config --file "$proj/stripped/.orbit" --get workspace.goal)
  [ "$goal" = "real goal" ]
}

@test "new: editor strips leading and trailing blank lines" {
  local proj="$SANDBOX/editor-trim"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  local mock="$SANDBOX/mock-editor.sh"
  printf '#!/bin/sh\nprintf "\\n\\ntrimmed goal\\n\\n\\n" > "$1"\n' > "$mock"
  chmod +x "$mock"

  cd "$proj" && ORBIT_EDITOR="$mock" orbit new --name trimmed >/dev/null 2>&1
  local goal
  goal=$(git config --file "$proj/trimmed/.orbit" --get workspace.goal)
  [ "$goal" = "trimmed goal" ]
}

@test "new: editor aborts on empty goal (only comments)" {
  local proj="$SANDBOX/editor-empty"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  # Editor that does nothing — leaves default comment template
  local mock="$SANDBOX/mock-editor.sh"
  printf '#!/bin/sh\ntrue\n' > "$mock"
  chmod +x "$mock"

  cd "$proj" && run bash -c 'ORBIT_EDITOR="'"$mock"'" ORBIT_ROOT="'"$proj"'" bash "'"$ORBIT_CMD"'" new --name empty-goal'
  [ "$status" -ne 0 ]
  assert_contains "$output" "aborting"
}

@test "new: editor preserves multi-line goal" {
  local proj="$SANDBOX/editor-multi"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  local mock="$SANDBOX/mock-editor.sh"
  cat > "$mock" <<'SCRIPT'
#!/bin/sh
printf 'line one\nline two\n' > "$1"
SCRIPT
  chmod +x "$mock"

  cd "$proj" && ORBIT_EDITOR="$mock" orbit new --name multiline >/dev/null 2>&1
  local goal
  goal=$(git config --file "$proj/multiline/.orbit" --get workspace.goal)
  printf '%s' "$goal" | grep -q "line one"
  printf '%s' "$goal" | grep -q "line two"
}

@test "new: ORBIT_EDITOR takes precedence over VISUAL and EDITOR" {
  local proj="$SANDBOX/editor-precedence"
  mkdir -p "$proj/.repos"
  touch "$proj/.repos/.orbit"
  TEST_PROJECT="$proj"

  local mock="$SANDBOX/mock-editor.sh"
  printf '#!/bin/sh\nprintf "orbit editor wins\\n" > "$1"\n' > "$mock"
  chmod +x "$mock"

  local bad="$SANDBOX/bad-editor.sh"
  printf '#!/bin/sh\nexit 1\n' > "$bad"
  chmod +x "$bad"

  cd "$proj" && ORBIT_EDITOR="$mock" VISUAL="$bad" EDITOR="$bad" orbit new --name prec >/dev/null 2>&1
  local goal
  goal=$(git config --file "$proj/prec/.orbit" --get workspace.goal)
  [ "$goal" = "orbit editor wins" ]
}
