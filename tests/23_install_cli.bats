#!/usr/bin/env bats
#
# Lightweight argument-parsing / validation checks for install.sh.
# These deliberately avoid real end-to-end installs: they exercise only the
# paths that stop at parsing or validation, or that no-op when the target CLI
# is absent. Network and agent CLIs are exercised only through fakes staged
# on PATH (see mock_bin) — no real claude/codex/qodercli command is ever
# invoked, and no real network request is made.

setup() {
  load test_helper/common
  common_setup
  INSTALL="${BATS_TEST_DIRNAME}/../install.sh"
  # Isolated HOME so uninstall paths that touch ~/.config or ~/.local never
  # affect the real environment.
  FAKE_HOME="$SANDBOX/home"
  mkdir -p "$FAKE_HOME"
  MOCK_BIN="$SANDBOX/mockbin"
  MOCK_STATE="$SANDBOX/mockstate"
  mkdir -p "$MOCK_BIN" "$MOCK_STATE"
}

teardown() {
  common_teardown
}

# Run install.sh with an isolated HOME and a PATH that has no agent CLIs, so
# any plugin uninstall degrades to a "CLI not found — skipping" no-op.
run_install() {
  run env HOME="$FAKE_HOME" PATH="/usr/bin:/bin" bash "$INSTALL" "$@"
}

# Run install.sh with the mock bin dir first on PATH. Extra env is passed
# through by the caller (env VAR=... before bash).
run_install_mocked() {
  run env HOME="$FAKE_HOME" PATH="$MOCK_BIN:/usr/bin:/bin" MOCK_STATE="$MOCK_STATE" "$@"
}

# Fake curl: parses `-o <file>`; fails the first $CURL_FAILS invocations with
# a realistic connect error, then writes a minimal orbit.sh payload.
write_fake_curl() {
  cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
state="$MOCK_STATE/curl-count"
n=$(( $(cat "$state" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$state"
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
if [ "$n" -le "${CURL_FAILS:-0}" ]; then
  echo "curl: (6) Could not resolve host: raw.githubusercontent.com (fake)" >&2
  exit 6
fi
printf '#!/usr/bin/env bash\n# fake orbit.sh\n' > "$out"
EOF
  chmod +x "$MOCK_BIN/curl"
}

@test "help: --help exits 0 and prints usage" {
  run_install --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:"* ]]
}

@test "parse: unknown flag exits 1" {
  run_install --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option: --bogus"* ]]
}

@test "uninstall: no target is rejected" {
  run_install --uninstall
  [ "$status" -eq 1 ]
  [[ "$output" == *"--uninstall requires at least one target"* ]]
}

@test "uninstall: a single plugin target no-ops when its CLI is absent" {
  run_install --uninstall --claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude CLI not found"* ]]
}

@test "uninstall: --all runs every target and exits 0 when nothing is installed" {
  run_install --uninstall --all
  [ "$status" -eq 0 ]
  # --all expands to all plugin targets; missing CLIs are skipped, not fatal.
  [[ "$output" == *"codex CLI not found"* ]] || [[ "$output" == *"Removed"* ]]
  [[ "$output" == *"Done."* ]]
}

@test "uninstall: --cli reports nothing to remove when runtime is absent" {
  run_install --uninstall --cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to remove"* ]]
}

# --- network resilience (ORBIT_RETRY / ORBIT_RETRY_DELAY_SECONDS / ORBIT_TIMEOUT_SECONDS) ---

@test "env: non-numeric ORBIT_RETRY is rejected" {
  run env HOME="$FAKE_HOME" PATH="/usr/bin:/bin" ORBIT_RETRY=abc bash "$INSTALL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ORBIT_RETRY must be a positive integer"* ]]
}

@test "env: ORBIT_RETRY=0 is rejected" {
  run env HOME="$FAKE_HOME" PATH="/usr/bin:/bin" ORBIT_RETRY=0 bash "$INSTALL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ORBIT_RETRY must be >= 1"* ]]
}

@test "env: non-numeric ORBIT_TIMEOUT_SECONDS is rejected" {
  run env HOME="$FAKE_HOME" PATH="/usr/bin:/bin" ORBIT_TIMEOUT_SECONDS=soon bash "$INSTALL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ORBIT_TIMEOUT_SECONDS must be a positive integer"* ]]
}

@test "retry: a download that fails transiently succeeds within ORBIT_RETRY" {
  write_fake_curl   # fails the first 2 invocations, succeeds on the 3rd
  run_install_mocked CURL_FAILS=2 ORBIT_SOURCE=acme/widgets \
    ORBIT_RETRY=3 ORBIT_RETRY_DELAY_SECONDS=0 bash "$INSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"attempt 1/3 failed"* ]]
  [[ "$output" == *"Installed orbit command to:"* ]]
  [ -x "$FAKE_HOME/.local/bin/orbit" ]
}

@test "retry exhausted: the real network error is printed, never swallowed" {
  write_fake_curl   # CURL_FAILS high enough that every attempt fails
  run_install_mocked CURL_FAILS=99 ORBIT_SOURCE=acme/widgets \
    ORBIT_RETRY=2 ORBIT_RETRY_DELAY_SECONDS=0 bash "$INSTALL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"giving up after 2 attempts"* ]]
  [[ "$output" == *"Could not resolve host"* ]]                  # the real curl error
  [[ "$output" == *"failed to fetch orbit.sh"* ]]
  [[ "$output" == *"local path source needs no network"* ]]      # escape-hatch hint
}

@test "timeout: a hung download is killed at ORBIT_TIMEOUT_SECONDS, not waited out" {
  printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$MOCK_BIN/curl"
  chmod +x "$MOCK_BIN/curl"
  run_install_mocked ORBIT_SOURCE=acme/widgets \
    ORBIT_RETRY=2 ORBIT_RETRY_DELAY_SECONDS=0 ORBIT_TIMEOUT_SECONDS=1 bash "$INSTALL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"timed out (1s)"* ]]
  [[ "$output" == *"failed to fetch orbit.sh"* ]]
}

@test "timeout: a TERM-immune download is KILLed after the grace period" {
  # No `exec` here: a trap would be reset by it. Ignored TERM → 2s grace → KILL.
  cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep 30 & wait
EOF
  chmod +x "$MOCK_BIN/curl"
  run_install_mocked ORBIT_SOURCE=acme/widgets \
    ORBIT_RETRY=1 ORBIT_RETRY_DELAY_SECONDS=0 ORBIT_TIMEOUT_SECONDS=1 bash "$INSTALL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"timed out after 1s"* ]]   # giving-up message names the timeout
  [[ "$output" == *"failed to fetch orbit.sh"* ]]
}

# --- marketplace error surfacing (fake claude on PATH) ---------------------

# Fake claude: marketplace add/update always fail with a realistic clone
# error; plugin install fails like a missing marketplace does, unless
# CLAUDE_INSTALL_OK=1 (an existing local snapshot installing fine offline).
write_fake_claude() {
  cat > "$MOCK_BIN/claude" <<'EOF'
#!/usr/bin/env bash
case "$1 $2 $3" in
  "plugin marketplace add")
    echo "fatal: unable to connect to github.com (fake)" >&2; exit 128 ;;
  "plugin marketplace update")
    echo "error: no such marketplace (fake)" >&2; exit 1 ;;
  "plugin uninstall"*)
    exit 0 ;;
  "plugin install"*)
    if [ "${CLAUDE_INSTALL_OK:-0}" = "1" ]; then
      touch "$MOCK_STATE/plugin-installed"; exit 0
    fi
    echo 'Error: plugin "claude-orbit" not found in marketplace "orbcli" (fake)' >&2; exit 1 ;;
esac
exit 0
EOF
  chmod +x "$MOCK_BIN/claude"
}

@test "marketplace: add/update failure surfaces both the add and install errors" {
  write_fake_claude
  run_install_mocked ORBIT_SOURCE="${BATS_TEST_DIRNAME}/.." \
    ORBIT_RETRY=2 ORBIT_RETRY_DELAY_SECONDS=0 bash "$INSTALL" --claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"unable to connect to github.com (fake)"* ]]   # the real add error
  [[ "$output" == *"marketplace add/update failed"* ]]            # the causal warning…
  [[ "$output" == *"cause is the add error"* ]]                   # …naming the root cause
  [[ "$output" == *"not found in marketplace"* ]]                 # the install error
}

@test "marketplace: refresh failure warns but does not block an offline install" {
  write_fake_claude
  run_install_mocked ORBIT_SOURCE="${BATS_TEST_DIRNAME}/.." \
    ORBIT_RETRY=2 ORBIT_RETRY_DELAY_SECONDS=0 CLAUDE_INSTALL_OK=1 bash "$INSTALL" --claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"cause is the add error"* ]]
  [[ "$output" == *"Installed Orbit plugin into Claude Code"* ]]
  [ -e "$MOCK_STATE/plugin-installed" ]
}

# --- source chain (ORBIT_SOURCES; single source never rotates) -------------
#
# These run a COPY of install.sh from the sandbox: with no orbit.sh next to
# it, no local checkout is detected — mirroring a piped install. Every
# network call is logged to $MOCK_STATE/calls by the fakes.
#
# The demo chain try.sh supplies, reused across these tests:
CHAIN="orbcli/orbit https://github.com/orbcli/orbit.git git@github.com:orbcli/orbit.git"

# Fake curl: log "curl <url>", fail while the counter is <= $CURL_FAILS.
write_fake_curl_logging() {
  cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
state="$MOCK_STATE/curl-count"
n=$(( $(cat "$state" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$state"
out=""; url=""; prev=""
for a in "$@"; do
  case "$a" in -*) prev="$a"; continue ;; esac
  if [ "$prev" = "-o" ]; then out="$a"; else url="$a"; fi
  prev="$a"
done
echo "curl $url" >> "$MOCK_STATE/calls"
if [ "$n" -le "${CURL_FAILS:-0}" ]; then
  echo "curl: (6) Could not resolve host (fake)" >&2
  exit 6
fi
printf '#!/usr/bin/env bash\n# fake orbit.sh\n' > "$out"
EOF
  chmod +x "$MOCK_BIN/curl"
}

# Fake git: log "git-clone <url>"; succeed only when the url contains
# $GIT_OK_SUBSTR, materializing a minimal orbit.sh in the target dir. Also
# records the inherited GIT_TERMINAL_PROMPT so a test can pin it to 0.
write_fake_git() {
  cat > "$MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
echo "gtp=${GIT_TERMINAL_PROMPT:-unset}" >> "$MOCK_STATE/gtp"
url="${@: -2:1}"; dir="${@: -1}"
echo "git-clone $url" >> "$MOCK_STATE/calls"
case "$url" in
  *"$GIT_OK_SUBSTR"*)
    mkdir -p "$dir"
    printf '#!/usr/bin/env bash\n# fake orbit.sh\n' > "$dir/orbit.sh"
    exit 0 ;;
  *)
    echo "fatal: unable to connect (fake)" >&2
    exit 128 ;;
esac
EOF
  chmod +x "$MOCK_BIN/git"
}

# Run a checkout-free copy of install.sh with the demo chain supplied (as
# try.sh would). Extra env pairs pass through.
run_install_chained() {
  cp "$INSTALL" "$SANDBOX/install.sh"
  run_install_mocked ORBIT_SOURCES="$CHAIN" "$@" bash "$SANDBOX/install.sh"
}

@test "chain: a retry rotates from the shorthand to the HTTPS clone" {
  write_fake_curl_logging; write_fake_git
  run_install_chained CURL_FAILS=99 GIT_OK_SUBSTR="https://" \
    ORBIT_RETRY=3 ORBIT_RETRY_DELAY_SECONDS=0
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$MOCK_STATE/calls")" = "curl https://raw.githubusercontent.com/orbcli/orbit/main/orbit.sh" ]
  [ "$(sed -n '2p' "$MOCK_STATE/calls")" = "git-clone https://github.com/orbcli/orbit.git" ]
  [ "$(wc -l < "$MOCK_STATE/calls" | tr -d ' ')" -eq 2 ]   # SSH never needed
  [[ "$output" == *"attempt 1/3 via orbcli/orbit failed"* ]]
  [ -x "$FAKE_HOME/.local/bin/orbit" ]
  # The clone saw the no-prompt env (installer must never ask interactively):
  [ "$(sed -n '1p' "$MOCK_STATE/gtp")" = "gtp=0" ]
}

@test "chain: rotation walks https, ssh, then wraps back to the shorthand" {
  write_fake_curl_logging; write_fake_git
  # git always fails; curl fails its FIRST call only → attempt 4 wraps back to
  # the shorthand and that second curl call succeeds.
  run_install_chained CURL_FAILS=1 GIT_OK_SUBSTR="nothing-matches" \
    ORBIT_RETRY=4 ORBIT_RETRY_DELAY_SECONDS=0
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$MOCK_STATE/calls")" = "curl https://raw.githubusercontent.com/orbcli/orbit/main/orbit.sh" ]
  [ "$(sed -n '2p' "$MOCK_STATE/calls")" = "git-clone https://github.com/orbcli/orbit.git" ]
  [ "$(sed -n '3p' "$MOCK_STATE/calls")" = "git-clone git@github.com:orbcli/orbit.git" ]
  [ "$(sed -n '4p' "$MOCK_STATE/calls")" = "curl https://raw.githubusercontent.com/orbcli/orbit/main/orbit.sh" ]
}

@test "chain: a pinned ORBIT_SOURCE never rotates" {
  write_fake_curl_logging; write_fake_git
  run_install_mocked CURL_FAILS=2 ORBIT_SOURCE=acme/widgets \
    ORBIT_RETRY=3 ORBIT_RETRY_DELAY_SECONDS=0 bash "$INSTALL"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MOCK_STATE/calls" | tr -d ' ')" -eq 3 ]
  ! grep -q "git-clone" "$MOCK_STATE/calls"
  [ "$(sed -n '3p' "$MOCK_STATE/calls")" = "curl https://raw.githubusercontent.com/acme/widgets/main/orbit.sh" ]
}

@test "chain: the marketplace add rotates its source across retries" {
  write_fake_curl_logging   # resolve succeeds on the first (shorthand) attempt
  cat > "$MOCK_BIN/claude" <<'EOF'
#!/usr/bin/env bash
case "$1 $2 $3" in
  "plugin marketplace add")
    echo "mp-add $4" >> "$MOCK_STATE/calls"
    n=$(( $(cat "$MOCK_STATE/add-count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$MOCK_STATE/add-count"
    if [ "$n" -eq 1 ]; then echo "fatal: unable to connect (fake)" >&2; exit 128; fi
    exit 0 ;;
  "plugin marketplace update") exit 1 ;;
  "plugin install"*) exit 0 ;;
  "plugin uninstall"*) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$MOCK_BIN/claude"
  cp "$INSTALL" "$SANDBOX/install.sh"
  run env HOME="$FAKE_HOME" PATH="$MOCK_BIN:/usr/bin:/bin" MOCK_STATE="$MOCK_STATE" \
    ORBIT_SOURCES="$CHAIN" ORBIT_RETRY=3 ORBIT_RETRY_DELAY_SECONDS=0 bash "$SANDBOX/install.sh" --claude
  [ "$status" -eq 0 ]
  [ "$(grep -c 'mp-add' "$MOCK_STATE/calls")" -eq 2 ]
  [ "$(grep 'mp-add' "$MOCK_STATE/calls" | sed -n '1p')" = "mp-add orbcli/orbit" ]
  [ "$(grep 'mp-add' "$MOCK_STATE/calls" | sed -n '2p')" = "mp-add https://github.com/orbcli/orbit.git" ]
}

@test "default: no ORBIT_SOURCES means a single source and no rotation" {
  write_fake_curl_logging; write_fake_git
  cp "$INSTALL" "$SANDBOX/install.sh"
  run_install_mocked CURL_FAILS=2 ORBIT_RETRY=3 ORBIT_RETRY_DELAY_SECONDS=0 \
    bash "$SANDBOX/install.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MOCK_STATE/calls" | tr -d ' ')" -eq 3 ]   # 3 attempts, all curl
  ! grep -q "git-clone" "$MOCK_STATE/calls"               # never rotated to a clone
  [ "$(sed -n '3p' "$MOCK_STATE/calls")" = "curl https://raw.githubusercontent.com/orbcli/orbit/main/orbit.sh" ]
}

@test "chain: ORBIT_SOURCES wins over a pinned ORBIT_SOURCE" {
  write_fake_curl_logging; write_fake_git
  cp "$INSTALL" "$SANDBOX/install.sh"
  run_install_mocked CURL_FAILS=99 GIT_OK_SUBSTR="https://" \
    ORBIT_SOURCE="pinned/repo" ORBIT_SOURCES="first/repo https://github.com/first/repo.git" \
    ORBIT_RETRY=2 ORBIT_RETRY_DELAY_SECONDS=0 bash "$SANDBOX/install.sh"
  [ "$status" -eq 0 ]
  # The chain head is used, NOT the pinned source:
  [ "$(sed -n '1p' "$MOCK_STATE/calls")" = "curl https://raw.githubusercontent.com/first/repo/main/orbit.sh" ]
  [ "$(sed -n '2p' "$MOCK_STATE/calls")" = "git-clone https://github.com/first/repo.git" ]
  ! grep -q "pinned" "$MOCK_STATE/calls"
}

@test "chain: a path entry in a mixed chain installs real content (no silent empty)" {
  write_fake_curl_logging; write_fake_git   # both always fail
  mkdir -p "$SANDBOX/local-mirror"
  cp "${BATS_TEST_DIRNAME}/../orbit.sh" "$SANDBOX/local-mirror/orbit.sh"
  cp "$INSTALL" "$SANDBOX/install.sh"
  run_install_mocked CURL_FAILS=99 GIT_OK_SUBSTR="nothing-matches" \
    ORBIT_SOURCES="orbcli/orbit $SANDBOX/local-mirror" \
    ORBIT_RETRY=2 ORBIT_RETRY_DELAY_SECONDS=0 bash "$SANDBOX/install.sh"
  [ "$status" -eq 0 ]
  cmp -s "$FAKE_HOME/.local/bin/orbit" "$SANDBOX/local-mirror/orbit.sh"
}

@test "chain: a failing path HEAD rotates on to the next entry" {
  write_fake_curl_logging; write_fake_git
  cp "$INSTALL" "$SANDBOX/install.sh"
  run_install_mocked CURL_FAILS=99 GIT_OK_SUBSTR="https://" \
    ORBIT_SOURCES="$SANDBOX/no-such-dir https://github.com/orbcli/orbit.git" \
    ORBIT_RETRY=2 ORBIT_RETRY_DELAY_SECONDS=0 bash "$SANDBOX/install.sh"
  [ "$status" -eq 0 ]
  # The path cp is silent in the calls log; the first network call must be the HTTPS clone:
  [ "$(sed -n '1p' "$MOCK_STATE/calls")" = "git-clone https://github.com/orbcli/orbit.git" ]
  [ "$(wc -l < "$MOCK_STATE/calls" | tr -d ' ')" -eq 1 ]
  [ -x "$FAKE_HOME/.local/bin/orbit" ]
}
