#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
LOCAL_ORBIT="$SCRIPT_DIR/orbit.sh"

# Source resolution always lands on a CHAIN of candidate sources (same
# semantics per entry as `claude plugin marketplace add`):
#   - a GitHub repo shorthand   owner/repo             -> raw.githubusercontent.com
#   - a git URL                 https://… | git@…:…    -> shallow clone
#   - a local path              /… | ./… | existing dir
# Priority: ORBIT_SOURCES > ORBIT_SOURCE > this local checkout > the default
# GitHub repo. Each RETRY of a network operation rotates to the next chain
# entry — rotating spreads attempts across both route and time, and a
# one-entry chain simply never rotates (the stable default). The first attempt
# of each operation reuses the source that last succeeded. try.sh supplies a
# multi-entry chain (shorthand → HTTPS → SSH) for zero-setup demo runs.
# ORBIT_REF pins the branch/tag for raw downloads (default: main).
DEFAULT_SOURCE="orbcli/orbit"
ORBIT_REF="${ORBIT_REF:-main}"
# bash < 4.4 under `set -u` errors on ${#arr[@]} when the array is EMPTY, so
# never size-test a possibly-empty array — resolve strictly in priority order.
SOURCE_CHAIN=()
if [ -n "${ORBIT_SOURCES:-}" ]; then
  # Intentional word splitting: the chain is space-separated.
  # shellcheck disable=SC2206,SC2086
  SOURCE_CHAIN=(${ORBIT_SOURCES})
fi
if [ -z "${SOURCE_CHAIN[0]:-}" ]; then
  if [ -n "${ORBIT_SOURCE:-}" ]; then
    SOURCE_CHAIN=("$ORBIT_SOURCE")
  elif [ -f "$LOCAL_ORBIT" ]; then
    SOURCE_CHAIN=("$SCRIPT_DIR")
  else
    SOURCE_CHAIN=("$DEFAULT_SOURCE")
  fi
fi
SOURCE="${SOURCE_CHAIN[0]}"
chain_idx=1   # the first rotation moves to entry 2; a one-entry chain wraps to itself

# Where the `orbit` runtime lands. Defaults to ~/.local/bin; override with
# ORBIT_BIN_DIR to install into a caller-managed dir (e.g. a throwaway demo dir).
# A custom dir also means the caller owns PATH + cleanup, so the rc is left alone.
TARGET_BIN_DIR="${ORBIT_BIN_DIR:-$HOME/.local/bin}"
TARGET_HELPER="$TARGET_BIN_DIR/orbit"
# shellcheck disable=SC2016
PATH_EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'

# Network resilience knobs (env-only, same style as ORBIT_SOURCE). Intermittent
# blocks come and go by the minute and a blocked TCP connect otherwise hangs
# for over a minute with no output — so every network operation goes through
# net_run: up to ORBIT_RETRY attempts, ORBIT_RETRY_DELAY_SECONDS apart, each
# attempt killed at ORBIT_TIMEOUT_SECONDS.
ORBIT_RETRY="${ORBIT_RETRY:-3}"
ORBIT_RETRY_DELAY_SECONDS="${ORBIT_RETRY_DELAY_SECONDS:-5}"
ORBIT_TIMEOUT_SECONDS="${ORBIT_TIMEOUT_SECONDS:-60}"

# An unattended installer must never prompt: a 404/private repo makes git ask
# for credentials on /dev/tty (or a GUI askpass) and the run looks frozen.
# Credential helpers and SSH keys are unaffected — only interactive prompts.
# Exported so the agent CLIs' own internal clones inherit it too.
export GIT_TERMINAL_PROMPT=0

FORCE=0
UNINSTALL=0
UNINSTALL_CLI=0
UNINSTALL_ALL=0
INSTALL_CLAUDE=0
INSTALL_CODEX=0
INSTALL_OPENCODE=0
INSTALL_QODER=0
INSTALL_ZSH=0
INSTALL_BASH=0
SOURCE_TYPE=""   # path | repo | url — set by classify_source
OC_PLUGIN_TMP=""
OC_SKILL_TMP=""

fail() { printf '%s\n' "$*" >&2; exit 1; }

# Marketplace installs hand $SOURCE to the agent CLI, and an owner/repo
# shorthand leaves the clone protocol to that CLI — claude expands it to SSH
# with no fallback, so a machine without SSH keys fails right here. Hint the
# explicit-HTTPS retry instead of changing the default (SSH users keep SSH).
hint_https_source() {
  local flag="$1"
  if [ "$SOURCE_TYPE" = "repo" ]; then
    printf '%s\n' "hint: no SSH key for GitHub? retry with an explicit HTTPS source:" >&2
    # The typical victim here piped install.sh from the network and has no
    # local checkout — print the curl form (same precedent as completion_hint).
    printf '%s\n' "  ORBIT_SOURCE=https://github.com/$SOURCE.git \\" >&2
    printf '%s\n' "    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/$SOURCE/$ORBIT_REF/install.sh)\" _ $flag --force" >&2
  fi
}

# When every network attempt failed, hand the problem back to the user: the
# remaining issue is network reachability between this machine and the source
# host — not something install.sh can work around. A local checkout installs
# with zero network.
hint_local_source() {
  local flag="${1:-}" url="$SOURCE"
  if [ "$SOURCE_TYPE" = "path" ]; then
    # A lone path source never touched the network — the hint is noise there.
    # But a path entry inside a MULTI-entry chain still gets the escape hatch,
    # pointed at the chain's first network entry (same classification order as
    # classify_source).
    [ "${#SOURCE_CHAIN[@]}" -gt 1 ] || return 0
    url=""
    local entry
    for entry in "${SOURCE_CHAIN[@]}"; do
      case "$entry" in
        *://*|*@*:*)        url="$entry"; break ;;
        /*|./*|../*|~*)     ;;  # path entry — skip
        */*)                url="https://github.com/$entry.git"; break ;;
      esac
    done
    [ -n "$url" ] || return 0
  fi
  [ "$SOURCE_TYPE" != "repo" ] || url="https://github.com/$SOURCE.git"
  printf '%s\n' "hint: all retries failed — this is a network reachability issue between this" >&2
  printf '%s\n' "  machine and the source host, not something install.sh can work around." >&2
  printf '%s\n' "  get the repo onto this machine yourself (proxy / mirror / another network), then" >&2
  printf '%s\n' "  install from the checkout — a local path source needs no network:" >&2
  printf '%s\n' "    git clone $url && cd $(basename "$url" .git) && ./install.sh${flag:+ $flag}" >&2
}

# net_run <label> <cmd> [args...] — run a network command through intermittent
# blocks: up to $ORBIT_RETRY attempts, $ORBIT_RETRY_DELAY_SECONDS apart, each
# attempt killed at $ORBIT_TIMEOUT_SECONDS (portable per-attempt timeout —
# macOS has no GNU timeout). The first attempt reuses the current source; each
# RETRY rotates to the next chain source when the chain has more than one
# entry. Every attempt's output is captured; the final attempt's output is
# printed so the real error (DNS, timeout, refused) is never silent.
# Must be called in a guarded context (if / ||) — it returns the last status.
net_run() {
  local label="$1"; shift
  local attempt=1 rc=0 log pid timer via=""
  log="$(mktemp)"
  while :; do
    [ "$attempt" -eq 1 ] || chain_advance
    via=""
    [ "${#SOURCE_CHAIN[@]}" -le 1 ] || via=" via $SOURCE"
    "$@" >"$log" 2>&1 &
    pid=$!
    # Timeout killer: TERM the command at the cap, KILL 2s later if it
    # lingers. The timer sleeps run in its background so an incoming TERM
    # interrupts `wait` immediately (a foreground sleep would defer the trap),
    # and the trap kills the timer sleep — no orphaned sleep is left behind
    # for callers like bats to wait on.
    (
      trap 'kill -KILL "$s" 2>/dev/null; exit 0' TERM
      sleep "$ORBIT_TIMEOUT_SECONDS" & s=$!
      wait "$s" 2>/dev/null
      kill -TERM "$pid" 2>/dev/null
      sleep 2 & s=$!
      wait "$s" 2>/dev/null
      kill -KILL "$pid" 2>/dev/null
      exit 0
    ) >/dev/null 2>&1 &
    timer=$!
    wait "$pid" 2>/dev/null; rc=$?
    kill -TERM "$timer" 2>/dev/null; wait "$timer" 2>/dev/null
    if [ "$rc" -eq 0 ]; then rm -f "$log"; return 0; fi
    if [ "$attempt" -ge "$ORBIT_RETRY" ]; then
      # A killed attempt may leave an empty/partial log — name the timeout
      # explicitly or the user sees "last error:" with nothing under it.
      if [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; then
        printf '%s\n' "$label — giving up after $ORBIT_RETRY attempts (last$via timed out after ${ORBIT_TIMEOUT_SECONDS}s); last error:" >&2
      else
        printf '%s\n' "$label — giving up after $ORBIT_RETRY attempts (last$via); last error:" >&2
      fi
      sed 's/^/    /' "$log" >&2
      rm -f "$log"
      return 1
    fi
    if [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; then
      printf '%s\n' "$label — attempt $attempt/$ORBIT_RETRY$via timed out (${ORBIT_TIMEOUT_SECONDS}s); retrying in ${ORBIT_RETRY_DELAY_SECONDS}s ..." >&2
    else
      printf '%s\n' "$label — attempt $attempt/$ORBIT_RETRY$via failed; retrying in ${ORBIT_RETRY_DELAY_SECONDS}s ..." >&2
    fi
    sleep "$ORBIT_RETRY_DELAY_SECONDS"
    attempt=$((attempt + 1))
  done
}

cleanup() {
  [ -n "${SRC_ORBIT_TMP:-}" ] && rm -f "$SRC_ORBIT_TMP"
  [ -n "${CLONE_TMP:-}" ] && rm -rf "$CLONE_TMP"
  [ -n "${OC_PLUGIN_TMP:-}" ] && rm -f "$OC_PLUGIN_TMP"
  [ -n "${OC_SKILL_TMP:-}" ] && rm -f "$OC_SKILL_TMP"
  return 0
}
trap cleanup EXIT

# Classify $SOURCE into path | repo | url (claude plugin marketplace add semantics).
classify_source() {
  case "$SOURCE" in
    *://*|*@*:*)     SOURCE_TYPE="url" ;;
    /*|./*|../*|~*)  SOURCE_TYPE="path" ;;
    *)
      if [ -d "$SOURCE" ]; then
        SOURCE_TYPE="path"
      elif printf '%s' "$SOURCE" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
        SOURCE_TYPE="repo"
      else
        fail "cannot classify source '$SOURCE' (expected owner/repo, a git URL, or a path)"
      fi ;;
  esac
}

# Rotate $SOURCE to the next chain entry and re-classify it. No-op for a
# one-entry chain (a pinned ORBIT_SOURCE, a local checkout, or the default) —
# which also dodges set -u on old bash: entry 2 doesn't exist to be read.
chain_advance() {
  [ "${#SOURCE_CHAIN[@]}" -gt 1 ] || return 0
  SOURCE="${SOURCE_CHAIN[$chain_idx]}"
  chain_idx=$(( (chain_idx + 1) % ${#SOURCE_CHAIN[@]} ))
  classify_source
}

usage() {
  cat <<'EOF'
usage: ./install.sh [--claude] [--codex] [--opencode] [--qoder|--qodercli] [--zsh] [--bash] [--force]
                    [--uninstall [--cli] [--all] [--claude] [--codex] [--opencode] [--qoder] [--zsh] [--bash]]

Always installs the global `orbit` command to ~/.local/bin and ensures it is on
your PATH. Run with no flags (locally or via curl) to install just the runtime.

options:
  --claude    install the Orbit plugin into Claude Code (claude plugin ...)
  --codex     install the Orbit plugin into Codex (codex plugin ...)
  --opencode  install the Orbit plugin into OpenCode as a local file (~/.config/opencode/plugins/)
  --qoder     install the Orbit plugin via the Qoder CLI (qodercli plugins ...)
  --qodercli  alias of --qoder
  --zsh       install zsh tab-completion
  --bash      install bash tab-completion
  --force     reset an already-installed plugin and its marketplace: remove both,
              then re-add and reinstall from the current source. Use it to repair
              a broken plugin state or to switch the marketplace source (e.g.
              from a git repo to a local path, which some CLIs refuse via a plain
              add). Without --force, install always adds/refreshes the marketplace
              and (re)installs the plugin — it never removes anything.
  --help      show this message

uninstall:
  --uninstall  uninstall mode (must be combined with at least one target)
  --cli        uninstall the orbit runtime (~/.local/bin/orbit)
  --all        uninstall everything (runtime + all plugins + completions)

environment:
  ORBIT_SOURCE  install source: owner/repo, a git URL, or a local path
                (default: this checkout when cloned, else orbcli/orbit)
  ORBIT_SOURCES space-separated source chain, taking priority over
                ORBIT_SOURCE: each retry of a network operation rotates to
                the next entry. try.sh supplies a shorthand/HTTPS/SSH chain
                for demo runs; plain install.sh stays single-source.
  ORBIT_REF     branch/tag for the github raw orbit.sh download (default: main)
  ORBIT_RETRY   attempts per network operation before giving up (default: 3)
  ORBIT_RETRY_DELAY_SECONDS
                seconds between attempts (default: 5)
  ORBIT_TIMEOUT_SECONDS
                per-attempt cap in seconds; a blocked connection is killed
                and retried instead of hanging silently (default: 60)

examples:
  ./install.sh
  ./install.sh --claude --zsh
  ORBIT_SOURCE=orbcli/orbit ./install.sh --codex --force
  ./install.sh --uninstall --claude --codex
  ./install.sh --uninstall --all
  /bin/bash -c "$(curl -fsSL REMOTE/install.sh)"
  /bin/bash -c "$(curl -fsSL REMOTE/install.sh)" _ --claude
  /bin/bash -c "$(curl -fsSL REMOTE/install.sh)" _ --codex
  /bin/bash -c "$(curl -fsSL REMOTE/install.sh)" _ --claude --force
  /bin/bash -c "$(curl -fsSL REMOTE/install.sh)" _ --opencode
  /bin/bash -c "$(curl -fsSL REMOTE/install.sh)" _ --qoder
  /bin/bash -c "$(curl -fsSL REMOTE/install.sh)" _ --zsh
  /bin/bash -c "$(curl -fsSL REMOTE/install.sh)" _ --claude --zsh --force
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude)   INSTALL_CLAUDE=1; shift ;;
    --codex)    INSTALL_CODEX=1; shift ;;
    --qoder|--qodercli) INSTALL_QODER=1; shift ;;
    --opencode) INSTALL_OPENCODE=1; shift ;;
    --zsh)      INSTALL_ZSH=1; shift ;;
    --bash)     INSTALL_BASH=1; shift ;;
    --force)    FORCE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --cli)      UNINSTALL_CLI=1; shift ;;
    --all)      UNINSTALL_ALL=1; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) printf '%s\n' "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Validate the network knobs before any network operation.
for knob in ORBIT_RETRY ORBIT_RETRY_DELAY_SECONDS ORBIT_TIMEOUT_SECONDS; do
  val=""
  eval "val=\$$knob"
  case "$val" in
    ''|*[!0-9]*) fail "$knob must be a positive integer (got: $val)" ;;
  esac
done
unset knob val
[ "$ORBIT_RETRY" -ge 1 ] || fail "ORBIT_RETRY must be >= 1 (got: $ORBIT_RETRY)"
[ "$ORBIT_TIMEOUT_SECONDS" -ge 1 ] || fail "ORBIT_TIMEOUT_SECONDS must be >= 1 (got: $ORBIT_TIMEOUT_SECONDS)"

# --- Fetch orbit.sh from $SOURCE (path: direct; repo: raw; url: shallow clone) ---
resolve_source() {
  # A lone path source needs no fetch at all — fail fast if it's missing
  # orbit.sh. A path entry INSIDE a multi-entry chain fetches like any other
  # entry (mixed chains rotate, so every entry must be reachable via net_run).
  if [ "$SOURCE_TYPE" = "path" ] && [ "${#SOURCE_CHAIN[@]}" -le 1 ]; then
    [ -f "$SOURCE/orbit.sh" ] || fail "orbit.sh not found in path source: $SOURCE"
    SRC_ORBIT="$SOURCE/orbit.sh"
    return 0
  fi
  # With a multi-entry chain a retry can rotate between repo (raw download
  # via curl), url (git clone) and path sources, so both tools must be
  # present; a single-entry chain needs only its own tool.
  if [ "${#SOURCE_CHAIN[@]}" -gt 1 ]; then
    command -v curl >/dev/null 2>&1 || fail "curl is required to download orbit.sh"
    command -v git >/dev/null 2>&1 || fail "git is required to install from a URL source"
  elif [ "$SOURCE_TYPE" = "repo" ]; then
    command -v curl >/dev/null 2>&1 || fail "curl is required to download orbit.sh"
  elif [ "$SOURCE_TYPE" = "url" ]; then
    command -v git >/dev/null 2>&1 || fail "git is required to install from a URL source"
  fi
  SRC_ORBIT="$(mktemp)"; SRC_ORBIT_TMP="$SRC_ORBIT"   # repo/path-type target
  CLONE_TMP="$(mktemp -d)"                             # url-type target
  # Fetch via the CURRENT source (net_run rotates it across the chain on
  # retry). repo = raw file download; url = full shallow clone (NOT
  # --sparse: the OpenCode plugin files live in subdirectories that a
  # sparse checkout never materializes) into a fresh dir per attempt, so a
  # retried clone never dies on the previous attempt's partial leftovers;
  # path = plain copy — a mixed chain (e.g. a local mirror as fallback)
  # must have every entry be self-sufficient.
  fetch_orbit_sh() {
    case "$SOURCE_TYPE" in
      repo)
        curl -fsSL --connect-timeout 10 --max-time "$ORBIT_TIMEOUT_SECONDS" \
          "https://raw.githubusercontent.com/$SOURCE/$ORBIT_REF/orbit.sh" -o "$SRC_ORBIT" ;;
      url)
        rm -rf "$CLONE_TMP"
        git clone --depth 1 --filter=blob:none "$SOURCE" "$CLONE_TMP" ;;
      path)
        cp "$SOURCE/orbit.sh" "$SRC_ORBIT" ;;
    esac
  }
  net_run "fetch orbit.sh" fetch_orbit_sh \
    || { hint_local_source; fail "failed to fetch orbit.sh (last source: $SOURCE)"; }
  if [ "$SOURCE_TYPE" = "url" ]; then
    [ -f "$CLONE_TMP/orbit.sh" ] || fail "orbit.sh not found at the top level of $SOURCE"
    SRC_ORBIT="$CLONE_TMP/orbit.sh"
  fi
}

# --- Detect the rc file for the user's login shell ---
detect_shell_rc() {
  case "${SHELL:-}" in
    */zsh)  printf '%s\n' "$HOME/.zshrc" ;;
    */bash) printf '%s\n' "$HOME/.bashrc" ;;
    *)      printf '%s\n' "$HOME/.profile" ;;
  esac
}

ensure_path_export() {
  local rc_file="$1"
  [ -f "$rc_file" ] || : > "$rc_file"
  # shellcheck disable=SC2016
  if grep -Fq "$HOME/.local/bin" "$rc_file"; then
    return
  fi
  printf '\n%s\n' "$PATH_EXPORT_LINE" >> "$rc_file"
  printf '%s\n' "Added ~/.local/bin to PATH in: $rc_file"
}

install_cli() {
  mkdir -p "$TARGET_BIN_DIR"
  if [ -f "$TARGET_HELPER" ] && [ "$FORCE" -eq 0 ]; then
    printf '%s\n' "orbit runtime already installed at $TARGET_HELPER — skipping (use --force to reinstall)"
    return 0
  fi
  rm -f "$TARGET_HELPER"
  cp -L "$SRC_ORBIT" "$TARGET_HELPER"
  chmod +x "$TARGET_HELPER"
  printf '%s\n' "Installed orbit command to: $TARGET_HELPER"
}

# Point the marketplace at $SOURCE (fresh add) and refresh the snapshot.
# `add` exits 0 without refreshing when the marketplace already exists — a
# successful add says nothing about freshness — so `update` runs
# unconditionally; it is the step that actually pulls new content.
claude_marketplace_ensure() {
  claude plugin marketplace add "$SOURCE" || true
  claude plugin marketplace update orbcli
}

# After the marketplace step fails through every retry: warn and let the
# plugin install be the decider. We deliberately do NOT parse `marketplace
# list` output (three CLIs, three unstable formats — not worth the
# maintenance): an existing local snapshot installs fine offline, and if
# 'orbcli' was never installed the plugin install below fails on its own with
# a clear error — the root cause is the marketplace step, not the install.
# $1 names the operation pair ("add/update" or "add/upgrade") per CLI.
marketplace_warn() {
  local op="${1:-add/update}"
  printf '%s\n' "warning: marketplace $op failed (see the error above). If 'orbcli' was never" >&2
  printf '%s\n' "  installed on this machine, the plugin install below will fail too — the root" >&2
  printf '%s\n' "  cause is the marketplace step, not the install. To reset both plugin and" >&2
  printf '%s\n' "  marketplace, re-run with --force." >&2
}

# --force removes state before re-adding, so for a network source prove the
# source is reachable FIRST — with the same git transport the CLIs' adds use,
# through net_run's retry/rotation and output surfacing. On failure the
# teardown is skipped and the existing plugin/marketplace are preserved
# (offline --force must not destroy the last working snapshot). Path sources
# are local and need no probe.
force_source_reachable() {
  [ "$SOURCE_TYPE" = "path" ] && return 0
  local url="$SOURCE"
  [ "$SOURCE_TYPE" = "repo" ] && url="https://github.com/$SOURCE.git"
  net_run "probe: git ls-remote $url" git ls-remote "$url" HEAD
}

install_claude_plugin() {
  command -v claude >/dev/null 2>&1 || fail "claude CLI not found; install Claude Code first"
  [ "$SOURCE_TYPE" != "path" ] || [ -f "$SOURCE/.claude-plugin/marketplace.json" ] \
    || fail "marketplace manifest not found: $SOURCE/.claude-plugin/marketplace.json"
  # --force: full reset — remove plugin and marketplace, then the normal flow
  # re-adds fresh. The teardown runs only after the source proves reachable
  # (see force_source_reachable): an offline --force skips it and keeps the
  # existing install intact. Removal output stays visible on purpose — only
  # the exit code is tolerated (a missing target is expected on first reset).
  # No -y on the uninstall: that flag only skips the --prune confirmation
  # prompt, which a bare uninstall never triggers (and some CLIs reject it).
  if [ "$FORCE" -eq 1 ]; then
    if force_source_reachable; then
      claude plugin uninstall claude-orbit </dev/null || true
      claude plugin marketplace remove orbcli </dev/null || true
    else
      printf '%s\n' "warning: --force reset skipped (source unreachable) — existing plugin and marketplace preserved" >&2
    fi
  fi
  # If add/update both fail through every retry it's a real error (network,
  # bad source) and net_run has printed the CLI's own message; warn and let
  # the install decide.
  if ! net_run "claude plugin marketplace add/update (source: $SOURCE)" claude_marketplace_ensure; then
    marketplace_warn
  fi
  # A plugin (re)install re-copies content from the current marketplace
  # snapshot, so a plain install already refreshes content — no remove
  # needed outside --force.
  net_run "claude plugin install claude-orbit@orbcli" claude plugin install "claude-orbit@orbcli" \
    || { hint_https_source --claude; hint_local_source --claude; fail "claude plugin install failed"; }
  printf '%s\n' "Installed Orbit plugin into Claude Code"
}

# Point the marketplace at $SOURCE (fresh add) and refresh the snapshot —
# same add-then-always-update flow as claude_marketplace_ensure.
qoder_marketplace_ensure() {
  qodercli plugins marketplace add "$SOURCE" || true
  qodercli plugins marketplace update orbcli
}

install_qoder_plugin() {
  command -v qodercli >/dev/null 2>&1 || fail "qodercli not found; install the Qoder CLI first"
  [ "$SOURCE_TYPE" != "path" ] || [ -f "$SOURCE/.qoder-plugin/plugin.json" ] \
    || fail "plugin manifest not found: $SOURCE/.qoder-plugin/plugin.json"
  # --force: full reset — remove plugin and marketplace, then re-add fresh.
  # Teardown is gated on source reachability (see force_source_reachable).
  if [ "$FORCE" -eq 1 ]; then
    if force_source_reachable; then
      qodercli plugins uninstall "qoder-orbit@orbcli" -s user </dev/null || true
      qodercli plugins marketplace remove orbcli </dev/null || true
    else
      printf '%s\n' "warning: --force reset skipped (source unreachable) — existing plugin and marketplace preserved" >&2
    fi
  fi
  # Same add/update flow as install_claude_plugin: on total failure print the
  # causal warning and let the plugin install be the decider.
  if ! net_run "qodercli plugins marketplace add/update (source: $SOURCE)" qoder_marketplace_ensure; then
    marketplace_warn
  fi
  # A plugin (re)install re-copies from the marketplace cache, so plain
  # install already refreshes content — no separate update step needed.
  net_run "qodercli plugins install qoder-orbit@orbcli" qodercli plugins install "qoder-orbit@orbcli" -s user \
    || { hint_https_source --qoder; hint_local_source --qoder; fail "qodercli plugin install failed"; }
  printf '%s\n' "Installed Orbit plugin via qodercli"
}

# Add the marketplace, honoring $ORBIT_REF for git/repo sources via --ref
# (path sources take no ref).
codex_marketplace_add() {
  if [ "$SOURCE_TYPE" = "path" ]; then
    codex plugin marketplace add "$SOURCE"
  else
    codex plugin marketplace add "$SOURCE" --ref "$ORBIT_REF"
  fi
}

# Point the marketplace at $SOURCE and refresh the snapshot. `add` exits 0
# without refreshing when the marketplace already exists, while `upgrade`
# errors on path-backed marketplaces ("not configured as a Git marketplace")
# — those read live and need no refresh. So gate upgrade on our own
# SOURCE_TYPE: after a successful add the marketplace's type always matches
# it (a colliding add no-ops on the same source or re-points). Propagate
# add's failure when skipping upgrade, so a refused add (e.g. a git->path
# switch, which needs --force) stays visible.
codex_marketplace_ensure() {
  add_failed=0; codex_marketplace_add || add_failed=1
  if [ "$SOURCE_TYPE" != "path" ]; then
    codex plugin marketplace upgrade orbcli
  else
    [ "$add_failed" -eq 0 ]
  fi
}

install_codex_plugin() {
  command -v codex >/dev/null 2>&1 || fail "codex CLI not found; install Codex first"
  # Codex reads a repo marketplace from .agents/plugins/marketplace.json (its
  # plugin entry is codex-orbit), separate from Claude's legacy
  # .claude-plugin/marketplace.json. Both marketplaces share the name orbcli but
  # live under different CLIs and expose distinct plugin names, so they never
  # collide.
  [ "$SOURCE_TYPE" != "path" ] || [ -f "$SOURCE/.agents/plugins/marketplace.json" ] \
    || fail "marketplace manifest not found: $SOURCE/.agents/plugins/marketplace.json"
  # --force: full reset — remove plugin and marketplace, then re-add fresh.
  # This is also the way to switch sources (e.g. git repo -> local path):
  # codex refuses a colliding add from a different source in that direction.
  # Teardown is gated on source reachability (see force_source_reachable).
  if [ "$FORCE" -eq 1 ]; then
    if force_source_reachable; then
      codex plugin remove "codex-orbit@orbcli" </dev/null || true
      codex plugin marketplace remove orbcli </dev/null || true
    else
      printf '%s\n' "warning: --force reset skipped (source unreachable) — existing plugin and marketplace preserved" >&2
    fi
  fi
  # Same add/upgrade flow as install_claude_plugin, except `upgrade` only
  # applies to git sources (see codex_marketplace_ensure). On total failure
  # print the causal warning and let the plugin add be the decider.
  if ! net_run "codex plugin marketplace add/upgrade (source: $SOURCE)" codex_marketplace_ensure; then
    marketplace_warn "add/upgrade"
  fi
  # `plugin add` re-materializes from the current snapshot and `marketplace
  # upgrade` already cascades to installed plugins — no remove needed
  # outside --force.
  net_run "codex plugin add codex-orbit@orbcli" codex plugin add "codex-orbit@orbcli" \
    || { hint_https_source --codex; hint_local_source --codex; fail "codex plugin add failed"; }
  printf '%s\n' "Installed Orbit plugin into Codex"
}

install_opencode_plugin() {
  local plugin_src skill_src
  # A lone path source reads the files directly. A path entry INSIDE a
  # multi-entry chain goes through net_run like any other entry, so a failed
  # local mirror rotates on to the next source (see resolve_source).
  if [ "$SOURCE_TYPE" = "path" ] && [ "${#SOURCE_CHAIN[@]}" -le 1 ]; then
    plugin_src="$SOURCE/.opencode-plugin/plugin.ts"
    skill_src="$SOURCE/skills/orbit/SKILL.md"
  else
      plugin_src="$(mktemp)"; OC_PLUGIN_TMP="$plugin_src"
      skill_src="$(mktemp)"; OC_SKILL_TMP="$skill_src"
      # Fetch BOTH files within one attempt via the current source (net_run
      # rotates it on retry). repo = two raw downloads; url = copy from the
      # resolve-time clone when it holds the files, else clone fresh (a
      # rotated-in URL source has no local copy yet); path = plain copy —
      # a mixed chain (e.g. a local mirror as fallback) must have every
      # entry be self-sufficient.
      fetch_oc_files() {
        case "$SOURCE_TYPE" in
          repo)
            curl -fsSL --connect-timeout 10 --max-time "$ORBIT_TIMEOUT_SECONDS" \
              "https://raw.githubusercontent.com/$SOURCE/$ORBIT_REF/.opencode-plugin/plugin.ts" -o "$plugin_src" \
            && curl -fsSL --connect-timeout 10 --max-time "$ORBIT_TIMEOUT_SECONDS" \
              "https://raw.githubusercontent.com/$SOURCE/$ORBIT_REF/skills/orbit/SKILL.md" -o "$skill_src" ;;
          url)
            if [ ! -f "$CLONE_TMP/.opencode-plugin/plugin.ts" ]; then
              rm -rf "$CLONE_TMP"
              git clone --depth 1 --filter=blob:none "$SOURCE" "$CLONE_TMP" || return 1
            fi
            cp "$CLONE_TMP/.opencode-plugin/plugin.ts" "$plugin_src" \
              && cp "$CLONE_TMP/skills/orbit/SKILL.md" "$skill_src" ;;
          path)
            cp "$SOURCE/.opencode-plugin/plugin.ts" "$plugin_src" \
              && cp "$SOURCE/skills/orbit/SKILL.md" "$skill_src" ;;
        esac
      }
      net_run "fetch opencode plugin files" fetch_oc_files \
        || { hint_local_source --opencode; fail "failed to fetch the OpenCode plugin files (last source: $SOURCE)"; }
  fi

  [ -f "$plugin_src" ] || fail "plugin.ts not found: $plugin_src"
  [ -f "$skill_src" ] || fail "SKILL.md not found: $skill_src"

  local plugin_dir="$HOME/.config/opencode/plugins"
  local skill_dir="$HOME/.config/opencode/skills/orbit"

  # OpenCode has no marketplace/CLI — the plugin is a copied file, so a plain
  # install always refreshes (overwrite in place). --force additionally wipes
  # the skill directory first, so files dropped from older payloads can't
  # linger. The skill dir is ours alone (plugins/ is shared with other
  # plugins). The case guard is a fail-closed invariant: it only ever matches
  # the literal assignment above — its job is to turn a future bad edit of
  # that assignment into a refusal instead of a stray rm -rf (literal path,
  # no trailing slash: a symlink is unlinked, never followed).
  if [ "$FORCE" -eq 1 ]; then
    rm -f "$plugin_dir/orbit.ts"
    case "$skill_dir" in
      "$HOME"/.config/opencode/skills/orbit) rm -rf "$skill_dir" ;;
      *) fail "refusing to remove unexpected skill dir: $skill_dir" ;;
    esac
  fi
  mkdir -p "$plugin_dir" "$skill_dir"

  # Copy atomically: a plain cp is truncate-then-write, so a mid-copy failure
  # would leave a broken plugin/skill behind on the next host start.
  cp "$plugin_src" "$plugin_dir/orbit.ts.tmp" && mv "$plugin_dir/orbit.ts.tmp" "$plugin_dir/orbit.ts"
  cp "$skill_src" "$skill_dir/SKILL.md.tmp" && mv "$skill_dir/SKILL.md.tmp" "$skill_dir/SKILL.md"

  printf '%s\n' "Installed Orbit plugin into OpenCode ($plugin_dir/orbit.ts)"
  printf '%s\n' "Installed Orbit skill into OpenCode ($skill_dir/SKILL.md)"
}

install_completion_zsh() {
  local dir=""
  local fpaths
  fpaths=$(zsh -ic 'printf "%s\n" $fpath' 2>/dev/null) || true
  while IFS= read -r d; do
    if [ -n "$d" ] && [ -d "$d" ] && [ -w "$d" ]; then dir="$d"; break; fi
  done <<< "$fpaths"
  if [ -z "$dir" ]; then
    dir="$HOME/.local/share/zsh/site-functions"
    mkdir -p "$dir"
  fi
  "$TARGET_HELPER" completion zsh > "$dir/_orbit"
  printf '%s\n' "Installed zsh completion to: $dir/_orbit"
  case "$dir" in
    "$HOME"/*) printf '%s\n' "Add to .zshrc before compinit: fpath=($dir \$fpath)" ;;
  esac
}

install_completion_bash() {
  local dir=""
  local d
  for d in \
    "${BASH_COMPLETION_COMPAT_DIR:-}" \
    "/usr/local/share/bash-completion/completions" \
    "/usr/share/bash-completion/completions"; do
    if [ -n "$d" ] && [ -d "$d" ] && [ -w "$d" ]; then dir="$d"; break; fi
  done
  if [ -z "$dir" ]; then
    dir="$HOME/.local/share/bash-completion/completions"
    mkdir -p "$dir"
  fi
  "$TARGET_HELPER" completion bash > "$dir/orbit"
  printf '%s\n' "Installed bash completion to: $dir/orbit"
  case "$dir" in
    "$HOME"/*) printf '%s\n' "Ensure bash-completion is enabled in .bashrc" ;;
  esac
}

# Detect an already-installed completion for the login shell. Echoes the file
# path (and returns 0) when one exists, so the install hint can skip nagging the
# user to install completion they already have. Only the login shell's flavor is
# checked — that's the shell whose tab-completion the hint would recommend.
completion_already_installed() {
  local d
  case "${SHELL:-}" in
    */zsh)
      for d in \
        "$HOME/.local/share/zsh/site-functions" \
        /usr/local/share/zsh/site-functions \
        /usr/share/zsh/site-functions; do
        [ -f "$d/_orbit" ] && { printf '%s\n' "$d/_orbit"; return 0; }
      done ;;
    */bash)
      for d in \
        "$HOME/.local/share/bash-completion/completions" \
        /usr/local/share/bash-completion/completions \
        /usr/share/bash-completion/completions; do
        [ -f "$d/orbit" ] && { printf '%s\n' "$d/orbit"; return 0; }
      done ;;
  esac
  return 1
}

completion_hint() {
  [ "$INSTALL_ZSH" -eq 0 ] && [ "$INSTALL_BASH" -eq 0 ] || return 0
  # Already installed for this shell → skip the nag; there's nothing to do.
  if completion_already_installed >/dev/null 2>&1; then
    return 0
  fi
  local flag
  case "${SHELL:-}" in
    */zsh)  flag="--zsh" ;;
    */bash) flag="--bash" ;;
    *)      flag="--zsh (zsh) or --bash (bash)" ;;
  esac
  printf '%s\n' "To install shell tab-completion:"
  if [ "$SOURCE_TYPE" = "repo" ]; then
    printf '  %s\n' "/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/$SOURCE/$ORBIT_REF/install.sh)\" _ $flag"
  else
    printf '  %s\n' "./install.sh $flag"
  fi
}

# --- Uninstall functions (fail-safe: no-op if target is already gone) ---
uninstall_cli() {
  [ -f "$TARGET_HELPER" ] || { printf '%s\n' "orbit runtime not found at $TARGET_HELPER — nothing to remove"; return 0; }
  rm "$TARGET_HELPER"
  printf '%s\n' "Removed orbit runtime from: $TARGET_HELPER"
}

uninstall_claude_plugin() {
  command -v claude >/dev/null 2>&1 || { printf '%s\n' "claude CLI not found — skipping"; return 0; }
  claude plugin uninstall claude-orbit </dev/null || true
  claude plugin marketplace remove orbcli </dev/null || true
  printf '%s\n' "Removed Orbit plugin from Claude Code"
}

uninstall_codex_plugin() {
  command -v codex >/dev/null 2>&1 || { printf '%s\n' "codex CLI not found — skipping"; return 0; }
  codex plugin remove "codex-orbit@orbcli" </dev/null || true
  codex plugin marketplace remove orbcli </dev/null || true
  printf '%s\n' "Removed Orbit plugin from Codex"
}

uninstall_qoder_plugin() {
  command -v qodercli >/dev/null 2>&1 || { printf '%s\n' "qodercli not found — skipping"; return 0; }
  qodercli plugins uninstall "qoder-orbit@orbcli" -s user </dev/null || true
  qodercli plugins marketplace remove orbcli </dev/null || true
  printf '%s\n' "Removed Orbit plugin from Qoder"
}

uninstall_opencode_plugin() {
  rm -f "$HOME/.config/opencode/plugins/orbit.ts"
  rm -rf "$HOME/.config/opencode/skills/orbit"
  printf '%s\n' "Removed Orbit plugin from OpenCode"
}

uninstall_completion_zsh() {
  local d
  for d in \
    "$HOME/.local/share/zsh/site-functions" \
    /usr/local/share/zsh/site-functions \
    /usr/share/zsh/site-functions; do
    [ -f "$d/_orbit" ] && rm "$d/_orbit" && printf '%s\n' "Removed zsh completion: $d/_orbit"
  done
  return 0
}

uninstall_completion_bash() {
  local d
  for d in \
    "$HOME/.local/share/bash-completion/completions" \
    /usr/local/share/bash-completion/completions \
    /usr/share/bash-completion/completions; do
    [ -f "$d/orbit" ] && rm "$d/orbit" && printf '%s\n' "Removed bash completion: $d/orbit"
  done
  return 0
}

# --- Run ---
if [ "$UNINSTALL" -eq 1 ]; then
  # --all expands to every target
  if [ "$UNINSTALL_ALL" -eq 1 ]; then
    UNINSTALL_CLI=1
    INSTALL_CLAUDE=1
    INSTALL_CODEX=1
    INSTALL_OPENCODE=1
    INSTALL_QODER=1
    INSTALL_ZSH=1
    INSTALL_BASH=1
  fi
  # Must specify at least one target
  if [ "$UNINSTALL_CLI" -eq 0 ] && [ "$INSTALL_CLAUDE" -eq 0 ] && [ "$INSTALL_CODEX" -eq 0 ] \
    && [ "$INSTALL_OPENCODE" -eq 0 ] && [ "$INSTALL_QODER" -eq 0 ] \
    && [ "$INSTALL_ZSH" -eq 0 ] && [ "$INSTALL_BASH" -eq 0 ]; then
    fail "--uninstall requires at least one target: --cli, --all, --claude, --codex, --opencode, --qoder, --zsh, or --bash"
  fi

  if [ "$INSTALL_CLAUDE" -eq 1 ]; then   uninstall_claude_plugin; fi
  if [ "$INSTALL_CODEX" -eq 1 ]; then    uninstall_codex_plugin; fi
  if [ "$INSTALL_OPENCODE" -eq 1 ]; then uninstall_opencode_plugin; fi
  if [ "$INSTALL_QODER" -eq 1 ]; then   uninstall_qoder_plugin; fi
  if [ "$INSTALL_ZSH" -eq 1 ]; then     uninstall_completion_zsh; fi
  if [ "$INSTALL_BASH" -eq 1 ]; then    uninstall_completion_bash; fi
  if [ "$UNINSTALL_CLI" -eq 1 ]; then   uninstall_cli; fi

  printf '%s\n' "Done. PATH entries in your shell rc are left in place (harmless without the binary)."
  exit 0
fi

classify_source
resolve_source
install_cli
# Manage the login shell's rc only for the default location. A custom ORBIT_BIN_DIR
# means the caller owns PATH (and cleanup), so leave the rc untouched — no dead
# PATH entry left behind after the caller removes its dir.
if [ -z "${ORBIT_BIN_DIR:-}" ]; then
  ensure_path_export "$(detect_shell_rc)"
fi

if [ "$INSTALL_ZSH" -eq 1 ]; then
  ensure_path_export "$HOME/.zshrc"
  install_completion_zsh
fi
if [ "$INSTALL_BASH" -eq 1 ]; then
  ensure_path_export "$HOME/.bashrc"
  install_completion_bash
fi

if [ "$INSTALL_CLAUDE" -eq 1 ]; then
  install_claude_plugin
fi
if [ "$INSTALL_CODEX" -eq 1 ]; then
  install_codex_plugin
fi
if [ "$INSTALL_OPENCODE" -eq 1 ]; then
  install_opencode_plugin
fi
if [ "$INSTALL_QODER" -eq 1 ]; then
  install_qoder_plugin
fi

printf '%s\n' "Next steps:"
if [ -n "${ORBIT_BIN_DIR:-}" ]; then
  printf '  %s\n' "- Add to PATH: export PATH=\"$TARGET_BIN_DIR:\$PATH\""
else
  printf '  %s\n' "- Open a new shell or run: source $(detect_shell_rc)"
fi
printf '  %s\n' "- Verify with: orbit doctor"
if [ "$INSTALL_CLAUDE" -eq 1 ]; then
  printf '  %s\n' "- In Claude Code, the Orbit skill and SessionStart hook are now active"
fi
if [ "$INSTALL_CODEX" -eq 1 ]; then
  printf '  %s\n' "- In Codex, the Orbit skill and SessionStart hook are now active (review hooks in /hooks on first run)"
fi
if [ "$INSTALL_OPENCODE" -eq 1 ]; then
  printf '  %s\n' "- In OpenCode, the Orbit skill and system-context hook are now active"
fi
if [ "$INSTALL_QODER" -eq 1 ]; then
  printf '  %s\n' "- In Qoder, the Orbit skill is now active"
fi
completion_hint
