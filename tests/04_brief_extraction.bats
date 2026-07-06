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

@test "brief: skips title and empty lines" {
  local proj="$SANDBOX/brief-test"
  clone_project "$proj"

  printf '# Title\n\nActual brief content.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1
  local brief
  brief=$(git config --file "$proj/.repos/.orbit" --get repos.myrepo.brief)
  [ "$brief" = "Actual brief content." ]
}

@test "brief: skips badge lines" {
  local proj="$SANDBOX/brief-test2"
  clone_project "$proj"

  printf '# Repo\n[![badge](url)](link)\n\nReal content.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1
  local brief
  brief=$(git config --file "$proj/.repos/.orbit" --get repos.myrepo.brief)
  [ "$brief" = "Real content." ]
}

@test "brief: strips blockquote prefix" {
  local proj="$SANDBOX/brief-test3"
  clone_project "$proj"

  printf '# Repo\n\n> Tagline from blockquote.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1
  local brief
  brief=$(git config --file "$proj/.repos/.orbit" --get repos.myrepo.brief)
  [ "$brief" = "Tagline from blockquote." ]
}

@test "brief: truncates long lines at word boundary within 120 characters" {
  local proj="$SANDBOX/brief-test4"
  clone_project "$proj"

  local long_line="This is a very long line that exceeds one hundred and twenty characters and should be truncated by the extraction logic at a word boundary here."
  printf '# Repo\n\n%s\n' "$long_line" | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1
  local brief
  brief=$(git config --file "$proj/.repos/.orbit" --get repos.myrepo.brief)
  [ "${#brief}" -le 120 ]
  [[ "$brief" != *" "* ]] || [[ "$brief" =~ [a-z]$ ]]
}
