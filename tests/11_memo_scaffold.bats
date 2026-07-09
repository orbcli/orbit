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

# --- memo --scaffold command (stdout-only, no file write) ---

@test "memo --scaffold: outputs scaffold to stdout without writing .md file" {
  local proj="$SANDBOX/memo-scaffold-test"
  clone_project "$proj"

  local output
  output=$(cd "$proj" && orbit memo myrepo --scaffold 2>/dev/null)
  assert_contains "$output" "# myrepo"
  [ ! -f "$proj/.repos/.myrepo.md" ]
}

@test "memo --scaffold: includes template sections in stdout" {
  local proj="$SANDBOX/memo-scaffold-test2"
  clone_project "$proj"

  local output
  output=$(cd "$proj" && orbit memo myrepo --scaffold 2>/dev/null)
  assert_contains "$output" "When to add (roles)"
  assert_contains "$output" "How to use"
  [ ! -f "$proj/.repos/.myrepo.md" ]
}

@test "memo --scaffold: still outputs when memo already exists" {
  local proj="$SANDBOX/memo-scaffold-test3"
  clone_project "$proj"
  printf '# myrepo\n\nOriginal memo content.\n' > "$proj/.repos/.myrepo.md"

  local output
  output=$(cd "$proj" && orbit memo myrepo --scaffold 2>/dev/null)
  assert_contains "$output" "# myrepo"
  local content
  content=$(cat "$proj/.repos/.myrepo.md")
  assert_contains "$content" "Original memo content."
}

@test "memo --scaffold: does not update index" {
  local proj="$SANDBOX/memo-scaffold-test4"
  clone_project "$proj"
  local brief_before
  brief_before=$(git config --file "$proj/.repos/.orbit" --get repos.myrepo.brief 2>/dev/null || true)

  cd "$proj" && orbit memo myrepo --scaffold >/dev/null 2>&1
  local brief_after
  brief_after=$(git config --file "$proj/.repos/.orbit" --get repos.myrepo.brief 2>/dev/null || true)
  [ "$brief_before" = "$brief_after" ]
}
