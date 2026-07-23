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

@test "brief: skips HTML block elements and their plain-text contents" {
  local proj="$SANDBOX/brief-test5"
  clone_project "$proj"

  printf '# Repo\n\n<p align="center">\n  <em>\n    JavaScript\n  </em>\n</p>\n\nReal content here.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' repos --json"
  assert_contains "$output" "Real content here."
}

@test "brief: skips multi-line HTML tags" {
  local proj="$SANDBOX/brief-test6"
  clone_project "$proj"

  printf '<div align="center">\n  <img alt="logo"\n       src="http://x/y.svg"\n       width="50%%">\n</div>\n\nCompiler repo.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' repos --json"
  assert_contains "$output" "Compiler repo."
}

@test "brief: skips code fences and nav link lines" {
  local proj="$SANDBOX/brief-test7"
  clone_project "$proj"

  printf '# Repo\n\n```sh\nnpm install x\n```\n\n[Docs](http://x) | [Website](http://y)\n\nOpinionated formatter.\n' | (cd "$proj" && orbit memo myrepo) >/dev/null 2>&1

  run bash -c "cd '$proj' && ORBIT_ROOT='$proj' bash '$ORBIT_CMD' repos --json"
  assert_contains "$output" "Opinionated formatter."
}
