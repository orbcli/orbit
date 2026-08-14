#!/usr/bin/env bats
#
# Assertion-form guard. On bash 3.2 (stock macOS /bin/bash, which the bats
# shebang resolves to), a failing bare `[[ … ]]` statement does NOT trip
# errexit — `[[ ]]`/`(( ))` only became subject to `set -e` in bash 4.1. Any
# mid-test bare `[[ ]]` assertion therefore passes silently on stock macOS,
# whatever it checks. Assertions must use the helpers in
# test_helper/common.bash (assert_contains / refute_contains / assert_matches)
# or plain `[ ]`, both of which fail through on every bash.
#
# This lint test greps the suite for the vacuous shape. The pattern is built
# at runtime so this file's own text never self-matches.

setup() {
  load test_helper/common
  common_setup
}

@test "lint: no bare [[ ]] assertions anywhere in tests/*.bats" {
  pat='^[[:space:]]*\[\['   # bare-statement form; if/||/&& contexts are fine
  run grep -rnE "$pat" "$BATS_TEST_DIRNAME"/*.bats
  # grep exits 1 when nothing matches; 0 means a violation was found.
  [ "$status" -eq 1 ]
}
