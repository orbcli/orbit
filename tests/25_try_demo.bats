#!/usr/bin/env bats
#
# Install-wiring tests for try.sh (piped mode). Everything
# network- or install-shaped is faked: a mock curl serves a fake install.sh,
# a mock orbit no-ops the pool/workspace commands, and the fake install.sh
# records the ORBIT_SOURCE it was handed. No real network request is made.
#
# The source chain itself lives in install.sh and is tested in
# 23_install_cli.bats; try.sh only fetches install.sh once and passes the
# user's ORBIT_SOURCE through untouched — that is what these tests pin down.

setup() {
  load test_helper/common
  common_setup
  FAKE_HOME="$SANDBOX/home"
  MOCK_BIN="$SANDBOX/mockbin"
  TRY_DIR="$SANDBOX/try"
  MOCK_STATE="$SANDBOX/mockstate"
  FAKE_INSTALL="$SANDBOX/fake-install.sh"
  mkdir -p "$FAKE_HOME" "$MOCK_BIN" "$MOCK_STATE"

  # Copy try.sh OUT of the checkout: with no install.sh next to it, the
  # script takes the piped path (fetch install.sh, run it).
  cp "${BATS_TEST_DIRNAME}/../try.sh" "$SANDBOX/try.sh"

  # Fake install.sh: record what it was handed; fail when INSTALL_FAILS=1.
  cat > "$FAKE_INSTALL" <<'EOF'
#!/usr/bin/env bash
echo "ORBIT_SOURCE=${ORBIT_SOURCE:-<unset>}" >> "$MOCK_STATE/calls"
echo "ORBIT_SOURCES=${ORBIT_SOURCES:-<unset>}" >> "$MOCK_STATE/calls"
if [ "$INSTALL_FAILS" = "1" ]; then
  echo "simulated install failure (fake)" >&2
  exit 1
fi
exit 0
EOF

  cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl: count calls; fail while count <= CURL_FAILS; else serve the fake
# install.sh to `-o <file>`.
n=$(( $(cat "$MOCK_STATE/curl-count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$MOCK_STATE/curl-count"
echo "curl call $n" >> "$MOCK_STATE/calls"
if [ "$n" -le "${CURL_FAILS:-0}" ]; then
  echo "curl: (6) Could not resolve host (fake)" >&2
  exit 6
fi
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
cp "$FAKE_INSTALL" "$out"
EOF

  # Fake orbit runtime: clone/new/done all no-op.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/orbit"
  chmod +x "$MOCK_BIN/curl" "$MOCK_BIN/orbit" "$FAKE_INSTALL"
}

teardown() {
  common_teardown
}

run_try() {
  run env HOME="$FAKE_HOME" PATH="$MOCK_BIN:/usr/bin:/bin" \
    ORBIT_TRY_DIR="$TRY_DIR" MOCK_STATE="$MOCK_STATE" FAKE_INSTALL="$FAKE_INSTALL" \
    ORBIT_RETRY_DELAY_SECONDS=0 "$@" bash "$SANDBOX/try.sh" --opencode
}

@test "try.sh: install.sh is fetched once and run with the default source chain" {
  run_try CURL_FAILS=0 INSTALL_FAILS=0
  [ "$status" -eq 0 ]
  # One curl fetch, one install run. try.sh supplies the demo chain via
  # ORBIT_SOURCES but never invents a pinned ORBIT_SOURCE.
  [ "$(grep -c 'curl call' "$MOCK_STATE/calls")" -eq 1 ]
  assert_contains "$(grep 'ORBIT_SOURCE=' "$MOCK_STATE/calls")" "<unset>"
  [ "$(grep 'ORBIT_SOURCES=' "$MOCK_STATE/calls")" = \
    "ORBIT_SOURCES=orbcli/orbit https://github.com/orbcli/orbit.git git@github.com:orbcli/orbit.git" ]
  assert_contains "$output" "plugin installed."
  assert_contains "$output" "✓ Ready."
}

@test "try.sh: a user-set ORBIT_SOURCE passes through untouched (no chain added)" {
  run_try CURL_FAILS=0 INSTALL_FAILS=0 ORBIT_SOURCE="https://pinned.example/orbit.git"
  [ "$status" -eq 0 ]
  [ "$(grep 'ORBIT_SOURCE=' "$MOCK_STATE/calls")" = "ORBIT_SOURCE=https://pinned.example/orbit.git" ]
  assert_contains "$(grep 'ORBIT_SOURCES=' "$MOCK_STATE/calls")" "<unset>"
  assert_contains "$output" "plugin installed."
}

@test "try.sh: a user-set ORBIT_SOURCES passes through untouched" {
  run_try CURL_FAILS=0 INSTALL_FAILS=0 ORBIT_SOURCES="custom/chain only-one"
  [ "$status" -eq 0 ]
  [ "$(grep 'ORBIT_SOURCES=' "$MOCK_STATE/calls")" = "ORBIT_SOURCES=custom/chain only-one" ]
  assert_contains "$output" "plugin installed."
}

@test "try.sh: the install.sh fetch retries through a transient failure" {
  run_try CURL_FAILS=1 INSTALL_FAILS=0
  [ "$status" -eq 0 ]
  [ "$(grep -c 'curl call' "$MOCK_STATE/calls")" -eq 2 ]   # one retry, still one fetch
  assert_contains "$output" "plugin installed."
}

@test "try.sh: a failing install shows its real error, never fails silently" {
  run_try CURL_FAILS=0 INSTALL_FAILS=1
  [ "$status" -eq 0 ]   # plugin step degrades to manual launch instructions
  assert_contains "$output" "simulated install failure (fake)"
  assert_contains "$output" "falling back to manual launch instructions"
}

@test "try.sh: a non-numeric ORBIT_RETRY is rejected before any network use" {
  run_try ORBIT_RETRY=abc
  [ "$status" -eq 1 ]
  assert_contains "$output" "ORBIT_RETRY must be a positive integer"
  [ ! -e "$TRY_DIR/upstream" ]   # died in preflight, before any seeding/fetch
}
