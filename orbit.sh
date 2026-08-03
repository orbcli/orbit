#!/usr/bin/env bash
set -euo pipefail

ORBIT_VERSION="0.1.0"
ORBIT_ROOT="${ORBIT_ROOT:-}"
ORBIT_DEFAULT_BRANCH_PREFIX="ws"
ORBIT_CMD="${0##*/}"

# --- Messages (all decorative output goes to stderr) ---

# new: editor prompts (before creation)
ORBIT_NEW_PROMPTS=(
  "What's the mission?"
  "Plot your course."
  "Set your heading."
  "Name your target."
  "Where to, pilot?"
  "Log your objective."
)

# new: farewells (after creation)
# shellcheck disable=SC2034
ORBIT_NEW_FAREWELLS=(
  "Godspeed."
  "Ad astra."
  "Go for orbit."
  "Fly true."
  "All systems nominal."
  "Good hunting."
)

# goal: editor prompts (before update)
ORBIT_GOAL_PROMPTS=(
  "Revise the mission."
  "Adjust your heading."
  "Recalculate trajectory."
  "Update the briefing."
  "New orders, pilot."
  "Amend the flight plan."
)

# goal: farewells (after update)
# shellcheck disable=SC2034
ORBIT_GOAL_FAREWELLS=(
  "Target locked."
  "Course corrected."
  "New heading confirmed."
  "Objective updated."
  "Coordinates set."
  "Recalibrating..."
)

# goal: farewells (after clear)
# shellcheck disable=SC2034
ORBIT_GOAL_CLEAR_FAREWELLS=(
  "Target disengaged."
  "Drifting free."
  "Off the grid."
  "Signal lost. Standing by."
)

# done: farewells (after marking done)
# shellcheck disable=SC2034
ORBIT_DONE_FAREWELLS=(
  "Mission complete."
  "Orbit achieved."
  "Touchdown confirmed."
  "Splashdown."
  "Payload delivered."
  "That's one for the books."
)

orbit_random_msg() {
  local _arr_name=$1
  eval "local _len=\${#${_arr_name}[@]}"
  # shellcheck disable=SC2154
  local idx=$(( RANDOM % _len ))
  eval "local _msg=\${${_arr_name}[$idx]}"
  # shellcheck disable=SC2154
  printf '\n%s\n' "$_msg" >&2
}

# --- Utilities ---

orbit_usage() {
  cat <<EOF
Usage:
  $ORBIT_CMD clone <url> [--push <fork-url>] [--name <repo>] [--branch <branch>]
  $ORBIT_CMD repos
  $ORBIT_CMD info <repo>
  $ORBIT_CMD memo [<repo>] [--refresh|--scaffold]
  $ORBIT_CMD new "<goal>" [--name <name>] [--no-goal] [--exec "<cmd>"]
  $ORBIT_CMD add <repo> [--ref <tag/branch>] [-s|--silent]
  $ORBIT_CMD switch [-c] [repo] <name>
  $ORBIT_CMD sync [repo...] [--force] [--branch <branch>]
  $ORBIT_CMD done [--pr <url>...] [--json]
  $ORBIT_CMD status [workspace] [--json]
  $ORBIT_CMD goal ["text"] [--clear]
  $ORBIT_CMD jot [<repo>] ["text"] [--pop] [--json]
  $ORBIT_CMD prune [workspace] [--older <dur>] [--dry-run] [--force] [--verify]
  $ORBIT_CMD config [<key> [<value> | --unset]]
  $ORBIT_CMD context [<key>] [--startup|--prime|--reignite] [--json]
  $ORBIT_CMD doctor
  $ORBIT_CMD completion <zsh|bash>
  $ORBIT_CMD version

  Options: --json for machine-readable output (repos, status, info, done, context, jot --pop)

Config keys (project-level, via '$ORBIT_CMD config <key> <value>'):
  agent.recommend       Launch command recommended after 'new' (e.g. 'claude "orbit start"')
  branch.prefix         Scoped-mode tracking branch prefix (default: ws)
  memo.minLines         Memo card soft lower bound / thin floor (default: 4)
  memo.maxLines         Memo card hard upper bound / compress + README-fallback cap (default: 16)
  jot.bufferSize        Jot entries per repo before aggregation is nudged (default: memo.minLines = 4)
  explore.paths         Cold-start memo exploration scope: comma-delimited <path>:<depth>
                        list, e.g. '.:1,src:1,docs:2' (default: .:1)

Environment:
  ORBIT_ROOT             Explicit project root (default: discover from CWD)
EOF
}

orbit_fail() {
  printf 'orbit: %s\n' "$*" >&2
  return 1
}

# orbit_plural <count> <singular> <plural> — human-facing counts read wrong
# with a bare "s" ("1 repos"); branch→branches style plurals need both forms.
orbit_plural() {
  if [ "$1" = "1" ]; then
    printf '%s' "$2"
  else
    printf '%s' "$3"
  fi
}

# One path segment, legal inside a git refname, and not something that reads as
# an option on a command line. git check-ref-format is the authority on the
# rest (rejects '.'-leading, '..', spaces, control chars).
orbit_valid_branch_prefix() {
  case "$1" in
    ''|*/*|-*) return 1 ;;
  esac
  git check-ref-format "refs/heads/$1/w/n" >/dev/null 2>&1
}

# List pool repos holding local branches under <prefix>/, as "repo (n)" pairs.
# Returns 1 when there are none.
orbit_branches_under_prefix() {
  local root="$1" prefix="$2" repo_dir count total=0 hits=""
  for repo_dir in "$root/.repos"/*/; do
    [ -d "$repo_dir" ] || continue
    count=$(git -C "$repo_dir" for-each-ref --format='%(refname:short)' "refs/heads/$prefix/" 2>/dev/null | grep -c . || true)
    [ "${count:-0}" -gt 0 ] || continue
    hits="$hits $(basename "$repo_dir") ($count)"
    total=$((total + count))
  done
  [ "$total" -gt 0 ] || return 1
  printf '%s\n' "${hits# }"
}

# The tracking-branch prefix is a durable project property, not per-invocation
# state: it is baked into every branch name orbit creates AND it is the selector
# prune uses to decide which branches are orbit's to delete. Those two moments
# must agree — if they can disagree, branches leak (created under one prefix,
# looked for under another) or, worse, prune claims branches it never created.
# So it lives in project config, written deliberately and persisting across
# sessions, rather than in an environment variable any single call can flip.
orbit_require_prefix() {
  local prefix="" root
  if root=$(orbit_find_root 2>/dev/null); then
    prefix=$(git config --file "$root/.repos/.orbit" --get branch.prefix 2>/dev/null || true)
  fi
  [ -n "$prefix" ] || prefix="$ORBIT_DEFAULT_BRANCH_PREFIX"
  orbit_valid_branch_prefix "$prefix" || { orbit_fail "invalid branch.prefix in project config: $prefix"; return 1; }
  printf '%s\n' "$prefix"
}

orbit_find_root() {
  if [ -n "$ORBIT_ROOT" ]; then
    [ -d "$ORBIT_ROOT/.repos" ] || return 1
    printf '%s\n' "$ORBIT_ROOT"
    return 0
  fi
  local dir
  dir="$(pwd)"
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/.repos" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

orbit_require_root() {
  local root
  root=$(orbit_find_root) || { orbit_fail "not in an orbit project (no .repos/ found); use 'orbit clone' or 'orbit new' to start"; return 1; }
  printf '%s\n' "$root"
}

# Pool infrastructure marker. .repos/ is orbit's pool, not an agent API surface:
# it lives outside the workspace sandbox and all access goes through orbit
# commands. This README is a passive warning that surfaces if an agent ever
# lists .repos/ directly. Idempotent — written once, never overwritten.
orbit_write_pool_readme() {
  local repos_dir="$1"
  [ -f "$repos_dir/README.md" ] && return 0
  cat > "$repos_dir/README.md" <<'EOF'
# .repos/ — orbit pool infrastructure (do not access directly)

This directory is orbit's repo pool. It is internal infrastructure, not an API
surface. Do not read, edit, or run git inside `.repos/` directly.

All pool access goes through orbit commands:

- `orbit repos` / `orbit info <repo>` — list and inspect pool repos
- `orbit add <repo>` — bring a repo into your workspace as a worktree
- `orbit sync <repo>` — update a pool repo from its upstream
- `orbit memo <repo>` — read/write a repo's memo card

Work happens in workspace worktrees created by `orbit add`, never here.
EOF
}

orbit_ensure_init() {
  local root
  if root=$(orbit_find_root); then
    mkdir -p "$root/.repos"
    [ -f "$root/.repos/.orbit" ] || touch "$root/.repos/.orbit"
    orbit_write_pool_readme "$root/.repos"
    printf '%s\n' "$root"
    return 0
  fi
  root="$(pwd)"
  mkdir -p "$root/.repos"
  touch "$root/.repos/.orbit"
  orbit_write_pool_readme "$root/.repos"
  printf '%s\n' "$root"
}

orbit_repo_basename() {
  local remote name
  remote="$1"
  name="${remote%/}"
  name="${name##*/}"
  name="${name##*:}"
  name="${name%.git}"
  [ -n "$name" ] || orbit_fail "cannot derive repo name from: $remote"
  printf '%s\n' "$name"
}

orbit_default_branch() {
  local repo="$1" head branch
  head=$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
  # Trust the local pointer only if it actually resolves — guards a dangling
  # origin/HEAD left behind by a deleted default branch.
  if [ -n "$head" ] && git -C "$repo" rev-parse --verify --quiet "$head" >/dev/null 2>&1; then
    printf '%s\n' "${head#refs/remotes/origin/}"
    return 0
  fi
  if git -C "$repo" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
    printf 'main\n'
    return 0
  fi
  if git -C "$repo" rev-parse --verify --quiet origin/master >/dev/null 2>&1; then
    printf 'master\n'
    return 0
  fi
  # Fallback: ask the remote directly. Handles a non-standard default branch
  # (e.g. develop/trunk) when origin/HEAD is missing — as after a single-branch
  # clone. Persist the answer so the fast local path works next time.
  branch=$(git -C "$repo" ls-remote --symref origin HEAD 2>/dev/null \
    | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}')
  if [ -n "$branch" ]; then
    git -C "$repo" remote set-head origin --auto >/dev/null 2>&1 || true
    printf '%s\n' "$branch"
    return 0
  fi
  orbit_fail "cannot determine default branch for $repo
  the remote has no detectable default branch — it is likely empty (no commits/branches pushed yet) or missing origin/HEAD.
  fix: push an initial commit to the remote, then run 'orbit sync'."
}

orbit_git_supports_orphan_worktree() {
  local ver
  ver=$(git --version | awk '{print $3}')
  [ "$(printf '%s\n' "2.42" "$ver" | sort -V | head -n1)" = "2.42" ]
}

orbit_git_supports_autosetupremote() {
  local ver
  ver=$(git --version | awk '{print $3}')
  [ "$(printf '%s\n' "2.37" "$ver" | sort -V | head -n1)" = "2.37" ]
}

orbit_reserved_workspace() {
  case "$1" in
    ''|.|..|.repos|.git|*/*) return 0 ;;
    .*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print the name of the workspace containing the given path, nothing if none.
# "Looks like a workspace" = a non-reserved direct child of the project root;
# any depth below it counts (workspaces host repos and nested dirs). Detection
# is purely structural — it does NOT require a .orbit marker: workspace metadata
# is disposable (Principle 3), so a lost or absent .orbit must never quietly
# disable a destructive-op guard. orbit_reserved_workspace already excludes
# .repos/.git and every dotdir, so the pool index cannot be mistaken for one.
orbit_ws_containing_dir() {
  local root="$1" path="$2" root_phys path_phys rel first
  root_phys=$(cd "$root" 2>/dev/null && pwd -P) || return 1
  [ -d "$path" ] || return 1
  path_phys=$(cd "$path" 2>/dev/null && pwd -P) || return 1
  case "$path_phys" in
    "$root_phys") return 1 ;;
    "$root_phys"/*) ;;
    *) return 1 ;;
  esac
  rel="${path_phys#"$root_phys/"}"
  first="${rel%%/*}"
  orbit_reserved_workspace "$first" && return 1
  printf '%s\n' "$first"
}

orbit_tracking_branch() {
  local prefix ws name
  prefix=$(orbit_require_prefix) || return 1
  ws="$1"; name="$2"
  printf '%s/%s/%s\n' "$prefix" "$ws" "$name"
}

orbit_branch_is_checked_out_elsewhere() {
  local repo="$1" branch="$2"
  git -C "$repo" worktree list --porcelain | grep -Fqx "branch refs/heads/$branch"
}

orbit_set_upstream() {
  local path="$1" local_branch="$2" upstream_branch="$3"
  git -C "$path" config "branch.$local_branch.remote" origin
  git -C "$path" config "branch.$local_branch.merge" "refs/heads/$upstream_branch"
}

orbit_remote_branch_exists() {
  local repo="$1" branch="$2"
  git -C "$repo" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1
}

orbit_add_fetch_refspec() {
  local repo="$1" branch="$2"
  local refspec="+refs/heads/$branch:refs/remotes/origin/$branch"
  git -C "$repo" config --get-all remote.origin.fetch 2>/dev/null | grep -Fqx "$refspec" && return 0
  git -C "$repo" config --add remote.origin.fetch "$refspec"
}

orbit_ensure_remote_branch() {
  local repo="$1" branch="$2"
  orbit_add_fetch_refspec "$repo" "$branch"
  # Always fetch, even when origin/<branch> exists locally: the remote branch
  # may have advanced or been force-pushed after it was fetched, and checking
  # out the stale ref silently builds on abandoned history. Degrade when
  # offline: use the local ref with a warning; fail only when there is
  # nothing to fall back on.
    if ! git -C "$repo" fetch origin "$branch" 2>/dev/null; then
    if git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
      printf 'orbit: cannot fetch origin/%s, using possibly-stale local ref\n' "$branch" >&2
    else
      # Roll back the refspec registered above: a leftover entry pointing at a
      # non-existent remote branch breaks every bare fetch in the pool until
      # the next reconcile touchpoint.
      orbit_remove_fetch_refspec "$repo" "+refs/heads/$branch:refs/remotes/origin/$branch"
      orbit_fail "cannot fetch origin/$branch"
    fi
  fi
}

# Remove one exact fetch refspec value. `git config --unset` matches the value
# as a regex and the refspec's leading '+' is an invalid pattern, so prefer
# --fixed-value (git >= 2.26, atomic single-value removal); older git falls
# back to rebuilding the value list.
orbit_remove_fetch_refspec() {
  local repo="$1" target="$2" line
  if git -C "$repo" config --unset --fixed-value remote.origin.fetch "$target" 2>/dev/null; then
    return 0
  fi
  local keep=()
  while IFS= read -r line; do
    [ "$line" = "$target" ] || keep+=("$line")
  done < <(git -C "$repo" config --get-all remote.origin.fetch 2>/dev/null || true)
  git -C "$repo" config --unset-all remote.origin.fetch 2>/dev/null || true
  for line in ${keep[@]+"${keep[@]}"}; do
    git -C "$repo" config --add remote.origin.fetch "$line"
  done
}

# Reconcile the pool's exact fetch refspecs with reality. Invariant: every
# configured exact refspec must point at a branch the remote actually has —
# one stale entry makes every bare `git fetch` fail with "couldn't find
# remote ref" in every worktree of the pool.
#
# Phase 1 removes refspecs whose remote branch is gone (typical: auto-deleted
# on PR merge; also legacy refspecs pre-registered by `switch -c` for branches
# never pushed). Phase 2 registers refspecs for locally-tracked branches that
# exist remotely but have none (scoped/raw branch pushed since last run), so
# their remote-tracking refs can materialize. Refspecs orbit never wrote
# (wildcards, other remote layouts) are left untouched in both phases.
#
# Prints one line per change (or would-change, in dry-run).
orbit_reconcile_fetch_refspecs() {
  local repo="$1" dry_run="${2:-0}"
  local remote_heads refspec branch lb merge
  # One network round-trip; on failure (offline etc.) skip reconciliation
  # entirely so unverifiable refspecs are never removed by mistake.
  remote_heads=$(git -C "$repo" ls-remote --heads origin 2>/dev/null) || return 0
  while IFS= read -r refspec; do
    case "$refspec" in
      +refs/heads/*:refs/remotes/origin/*) ;;
      *) continue ;;
    esac
    branch="${refspec#+refs/heads/}"
    branch="${branch%%:refs/remotes/origin/*}"
    # Foreign refspecs are not orbit's to manage: git refnames forbid '*', so
    # anything containing a glob (e.g. a user-configured full-fetch wildcard
    # '+refs/heads/*:refs/remotes/origin/*') stays untouched.
    case "$branch" in *'*'*) continue ;; esac
    printf '%s\n' "$remote_heads" | awk '{print $2}' | grep -Fqx "refs/heads/$branch" && continue
    if [ "$dry_run" = "1" ]; then
      printf 'would remove stale fetch refspec: %s\n' "$branch"
    else
      orbit_remove_fetch_refspec "$repo" "$refspec"
      git -C "$repo" update-ref -d "refs/remotes/origin/$branch" 2>/dev/null || true
      printf 'removed stale fetch refspec: %s\n' "$branch"
    fi
  done < <(git -C "$repo" config --get-all remote.origin.fetch 2>/dev/null || true)
  while IFS= read -r lb; do
    [ -n "$lb" ] || continue
    [ "$(git -C "$repo" config --get "branch.$lb.remote" 2>/dev/null)" = "origin" ] || continue
    merge=$(git -C "$repo" config --get "branch.$lb.merge" 2>/dev/null) || continue
    case "$merge" in
      refs/heads/*) branch="${merge#refs/heads/}" ;;
      *) continue ;;
    esac
    printf '%s\n' "$remote_heads" | awk '{print $2}' | grep -Fqx "refs/heads/$branch" || continue
    git -C "$repo" config --get-all remote.origin.fetch 2>/dev/null \
      | grep -Fqx "+refs/heads/$branch:refs/remotes/origin/$branch" && continue
    if [ "$dry_run" = "1" ]; then
      printf 'would add fetch refspec: %s\n' "$branch"
    else
      orbit_add_fetch_refspec "$repo" "$branch"
      printf 'added fetch refspec: %s\n' "$branch"
    fi
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)
}

# --- CWD Inference ---

# A repo name is a pool directory basename, never a path. Callers build
# destructive targets by concatenation ($root/.repos/$name), so a traversing
# name ('../<ws>/<repo>') would point the pool operation at a workspace
# worktree instead — check the argument, not just whether the path it lands on
# happens to exist.
# The charset is GitHub's own ([A-Za-z0-9._-]): slashes and spaces are not
# legal remote repo names either. Two GitHub-legal shapes stay rejected on
# purpose: a leading '.' (pool loops glob .repos/*/, which skips hidden dirs)
# and a leading '-' (indistinguishable from an option flag in any argv slot).
orbit_valid_repo_name() {
  local name="$1"
  case "$name" in
    ''|.*|-*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

orbit_require_repo_name() {
  orbit_valid_repo_name "$1" || orbit_fail "invalid repo name: $1 (expected a pool repo basename: [A-Za-z0-9._-], no leading '.' or '-')"
}

orbit_infer_workspace() {
  local root="$1" cwd rel first
  # Physical paths on both sides: a cwd reached through a symlink (macOS
  # /tmp -> /private/tmp) shares no prefix with the logical root, and every
  # command that infers its workspace would refuse to work there. This is also
  # what keeps inference and the root-only guards answering the same question
  # the same way.
  cwd=$(pwd -P)
  root=$(cd "$root" 2>/dev/null && pwd -P) || root="$1"
  case "$cwd" in
    "$root") orbit_fail "cannot infer workspace from project root; cd into a workspace first"; return 1 ;;
    "$root"/*) ;;
    *) orbit_fail "CWD is not under project root"; return 1 ;;
  esac
  rel="${cwd#"$root/"}"
  first="${rel%%/*}"
  if orbit_reserved_workspace "$first"; then
    orbit_fail "cannot infer workspace: '$first' is reserved"
    return 1
  fi
  printf '%s\n' "$first"
}

# True when the CWD is inside some workspace (the project root itself and
# reserved dirs are not). Delegates to orbit_ws_containing_dir so the cwd guard
# and the ancestry guard answer "what counts as a workspace" with one rule.
# The comparison is on physical paths, because a cwd reached through a symlink
# (macOS /tmp -> /private/tmp) fails a logical prefix match, and an isolation
# guard that silently does not fire is the bug class this whole family of checks
# exists to prevent — which is also why an unreadable cwd answers "inside":
# a deleted working directory cannot be proven to be outside a workspace, and
# guessing "outside" is exactly the silent non-firing to avoid. The refusal that
# follows names the project root, which is the fix for a deleted cwd anyway.
orbit_cwd_inside_workspace() {
  local cwd
  cwd=$(pwd -P 2>/dev/null) || return 0
  orbit_ws_containing_dir "$1" "$cwd" >/dev/null
}

orbit_infer_repo() {
  local root="$1" ws="$2" cwd rel repo_name ws_dir
  # Physical on both sides, same reason as orbit_infer_workspace.
  cwd=$(pwd -P)
  ws_dir=$(cd "$root/$ws" 2>/dev/null && pwd -P) || ws_dir="$root/$ws"
  case "$cwd" in
    "$ws_dir") return 1 ;;
    "$ws_dir"/*) ;;
    *) return 1 ;;
  esac
  rel="${cwd#"$ws_dir/"}"
  repo_name="${rel%%/*}"
  if [ -d "$root/$ws/$repo_name/.git" ] || [ -f "$root/$ws/$repo_name/.git" ]; then
    printf '%s\n' "$repo_name"
    return 0
  fi
  return 1
}

# --- Process Ancestry ---

# Ancestor cwds are a property of this process, not of any candidate: collect
# them once per run. Re-walking per candidate costs a ps + lsof round-trip per
# ancestor on macOS, which scales with the number of workspaces for no gain.
ORBIT_ANCESTRY_CACHED=0
ORBIT_ANCESTOR_CWDS=""

# Print the cwd of a process; nothing if unreadable (exited, permissions).
# On hosts with neither /proc nor lsof this prints nothing for every pid and
# session detection degrades to the root-level guard — orbit doctor warns.
# `|| true` keeps the function safe under set -e in any calling context.
orbit_process_cwd() {
  local pid="$1"
  if [ -d "/proc/$pid" ]; then
    readlink "/proc/$pid/cwd" 2>/dev/null || true
  elif command -v lsof >/dev/null 2>&1; then
    lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk '/^n\//{print substr($0,2); exit}' || true
  fi
}

# Print a process's parent pid. Prefers /proc (no external command, and works
# where busybox ps lacks -o); falls back to ps. In /proc/<pid>/stat the comm
# field can itself contain spaces and parens, so fields are read after the last
# ')': state, then ppid.
orbit_process_ppid() {
  local pid="$1" stat rest
  if [ -r "/proc/$pid/stat" ]; then
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || stat=""
    if [ -n "$stat" ]; then
      rest=${stat##*') '}
      # shellcheck disable=SC2086  # deliberate word split into positionals
      set -- $rest
      [ "$#" -ge 2 ] && { printf '%s\n' "$2"; return 0; }
    fi
  fi
  ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true
}

# Walk the ppid chain once and cache every readable ancestor cwd.
# Announces its own blind spot: if not a single ancestor cwd could be read, the
# guard cannot see anything, and a guard that silently does nothing is how the
# original incident happened. The check is on the *result*, not on which
# facility is present — a host can have /proc yet no usable ps, and vice versa.
orbit_collect_ancestor_cwds() {
  [ "$ORBIT_ANCESTRY_CACHED" = "1" ] && return 0
  ORBIT_ANCESTRY_CACHED=1
  local pid cwd depth=0
  pid=$(orbit_process_ppid $$)
  # Cap the walk at 32 ancestors: deep enough for any realistic shell/agent
  # stack, and bounds the loop should ps ever report a cyclic ppid chain.
  # Ancestors beyond the cap are (deliberately) not checked.
  while [ "$depth" -lt 32 ]; do
    case "$pid" in ''|*[!0-9]*|0|1) break ;; esac
    cwd=$(orbit_process_cwd "$pid")
    if [ -n "$cwd" ]; then
      ORBIT_ANCESTOR_CWDS="$ORBIT_ANCESTOR_CWDS$cwd
"
    fi
    pid=$(orbit_process_ppid "$pid")
    depth=$((depth + 1))
  done
  if [ -z "$ORBIT_ANCESTOR_CWDS" ]; then
    printf 'orbit: cannot read process ancestry on this host: the initiation guard is inactive\n' >&2
  fi
}

# Return 0 if any ancestor process has its cwd inside $1.
# The invoking shell's cwd is agent-controllable (cd), so "is this session
# rooted in <dir>" must be checked on the process tree — a shell can cd out,
# but the session's ancestor chain keeps its launch cwd. Positive match only:
# unreadable cwds are skipped and the walk continues.
orbit_session_workspace() {
  local root="$1" cwd ws
  # orbit_ws_containing_dir physical-normalizes each ancestor cwd itself
  # (lsof//proc report resolved paths).
  orbit_collect_ancestor_cwds
  [ -n "$ORBIT_ANCESTOR_CWDS" ] || return 1
  while IFS= read -r cwd; do
    [ -n "$cwd" ] || continue
    if ws=$(orbit_ws_containing_dir "$root" "$cwd"); then
      printf '%s\n' "$ws"
      return 0
    fi
  done <<EOF
$ORBIT_ANCESTOR_CWDS
EOF
  return 1
}

# Shared guard for destructive root-scoped operations (prune, sync --force /
# --branch). One rule: the invocation must come from a process tree standing
# entirely outside every workspace.
#   $1 root  $2 subcommand name (replay prefix)  $3 display name (message
#   prefix, may name flags)  $4+ original args (for the cd replay)
# Refuses (orbit_fail + return 1) when blocked; returns 0 when it may proceed.
# Every failure path returns explicitly rather than leaning on the caller's
# set -e, so the guard stays correct even if a future caller invokes it in a
# condition context (which would disable set -e for its whole body).
orbit_require_root_scope() {
  local root="$1" subcmd="$2" display="$3"
  shift 3
  local ws_hit

  # Walk the ancestry HERE, in this shell. orbit_session_workspace is called in
  # a command substitution below, and a subshell's assignments never reach the
  # caller — reading ORBIT_ANCESTOR_CWDS after it would always see the empty
  # initial value and mistake a readable ancestry for a blind one. Collecting
  # first also lets the subshell inherit the cache: one walk, one blind-spot
  # warning.
  orbit_collect_ancestor_cwds

  # Primary, target-independent guard: any ancestor process rooted inside any
  # workspace aborts the whole invocation. A parent's cwd can't be cd'd away,
  # so there is no remedy to offer — state the fact and stop.
  if ws_hit=$(orbit_session_workspace "$root"); then
    orbit_fail "$display should not be initiated from inside workspace $ws_hit"
    return 1
  fi

  # Fallback guard: orbit's own cwd is misplaced into a workspace.
  if orbit_cwd_inside_workspace "$root"; then
    # Replay the intended command ONLY when the ancestry actually ran and came
    # back clean (ORBIT_ANCESTOR_CWDS populated above). When it was blind (no
    # readable ancestor cwd), we cannot vouch the session isn't rooted in a
    # workspace, so handing back a ready-to-run `cd <root> && orbit ...` could
    # walk the operator straight into deleting the live workspace they are in
    # — give the fact only.
    if [ -z "$ORBIT_ANCESTOR_CWDS" ]; then
      orbit_fail "$display must be run from the project root"
      return 1
    fi
    local replay="" arg
    for arg in "$@"; do replay="$replay $(printf '%q' "$arg")"; done
    orbit_fail "$display must be run from the project root — cd $(printf '%q' "$root") && orbit $subcmd$replay"
    return 1
  fi

  return 0
}

orbit_ensure_workspace_orbit() {
  local ws_dir="$1"
  local orbit_file="$ws_dir/.orbit"
  if [ ! -f "$orbit_file" ]; then
    local now
    now=$(date +%s)
    git config --file "$orbit_file" workspace.created "$now"
  fi
}

# Memo card line bounds (project config on .repos/.orbit; not shell env — memo
# is project-level state). minLines = soft lower bound (gap/thin floor): below
# it a card isn't real yet. maxLines = hard upper bound (compress/curate ceiling
# + README-fallback cap): above it, curate instead of appending.
orbit_memo_min() {
  local root="$1" v
  v=$(git config --file "$root/.repos/.orbit" --get memo.minLines 2>/dev/null || true)
  case "$v" in ''|*[!0-9]*) v=4 ;; esac
  printf '%s' "$v"
}
orbit_memo_max() {
  local root="$1" v
  v=$(git config --file "$root/.repos/.orbit" --get memo.maxLines 2>/dev/null || true)
  case "$v" in ''|*[!0-9]*) v=16 ;; esac
  printf '%s' "$v"
}

# Over-budget threshold = maxLines + minLines. A card past the hard ceiling
# by more than the min-floor buffer is genuinely bloated; best-effort curation
# that lands slightly over the ceiling stays under this line and is left alone.
orbit_memo_overlong_threshold() {
  local root="$1"
  printf '%s' "$(( $(orbit_memo_max "$root") + $(orbit_memo_min "$root") ))"
}

# A memo is "thin" (missing or low-quality) if the file is absent or has fewer
# than memo.minLines non-blank lines. Conservative on purpose: only flags
# genuinely empty/stub cards that still need a real pull-decision card written.
orbit_memo_is_thin() {
  local md_file="$1" root="$2"
  [ -f "$md_file" ] || return 0
  local n min
  n=$(grep -c '[^[:space:]]' "$md_file" 2>/dev/null || echo 0)
  min=$(orbit_memo_min "$root")
  [ "$n" -lt "$min" ]
}

# Cold-start exploration scope for writing a memo card: a comma-delimited list
# of <path>:<depth> entries (project config; default the repo root at depth 1).
# One global knob, consumed only at first `orbit add` of a repo; afterward the
# jot -> incremental-memo pipeline maintains the card. Doc-format agnostic —
# orbit attaches no meaning to what lives at the paths.
orbit_explore_paths() {
  local root="$1" v
  v=$(git config --file "$root/.repos/.orbit" --get explore.paths 2>/dev/null || true)
  [ -n "$v" ] || v=".:1"
  printf '%s' "$v"
}

# Render the stored path:depth list as human text so a reader need not know the
# convention: ".:1,src:2" -> ". (depth 1), src (depth 2)".
orbit_explore_paths_human() {
  local raw out="" entry path depth
  raw=$(orbit_explore_paths "$1")
  local oldifs="$IFS"; IFS=,
  for entry in $raw; do
    IFS="$oldifs"
    path="${entry%%:*}"; depth="${entry##*:}"
    [ -n "$out" ] && out="$out, "
    out="$out$path (depth $depth)"
    IFS=,
  done
  IFS="$oldifs"
  printf '%s' "$out"
}

# Jot aggregation buffer (project config on .repos/.orbit): a repo that has
# accumulated enough jots to fill a minimum memo should aggregate them into the
# card. Defaults to memo.minLines; follows it unless explicitly set.
orbit_jot_buffer_size() {
  local root="$1" v
  v=$(git config --file "$root/.repos/.orbit" --get jot.bufferSize 2>/dev/null || true)
  case "$v" in ''|*[!0-9]*) v=$(orbit_memo_min "$root") ;; esac
  printf '%s' "$v"
}

# Jot warn level for a count given the buffer size: building | overflow | none.
# Silent at or below bufferSize/2; building up to bufferSize; overflow past it.
orbit_jot_level() {
  local count="$1" buf="$2"
  local half=$(( buf / 2 ))
  if [ "$count" -gt "$buf" ]; then printf 'overflow'
  elif [ "$count" -gt "$half" ]; then printf 'building'; fi
}

# Memo state for context/status purposes: thin | ok | over.
# thin = missing or fewer than memo.minLines non-blank lines (no real card yet);
# over = more than maxLines+minLines non-blank lines (over budget, curate once).
orbit_memo_state() {
  local md_file="$1" root="$2" n min over_t
  [ -f "$md_file" ] || { printf 'thin'; return; }
  n=$(grep -c '[^[:space:]]' "$md_file" 2>/dev/null || echo 0)
  min=$(orbit_memo_min "$root")
  over_t=$(orbit_memo_overlong_threshold "$root")
  if [ "$n" -lt "$min" ]; then printf 'thin'
  elif [ "$n" -gt "$over_t" ]; then printf 'over'
  else printf 'ok'; fi
}

# Print the worktree's upstream tracking state: "untracked" when the branch has
# no upstream (raw-mode branch pushed without `git fetch origin <branch>` —
# cruise block surfaces this so the agent knows to fetch), a number when behind,
# or empty when tracked and up-to-date. Uses local refs only — never fetches.
orbit_repo_upstream_behind() {
  local wt_dir="$1" upstream behind
  # See orbit_status: a failing rev-parse can still print '@{upstream}' —
  # gate on the exit code, not on the captured text.
  if ! upstream=$(git -C "$wt_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null); then
    upstream=""
  fi
  if [ -z "$upstream" ]; then
    printf 'untracked'
    return 0
  fi
  behind=$(git -C "$wt_dir" rev-list --count "HEAD..${upstream}" 2>/dev/null || echo 0)
  [ "$behind" = "0" ] && behind=""
  printf '%s' "$behind"
}

# Per-repo status for a workspace, one line per worktree repo (unfiltered):
#   <name>|<jot_count>|<jot_level>|<behind>|<memo_state>|<branch>|<is_scoped>
# jot_level: building|overflow (empty when count <= bufferSize/2);
# behind: commits behind the worktree branch's @{upstream}, "untracked" when
# no upstream (raw-mode), or empty when tracked and up-to-date;
# memo_state: ok|thin|over (see orbit_memo_state);
# branch: the worktree's current branch name (for the untracked hint);
# is_scoped: 1 when branch name starts with ws/<workspace>/ (scoped mode),
# 0 otherwise (raw mode — recommend orbit switch -c to convert).
# Shared by `orbit context` (cruise/reignite blocks) and `orbit done`.
orbit_collect_repo_status() {
  local root="$1" ws_dir="$2"
  local orbit_file="$ws_dir/.orbit"
  local buf
  buf=$(orbit_jot_buffer_size "$root")
  local ws_name
  ws_name=$(basename "$ws_dir")
  local d name branch count level behind mstate is_scoped
  for d in "$ws_dir"/*/; do
    [ -d "$d" ] || continue
    [ -d "$d/.git" ] || [ -f "$d/.git" ] || continue
    name=$(basename "$d")
    branch=$(git -C "$d" branch --show-current 2>/dev/null || echo "detached")
    case "$branch" in
      ws/"$ws_name"/*) is_scoped=1 ;;
      *) is_scoped=0 ;;
    esac
    count=$(git config --file "$orbit_file" --get-all "jot.$name.entry" 2>/dev/null | grep -c . || true)
    [ -n "$count" ] || count=0
    level=$(orbit_jot_level "$count" "$buf")
    behind=$(orbit_repo_upstream_behind "$d")
    mstate=$(orbit_memo_state "$root/.repos/.$name.md" "$root")
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$name" "$count" "$level" "$behind" "$mstate" "$branch" "$is_scoped"
  done
}

# --- Brief Extraction ---

orbit_brief_extract() {
  local file="$1"
  [ -e "$file" ] || [ "$file" = "/dev/stdin" ] || return 1
  local line found=""
  # State for multi-line constructs common in GitHub READMEs:
  #   in_fence   — the opening fence marker (``` or ~~~), empty when outside
  #   in_comment — inside a multi-line <!-- --> comment
  #   in_tag     — inside a multi-line HTML tag (<img ...\n src="..."\n width="50%">)
  #   html_stack — open non-void HTML blocks (<p align="center"> … </p>)
  #   html_lines — lines spent inside html_stack; an unclosed block is common
  #     in hand-written README HTML, so after a budget we drop the stack and
  #     resume normal scanning instead of swallowing the rest of the file
  local in_fence="" in_comment=0 in_tag=0 html_stack="" html_lines=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"

    if [ "$in_comment" = "1" ]; then
      case "$line" in *'-->'*) in_comment=0 ;; esac
      continue
    fi
    if [ "$in_tag" = "1" ]; then
      case "$line" in *'>'*) in_tag=0 ;; esac
      continue
    fi
    case "$line" in
      '```'*|'~~~'*)
        # Typed fences: only the same fence type closes the block, so a ~~~
        # line inside a ``` fence (or vice versa) is content, not a toggle.
        if [ -n "$in_fence" ]; then
          case "$line" in "$in_fence"*) in_fence="" ;; esac
        else
          in_fence="${line:0:3}"
        fi
        continue ;;
    esac
    [ -n "$in_fence" ] && continue
    if [ -n "$html_stack" ]; then
      html_lines=$((html_lines + 1))
      if [ "$html_lines" -gt 50 ]; then
        html_stack="" html_lines=0
      else
        local top="${html_stack##* }"
        case "$line" in
          '</'"$top"'>'*)
            html_stack="${html_stack% *}"
            [ -z "$html_stack" ] && html_lines=0 ;;
        esac
        continue
      fi
    fi

    case "$line" in
      ''|'#'*) continue ;;
      '['*|'!['*) continue ;;        # badges, link-only/nav lines
      '* '*|'- '*|[0-9]*'. '*) continue ;;
      '---'*|'***'*|'==='*) continue ;;
      '<!--'*)
        case "$line" in *'-->'*) ;; *) in_comment=1 ;; esac
        continue ;;
    esac
    case "$line" in
      '<'[a-zA-Z]*)
        # no '>' on the line → multi-line tag, skip until it closes
        case "$line" in *'>'*) ;; *) in_tag=1; continue ;; esac
        local tag
        tag="${line#<}"
        tag="${tag%% *}"
        tag="${tag%%>*}"
        case "$tag" in
          # void elements never open a block
          img|br|hr|source|input|meta|link|area|base|col|embed|track|wbr) ;;
          *)
            # inline-closed (<h2>Text</h2>) or self-closing (<br/>) don't open
            case "$line" in
              *'/>'*|*'</'"$tag"'>'*) ;;
              *) html_stack="$html_stack $tag" ;;
            esac ;;
        esac
        continue ;;
      '</'[a-zA-Z]*) continue ;;
    esac

    line="${line#> }"
    if [ ${#line} -gt 120 ]; then
      line="${line:0:120}"
      line="${line% *}"
    fi
    printf '%s\n' "$line"
    found=1
    break
  done < "$file"
  [ -n "$found" ]
}

# Resolve a pool repo's display brief via the shared fallback model
# (docs/spec-metadata.md "Fallback Rules"): index cache → memo file → README.
# README/memo fallbacks are display-only and never written back to the index.
# Prints two lines: the resolved brief (possibly empty) and the source tag
# (index|memo|readme|none). Presentation is the caller's job — `orbit repos`
# renders steering notes on stderr (human terminal), while the
# `orbit context --startup` prime roster inlines them as stdout sections
# (hook injection only carries stdout).
orbit_pool_brief() {
  local root="$1" index="$2" name="$3" repo_dir="$4"
  local brief
  brief=$(git config --file "$index" --get "repos.$name.brief" 2>/dev/null || true)
  if [ -n "$brief" ]; then
    printf '%s\nindex\n' "$brief"
    return 0
  fi

  local md_file="$root/.repos/.$name.md"
  if [ -f "$md_file" ]; then
    brief=$(orbit_brief_extract "$md_file" || true)
    if [ -n "$brief" ]; then
      printf '%s\nmemo\n' "$brief"
      return 0
    fi
  fi

  local readme="" f
  for f in "$repo_dir/README.md" "$repo_dir/README" "$repo_dir/readme.md"; do
    if [ -f "$f" ]; then readme="$f"; break; fi
  done
  if [ -n "$readme" ]; then
    brief=$(orbit_brief_extract "$readme" || true)
    if [ -n "$brief" ]; then
      printf '%s\nreadme\n' "$brief"
      return 0
    fi
  fi

  printf '\nnone\n'
}

# --- Staleness Check ---

orbit_staleness_check() {
  local repo_name="$1" root="$2"
  local index="$root/.repos/.orbit"
  local repo_dir="$root/.repos/$repo_name"
  [ -f "$index" ] || return 0
  local stored current
  stored=$(git config --file "$index" --get "repos.$repo_name.head" 2>/dev/null || true)
  [ -n "$stored" ] || return 0
  [ -f "$root/.repos/.$repo_name.md" ] || return 0
  current=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)
  [ -n "$current" ] || return 0
  if [ "$stored" != "$current" ]; then
    local distance
    distance=$(git -C "$repo_dir" rev-list "$stored".."$current" --count 2>/dev/null || echo "?")
    printf 'orbit: %s memo is %s commits behind HEAD: skim the changes, then update memo %s, or run memo %s --refresh if structure is unchanged\n' \
      "$repo_name" "$distance" "$repo_name" "$repo_name" >&2
  fi
}

orbit_upstream_check() {
  local repo_name="$1" root="$2"
  local repo_dir="$root/.repos/$repo_name"
  local branch
  branch=$(orbit_default_branch "$repo_dir" 2>/dev/null) || return 0
  local local_head remote_head
  local_head=$(git -C "$repo_dir" rev-parse "refs/heads/$branch" 2>/dev/null) || return 0
  remote_head=$(git -C "$repo_dir" rev-parse "refs/remotes/origin/$branch" 2>/dev/null) || return 0
  if [ "$local_head" != "$remote_head" ]; then
    local distance
    distance=$(git -C "$repo_dir" rev-list "$local_head".."$remote_head" --count 2>/dev/null || echo "?")
    printf 'orbit: %s has %s new commits on origin/%s: run sync %s before you add or rely on it\n' \
      "$repo_name" "$distance" "$branch" "$repo_name" >&2
  fi
}

# --- JSON Output ---

orbit_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\x08'/\\b}"
  s="${s//$'\x0c'/\\f}"
  s=$(printf '%s' "$s" | tr -d '\001-\007\013\016-\037')
  printf '%s' "$s"
}

orbit_json_kv() {
  local key="$1" value="$2"
  printf '"%s":"%s"' "$key" "$(orbit_json_escape "$value")"
}

orbit_json_kv_raw() {
  # For values that are already valid JSON (numbers, booleans, arrays, objects)
  local key="$1" value="$2"
  printf '"%s":%s' "$key" "$value"
}

# --- Commands ---

orbit_clone() {
  [ "$#" -ge 1 ] || orbit_fail "usage: orbit clone <url> [--push <fork-url>] [--name <repo>] [--branch <branch>]"

  local remote="$1" repo_name="" branch="" push_url=""
  shift

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) [ "$#" -ge 2 ] || orbit_fail "--name requires a value"; repo_name="$2"; shift 2 ;;
      --branch) [ "$#" -ge 2 ] || orbit_fail "--branch requires a value"; branch="$2"; shift 2 ;;
      --push) [ "$#" -ge 2 ] || orbit_fail "--push requires a value"; push_url="$2"; shift 2 ;;
      *) orbit_fail "unknown option: $1" ;;
    esac
  done

  local root
  root=$(orbit_ensure_init)

  if [ -z "$repo_name" ]; then
    repo_name=$(orbit_repo_basename "$remote") || return 1
    # A URL basename outside the name contract (e.g. an org's .github repo) is
    # not a dead end — the repo just needs a pool identity picked by hand.
    orbit_valid_repo_name "$repo_name" || orbit_fail "cannot use URL basename as repo name: $repo_name (pick a pool name with --name)"
  fi
  orbit_require_repo_name "$repo_name"

  local dst="$root/.repos/$repo_name"
  [ ! -e "$dst" ] || orbit_fail "repo already exists: $repo_name"

  if [ -n "$branch" ]; then
    git clone --single-branch --branch "$branch" "$remote" "$dst"
  else
    git clone --single-branch "$remote" "$dst"
  fi

  git -C "$dst" config push.default upstream
  # Let a bare `git push` on a fresh raw-mode branch create origin/<branch> and set
  # tracking (git >= 2.37). Without it, push.default=upstream makes bare push error on
  # a branch with no upstream. Older git silently ignores this key (no-op).
  git -C "$dst" config push.autoSetupRemote true

  if [ -n "$push_url" ]; then
    git -C "$dst" remote set-url --push origin "$push_url"
  fi

  local index="$root/.repos/.orbit"

  local url head
  url=$(git -C "$dst" remote get-url origin)
  head=$(git -C "$dst" rev-parse HEAD 2>/dev/null) || head="-"
  git config --file "$index" "repos.$repo_name.url" "$url"
  git config --file "$index" "repos.$repo_name.head" "$head"

  local cloned_branch
  cloned_branch=$(git -C "$dst" symbolic-ref --short HEAD 2>/dev/null || echo "unknown")
  printf 'cloned %s (default branch: %s)\n' "$repo_name" "$cloned_branch"
  printf 'next: orbit new "<goal>", then orbit add %s\n' "$repo_name"
}

orbit_new() {
  local goal="" name="" exec_cmd="" no_goal=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) [ "$#" -ge 2 ] || orbit_fail "--name requires a value"; name="$2"; shift 2 ;;
      --exec) [ "$#" -ge 2 ] || orbit_fail "--exec requires a value"; exec_cmd="$2"; shift 2 ;;
      --no-goal) no_goal=true; shift ;;
      -*) orbit_fail "unknown option: $1" ;;
      *)
        if [ -z "$goal" ]; then
          goal="$1"
        else
          orbit_fail "unexpected argument: $1"
        fi
        shift
        ;;
    esac
  done

  if [ "$no_goal" = true ]; then
    [ -z "$goal" ] || orbit_fail "--no-goal cannot be combined with a goal argument"
  elif [ -z "$goal" ]; then
    local use_editor=false
    if [ -n "${ORBIT_EDITOR:-}" ]; then
      use_editor=true
    elif [ -t 0 ]; then
      use_editor=true
    fi

    if [ "$use_editor" = true ]; then
      local tmpf
      tmpf=$(mktemp "${TMPDIR:-/tmp}/orbit-goal-XXXXXX")
      local pidx=$(( RANDOM % ${#ORBIT_NEW_PROMPTS[@]} ))
      printf '\n# %s\n# Lines starting with # are ignored. Empty goal aborts.\n' "${ORBIT_NEW_PROMPTS[$pidx]}" > "$tmpf"
      local editor="${ORBIT_EDITOR:-${VISUAL:-${EDITOR:-vi}}}"
      "$editor" "$tmpf" </dev/tty >/dev/tty 2>/dev/null || "$editor" "$tmpf"
      goal=$(awk '/^#/{next} {lines[++n]=$0} END{s=1;e=n; while(s<=e && lines[s]=="")s++; while(e>=s && lines[e]=="")e--; for(i=s;i<=e;i++)print lines[i]}' "$tmpf")
      rm -f "$tmpf"
    else
      goal=$(cat)
    fi
    [ -n "$goal" ] || orbit_fail "aborting: empty goal"
  fi

  local root
  root=$(orbit_ensure_init)

  if [ -z "$name" ]; then
    local max=0 n
    for d in "$root"/task-*/ ; do
      [ -d "$d" ] || continue
      n="${d%/}"
      n="${n##*task-}"
      if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$max" ]; then
        max="$n"
      fi
    done
    name=$(printf 'task-%02d' $((max + 1)))
  fi

  if orbit_reserved_workspace "$name"; then
    orbit_fail "invalid workspace name: $name"
  fi

  # Workspace name must be valid for scoped-mode branch names (ws/<workspace>/<name>).
  # git branch ref rules: no space, ~, ^, :, ?, *, [, \; no leading/trailing dot or slash;
  # no consecutive dots or slashes; no control chars; length limit (leave room for
  # ws/<workspace>/ prefix + branch name, keep total < 255).
  if [ "${#name}" -gt 50 ]; then
    orbit_fail "workspace name too long (${#name} chars, max 50): $name"
  fi
  case "$name" in
    *[[:space:]~^:?*[\\]]* | .* | */ | *..* | *//* )
      orbit_fail "invalid workspace name (git branch ref rules): $name" ;;
  esac

  local ws_dir="$root/$name"
  [ ! -e "$ws_dir" ] || orbit_fail "workspace already exists: $name"

  mkdir -p "$ws_dir"
  local now
  now=$(date +%s)
  if [ -n "$goal" ]; then
    git config --file "$ws_dir/.orbit" workspace.goal "$goal"
  fi
  git config --file "$ws_dir/.orbit" workspace.created "$now"

  local cd_target
  if [ "$PWD" = "$root" ]; then
    cd_target="$name"
  else
    cd_target="$ws_dir"
  fi

  printf 'created workspace: %s\n' "$name"
  if [ -n "$goal" ]; then
    printf '\n  "%s"\n' "$goal"
  fi

  if [ -n "$exec_cmd" ]; then
    orbit_random_msg ORBIT_NEW_FAREWELLS
    (cd "$ws_dir" && sh -c "$exec_cmd")
  else
    local agent_exec
    agent_exec=$(git config --file "$root/.repos/.orbit" --get agent.recommend 2>/dev/null || true)
    if [ -n "$agent_exec" ]; then
      printf '\nget started:\n'
      printf '\n  cd %s && %s\n' "$cd_target" "$agent_exec"
    else
      printf '\nenter workspace:\n'
      printf '\n  cd %s\n' "$cd_target"
    fi
    orbit_random_msg ORBIT_NEW_FAREWELLS
  fi
}

orbit_add() {
  local repo_name="" target_ref="" silent=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ref)
        [ "$#" -ge 2 ] || orbit_fail "usage: orbit add <repo> [--ref <tag/branch>] [-s|--silent]"
        target_ref="$2"; shift 2 ;;
      -s|--silent)
        silent=1; shift ;;
      -*)
        orbit_fail "usage: orbit add <repo> [--ref <tag/branch>] [-s|--silent]" ;;
      *)
        [ -z "$repo_name" ] || orbit_fail "usage: orbit add <repo> [--ref <tag/branch>] [-s|--silent]"
        repo_name="$1"; shift ;;
    esac
  done
  [ -n "$repo_name" ] || orbit_fail "usage: orbit add <repo> [--ref <tag/branch>] [-s|--silent]"
  orbit_require_repo_name "$repo_name"

  local root
  root=$(orbit_require_root) || return 1

  local ws
  ws=$(orbit_infer_workspace "$root") || return 1

  local ws_status
  ws_status=$(git config --file "$root/$ws/.orbit" --get workspace.status 2>/dev/null || true)
  if [ "$ws_status" = "done" ]; then
    printf 'orbit: workspace %s is marked done and prune-eligible: reactivate it with goal "<text>" before resuming work\n' "$ws" >&2
  fi

  local repo_dir="$root/.repos/$repo_name"
  [ -d "$repo_dir" ] || orbit_fail "repo not in pool: $repo_name (use 'orbit clone' first)"

  local ws_dir="$root/$ws"
  local dst="$ws_dir/$repo_name"
  [ ! -e "$dst" ] || orbit_fail "worktree already exists: $ws/$repo_name"

  # Empty-repo bootstrap: no commits yet → create an orphan-branch worktree
  # so the user can author the first commit.
  if [ -z "$target_ref" ] && ! git -C "$repo_dir" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    orbit_git_supports_orphan_worktree || orbit_fail "$repo_name is an empty repo; bootstrapping the first commit needs git >= 2.42 (you have $(git --version | awk '{print $3}')). Upgrade git, or push an initial commit to the remote first."
    local empty_default empty_branch
    empty_default=$(git -C "$repo_dir" symbolic-ref --short HEAD 2>/dev/null || echo main)
    empty_branch=$(orbit_tracking_branch "$ws" "$empty_default") || return 1
    git -C "$repo_dir" worktree add --orphan -b "$empty_branch" "$dst"
    orbit_set_upstream "$dst" "$empty_branch" "$empty_default"
    orbit_ensure_workspace_orbit "$ws_dir"
    printf 'added %s → %s/%s (branch: %s, EMPTY repo — author the first commit here, then: git push)\n' \
      "$repo_name" "$ws" "$repo_name" "$empty_branch"
    return 0
  fi

  local default_branch
  default_branch=$(orbit_default_branch "$repo_dir") || return 1

  local checkout_target local_branch
  if [ -n "$target_ref" ]; then
    # --ref mode: fetch specified ref
    git -C "$repo_dir" fetch origin "$target_ref" 2>/dev/null || orbit_fail "$repo_name: cannot fetch ref: $target_ref"
    checkout_target="FETCH_HEAD"
  else
    # Default mode: checkout default branch
    orbit_ensure_remote_branch "$repo_dir" "$default_branch"
    checkout_target="origin/$default_branch"
  fi

  local_branch=$(orbit_tracking_branch "$ws" "$default_branch") || return 1

  if git -C "$repo_dir" rev-parse --verify --quiet "refs/heads/$local_branch" >/dev/null 2>&1; then
    if orbit_branch_is_checked_out_elsewhere "$repo_dir" "$local_branch"; then
      orbit_fail "branch already checked out: $local_branch"
    fi
    git -C "$repo_dir" worktree add "$dst" "$local_branch"
    [ -z "$target_ref" ] || git -C "$dst" reset --hard "$checkout_target" 2>/dev/null
  else
    git -C "$repo_dir" worktree add -b "$local_branch" "$dst" "$checkout_target"
  fi

  # Set upstream for status/ahead-behind visibility; push safety is handled by skill conventions
  orbit_set_upstream "$dst" "$local_branch" "$default_branch"

  orbit_ensure_workspace_orbit "$ws_dir"

  printf 'added %s → %s/%s (branch: %s, upstream: origin/%s)\n' "$repo_name" "$ws" "$repo_name" "$local_branch" "$default_branch"

  local explore_paths
  explore_paths=$(orbit_explore_paths_human "$root")

  # Surface the memo so agents that skipped `orbit info` still get repo context.
  # A well-behaved agent that already ran `orbit info` passes -s to suppress this.
  if [ "$silent" -eq 0 ]; then
    # Raw-mode tracking limitation: the pool is a single-branch clone, so a branch
    # you create with `git checkout -b <name>` and push won't show remote tracking
    # in `git status` / `@{upstream}` until `git fetch origin <name>` materializes
    # the ref. `orbit switch -c <name>` (scoped) wires tracking up front.
    printf 'orbit: raw-mode branches (git checkout -b) stay untracked under the single-branch pool: run git fetch origin <branch> after pushing, or use switch -c <name> to wire the upstream config up front (the tracking ref materializes at the next sync/info/session start)\n' >&2
    local md_file="$root/.repos/.$repo_name.md"
    if [ -f "$md_file" ]; then
      printf -- '--- memo: %s (pass -s to suppress) ---\n' "$repo_name" >&2
      cat "$md_file" >&2
      # Thin card: nudge a proper exploration at this high-attention moment.
      # This stderr is the explore.paths carrier (bounded cold-start scope).
      if orbit_memo_is_thin "$md_file" "$root"; then
        printf 'orbit: memo for %s is thin: explore %s and expand it into a pull-decision card (roles + how to use) with memo %s before done (pass -s to suppress)\n' \
          "$repo_name" "$explore_paths" "$repo_name" >&2
      fi
    else
      printf 'orbit: no memo for %s: explore %s and write a pull-decision card (roles + how to use), then write it with memo %s before done (pass -s to suppress)\n' "$repo_name" "$explore_paths" "$repo_name" >&2
    fi
  fi
}

orbit_switch() {
  local create_mode=0 args=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -c) create_mode=1; shift ;;
      -*) orbit_fail "unknown option: $1" ;;
      *) args+=("$1"); shift ;;
    esac
  done

  [ "${#args[@]}" -ge 1 ] || orbit_fail "usage: orbit switch [-c] [repo] <name>"

  local root ws repo_name branch_name
  root=$(orbit_require_root) || return 1
  ws=$(orbit_infer_workspace "$root") || return 1

  if [ "${#args[@]}" -eq 2 ]; then
    repo_name="${args[0]}"
    branch_name="${args[1]}"
  elif [ "${#args[@]}" -eq 1 ]; then
    branch_name="${args[0]}"
    repo_name=$(orbit_infer_repo "$root" "$ws") || orbit_fail "multiple repos in workspace, specify which one: orbit switch [-c] <repo> <name>"
  else
    orbit_fail "usage: orbit switch [-c] [repo] <name>"
  fi

  local repo_dir="$root/.repos/$repo_name"
  [ -d "$repo_dir" ] || orbit_fail "repo not in pool: $repo_name"

  local wt_path="$root/$ws/$repo_name"
  [ -d "$wt_path" ] || orbit_fail "repo not in workspace: $ws/$repo_name (use 'orbit add' first)"

  local push_default
  push_default=$(git -C "$repo_dir" config --get push.default 2>/dev/null || true)
  if [ "$push_default" != "upstream" ]; then
    git -C "$repo_dir" config push.default upstream
  fi
  if [ "$(git -C "$repo_dir" config --get push.autoSetupRemote 2>/dev/null || true)" != "true" ]; then
    git -C "$repo_dir" config push.autoSetupRemote true
  fi

  local local_branch
  local_branch=$(orbit_tracking_branch "$ws" "$branch_name") || return 1

  if [ "$create_mode" -eq 1 ]; then
    # No pre-creation remote check — git switch -c doesn't check remote either.
    # Push conflict is handled by git when it happens.
    local current
    current=$(git -C "$wt_path" branch --show-current)
    if [ "$current" = "$local_branch" ]; then
      printf 'already on %s\n' "$local_branch"
      return 0
    fi
    git -C "$wt_path" checkout -b "$local_branch"
    orbit_set_upstream "$wt_path" "$local_branch" "$branch_name"
    # Do NOT pre-register a fetch refspec here: an exact refspec for a branch
    # the remote doesn't have yet makes every bare `git fetch` fail until the
    # first push. sync/prune reconciliation registers it once the branch
    # exists remotely (see orbit_reconcile_fetch_refspecs).
    printf '%s: created %s (upstream: origin/%s)\n' "$repo_name" "$local_branch" "$branch_name"

    # Post-creation conflict check: remote already has <name> with different
    # commits → push will conflict. Exempt when transferring a raw-mode branch
    # (current branch name = <name> and no upstream — agent already knows).
    local remote_head local_head current_branch current_upstream
    remote_head=$(git ls-remote --heads origin "$branch_name" 2>/dev/null | awk '{print $1}')
    if [ -n "$remote_head" ]; then
      local_head=$(git -C "$wt_path" rev-parse "refs/heads/$local_branch" 2>/dev/null || true)
      current_branch=$(git -C "$wt_path" branch --show-current 2>/dev/null || true)
      current_upstream=$(git -C "$wt_path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
      if [ -n "$local_head" ] && [ "$remote_head" != "$local_head" ] && \
         { [ "$current_branch" != "$branch_name" ] || [ -n "$current_upstream" ]; }; then
        printf 'orbit: note: remote already has %s with different commits — push will conflict\n' "$branch_name" >&2
      fi
    fi
  else
    if git -C "$repo_dir" rev-parse --verify --quiet "refs/heads/$local_branch" >/dev/null 2>&1; then
      if orbit_branch_is_checked_out_elsewhere "$repo_dir" "$local_branch"; then
        orbit_fail "branch checked out in another worktree: $local_branch"
      fi
      git -C "$wt_path" checkout "$local_branch"
      printf '%s: switched to %s\n' "$repo_name" "$local_branch"
    elif orbit_remote_branch_exists "$repo_dir" "$branch_name"; then
      orbit_ensure_remote_branch "$repo_dir" "$branch_name"
      git -C "$wt_path" checkout -b "$local_branch" "origin/$branch_name"
      orbit_set_upstream "$wt_path" "$local_branch" "$branch_name"
      printf '%s: created %s (upstream: origin/%s)\n' "$repo_name" "$local_branch" "$branch_name"
    else
      orbit_fail "branch not found on remote: origin/$branch_name (use -c to create)"
    fi
  fi
}

orbit_sync_one() {
  local repo_name="$1" root="$2" force="$3" new_branch="$4" ws="${5:-}"
  if ! orbit_valid_repo_name "$repo_name"; then
    printf "orbit: invalid repo name: %s (expected a pool repo basename: [A-Za-z0-9._-], no leading '.' or '-')\n" "$repo_name" >&2
    return 1
  fi
  local repo_dir="$root/.repos/$repo_name"
  [ -d "$repo_dir" ] || { printf 'orbit: %s: repo not in pool, skipping\n' "$repo_name" >&2; return 1; }

  local branch
  branch=$(orbit_default_branch "$repo_dir" 2>/dev/null) || { printf 'orbit: %s: cannot determine default branch (remote is empty or missing origin/HEAD; push an initial commit first)\n' "$repo_name" >&2; return 1; }

  if [ -n "$new_branch" ]; then
    # Retire only the refspec of the branch being replaced. --unset-all would
    # also drop refspecs other workspaces registered for their own branches
    # (breaking every bare fetch in their worktrees) and any user-configured
    # wildcard — neither is this command's to remove.
    orbit_remove_fetch_refspec "$repo_dir" "+refs/heads/$branch:refs/remotes/origin/$branch"
    orbit_add_fetch_refspec "$repo_dir" "$new_branch"
    if ! git -C "$repo_dir" fetch origin "$new_branch" 2>/dev/null; then
      printf 'orbit: %s: cannot fetch branch: %s\n' "$repo_name" "$new_branch" >&2
      # Roll back to the pre-switch refspec set so a failed switch does not
      # leave the pool unable to fetch its previous branch.
      orbit_remove_fetch_refspec "$repo_dir" "+refs/heads/$new_branch:refs/remotes/origin/$new_branch"
      orbit_add_fetch_refspec "$repo_dir" "$branch"
      return 1
    fi
    if git -C "$repo_dir" rev-parse --verify --quiet "refs/heads/$new_branch" >/dev/null 2>&1; then
      git -C "$repo_dir" checkout "$new_branch" 2>/dev/null
    else
      git -C "$repo_dir" checkout -b "$new_branch" "origin/$new_branch" 2>/dev/null
    fi
    git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$new_branch" 2>/dev/null || true
    if [ "$force" -eq 1 ]; then
      git -C "$repo_dir" reset --hard "origin/$new_branch" 2>/dev/null
    fi
    if [ -f "$root/.repos/.$repo_name.md" ]; then
      printf 'orbit: %s: memo may not apply to new branch %s\n' "$repo_name" "$new_branch" >&2
    fi
    printf 'pool: switched %s to branch %s\n' "$repo_name" "$new_branch"
    return 0
  fi

  # Reconcile fetch refspecs first: a stale entry (remote branch deleted, or
  # pre-registered but never pushed) breaks every bare `git fetch` in every
  # worktree of this pool.
  while IFS= read -r line; do
    printf '%s: %s\n' "$repo_name" "$line"
  done < <(orbit_reconcile_fetch_refspecs "$repo_dir" 0)

  # Bare fetch (not `fetch origin $branch`) so refs for refspecs just
  # registered by the reconcile materialize too.
  if ! git -C "$repo_dir" fetch origin 2>/dev/null; then
    printf 'orbit: %s: fetch failed\n' "$repo_name" >&2
    return 1
  fi

  local head_before
  head_before=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)

  if [ "$force" -eq 1 ]; then
    git -C "$repo_dir" reset --hard "origin/$branch" 2>/dev/null
    printf '%s: reset to origin/%s\n' "$repo_name" "$branch"
  else
    if ! git -C "$repo_dir" merge --ff-only "origin/$branch" 2>/dev/null; then
      printf 'orbit: %s: fast-forward failed (local diverged from upstream), use --force to reset the pool checkout (worktrees are untouched)\n' "$repo_name" >&2
      return 1
    fi
    local head_after
    head_after=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)
    if [ "$head_before" = "$head_after" ]; then
      printf '%s: already up to date\n' "$repo_name"
    else
      local n_commits
      n_commits=$(git -C "$repo_dir" rev-list --count "${head_before}..${head_after}" 2>/dev/null || echo '?')
      printf '%s: fast-forwarded %s %s → origin/%s\n' "$repo_name" "$n_commits" "$(orbit_plural "$n_commits" commit commits)" "$branch"
    fi
  fi

  # sync updates the pool repo only. If this workspace has a worktree of this repo
  # tracking the same remote branch we just advanced, it is now behind — hint the pull.
  if [ -n "$ws" ]; then
    local wt="$root/$ws/$repo_name"
    if [ -e "$wt/.git" ]; then
      local wt_up
      wt_up=$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
      if [ "$wt_up" = "origin/$branch" ]; then
        printf 'orbit: %s pool advanced but your worktree (tracking origin/%s) is untouched by sync: pull it with git if you want the new commits\n' "$repo_name" "$branch" >&2
      fi
    fi
  fi
}

orbit_sync() {
  local force=0 new_branch="" repos=()
  local orig_args=("$@")

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      --branch)
        [ "$#" -ge 2 ] || orbit_fail "--branch requires a value"
        new_branch="$2"; shift 2 ;;
      -*) orbit_fail "unknown option: $1" ;;
      *) repos+=("$1"); shift ;;
    esac
  done

  local root
  root=$(orbit_require_root) || return 1

  # Destructive pool operations are root-scoped. --force discards the pool's
  # local commits; --branch re-points the pool's checked-out branch, its
  # origin/HEAD, and the fetch refspecs every workspace's worktrees rely on.
  # Neither destroys anything the calling workspace owns — which is precisely
  # why the call must come from the scope that does own the pool. Bare sync
  # (ff-only) cannot lose data and stays callable from anywhere.
  if [ "$force" -eq 1 ] || [ -n "$new_branch" ]; then
    local scoped_flags=""
    [ "$force" -eq 1 ] && scoped_flags="--force"
    if [ -n "$new_branch" ]; then
      [ -n "$scoped_flags" ] && scoped_flags="$scoped_flags/"
      scoped_flags="$scoped_flags--branch"
    fi
    orbit_require_root_scope "$root" "sync" "sync $scoped_flags" ${orig_args[@]+"${orig_args[@]}"}
  fi

  local ws_ctx=""
  ws_ctx=$(orbit_infer_workspace "$root" 2>/dev/null) || ws_ctx=""
  if [ "${#repos[@]}" -eq 0 ]; then
    local ws repo_name
    if ws=$(orbit_infer_workspace "$root" 2>/dev/null); then
      if repo_name=$(orbit_infer_repo "$root" "$ws" 2>/dev/null); then
        repos+=("$repo_name")
      else
        for d in "$root/$ws"/*/; do
          [ -d "$d" ] || continue
          local name
          name=$(basename "$d")
          if [ -d "$d/.git" ] || [ -f "$d/.git" ]; then
            repos+=("$name")
          fi
        done
      fi
    else
      for d in "$root/.repos"/*/; do
        [ -d "$d" ] || continue
        repos+=("$(basename "$d")")
      done
    fi
  fi

  [ "${#repos[@]}" -gt 0 ] || orbit_fail "no repos to sync"

  local n_ok=0 failed_names=""
  for repo_name in "${repos[@]}"; do
    if orbit_sync_one "$repo_name" "$root" "$force" "$new_branch" "$ws_ctx"; then
      n_ok=$((n_ok + 1))
    else
      failed_names="$failed_names $repo_name"
    fi
  done

  local n_failed=$(( ${#repos[@]} - n_ok ))
  if [ "${#repos[@]}" -gt 1 ]; then
    if [ "$n_failed" -gt 0 ]; then
      printf 'sync complete: %d ok, %d failed (%s)\n' "$n_ok" "$n_failed" "${failed_names# }"
    else
      printf 'sync complete: %d ok, 0 failed\n' "$n_ok"
    fi
  fi

  [ "$n_failed" -eq 0 ]
}

orbit_status() {
  local root ws json_mode=0

  root=$(orbit_require_root) || return 1

  local args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json_mode=1; shift ;;
      -*) orbit_fail "unknown option: $1" ;;
      *) args+=("$1"); shift ;;
    esac
  done

  if [ "${#args[@]}" -eq 1 ]; then
    ws="${args[0]}"
  elif [ "${#args[@]}" -eq 0 ]; then
    ws=$(orbit_infer_workspace "$root") || return 1
  else
    orbit_fail "usage: orbit status [--json] [workspace]"
  fi

  local ws_dir="$root/$ws"
  [ -d "$ws_dir" ] || orbit_fail "workspace not found: $ws"

  orbit_ensure_workspace_orbit "$ws_dir"

  local goal
  goal=$(git config --file "$ws_dir/.orbit" --get workspace.goal 2>/dev/null || true)

  local status_val
  status_val=$(git config --file "$ws_dir/.orbit" --get workspace.status 2>/dev/null || true)
  [ -n "$status_val" ] || status_val="active"

  local d name branch upstream ahead behind dirty is_scoped
  local repo_entries=()
  for d in "$ws_dir"/*/; do
    [ -d "$d" ] || continue
    [ -d "$d/.git" ] || [ -f "$d/.git" ] || continue
    name=$(basename "$d")
    branch=$(git -C "$d" branch --show-current 2>/dev/null || echo "detached")
    case "$branch" in
      ws/"$ws"/*) is_scoped=1 ;;
      *) is_scoped=0 ;;
    esac
    # Upstream config may exist while its remote-tracking ref was never
    # materialized (single-branch pool): rev-parse then prints the literal
    # '@{upstream}' AND fails — treat that as untracked, never as in-sync.
    upstream=$(git -C "$d" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || upstream='-'
    if [ "$upstream" = '-' ]; then
      ahead='0'; behind='0'
    else
      ahead=$(git -C "$d" rev-list --count "${upstream}..HEAD" 2>/dev/null || echo '0')
      behind=$(git -C "$d" rev-list --count "HEAD..${upstream}" 2>/dev/null || echo '0')
    fi
    dirty=$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    repo_entries+=("$name|$branch|$ahead|$behind|$dirty|$is_scoped|$upstream")
  done

  if [ "$json_mode" -eq 1 ]; then
    local out="{"
    out+="$(orbit_json_kv workspace "$ws"),"
    out+="$(orbit_json_kv goal "$goal"),"
    out+="$(orbit_json_kv status "$status_val"),"
    out+='"worktrees":['
    local first=1
    for entry in "${repo_entries[@]+${repo_entries[@]}}"; do
      IFS='|' read -r name branch ahead behind dirty is_scoped upstream <<< "$entry"
      local dirty_bool="false"
      [ "$dirty" = "0" ] || dirty_bool="true"
      [ "$first" -eq 1 ] || out+=','
      first=0
      out+='{'
      out+="$(orbit_json_kv name "$name"),"
      out+="$(orbit_json_kv branch "$branch"),"
      out+="$(orbit_json_kv_raw ahead "$ahead"),"
      out+="$(orbit_json_kv_raw behind "$behind"),"
      out+="$(orbit_json_kv_raw dirty "$dirty_bool"),"
      out+="$(orbit_json_kv_raw scoped "$is_scoped")"
      out+='}'
    done
    out+=']}'
    printf '%s\n' "$out"
    return 0
  fi

  printf '=== workspace: %s (%s) ===\n' "$ws" "$status_val"
  if [ -n "$goal" ]; then
    printf 'goal: %s\n' "$goal"
  fi
  printf '\n'

  if [ "${#repo_entries[@]}" -eq 0 ]; then
    printf '(no repos yet — orbit add <repo>)\n'
    return 0
  fi

  local name_w=0
  for entry in "${repo_entries[@]}"; do
    IFS='|' read -r name _ <<< "$entry"
    [ "${#name}" -gt "$name_w" ] && name_w=${#name}
  done

  for entry in "${repo_entries[@]}"; do
    IFS='|' read -r name branch ahead behind dirty is_scoped upstream <<< "$entry"
    local display_branch="$branch" raw_mark=""
    case "$branch" in
      ws/"$ws"/*) display_branch="${branch#ws/"$ws"/}" ;;
    esac
    [ "$is_scoped" = "0" ] && raw_mark=" raw"
    if [ "$upstream" = '-' ]; then
      # Never fabricate +0/-0 for an untracked branch — that reads as "in sync"
      printf '  %-*s %-28s %-15s -   -  dirty:%s%s\n' "$name_w" "$name" "$display_branch" "(no upstream)" "$dirty" "$raw_mark"
    elif [ "$ahead" = "0" ] && [ "$behind" = "0" ] && [ "$dirty" = "0" ]; then
      printf '  %-*s %-28s %-15s clean\n' "$name_w" "$name" "$display_branch" "$upstream"
    else
      local counters=""
      [ "$ahead" != "0" ] && counters="+$ahead"
      if [ "$behind" != "0" ]; then
        [ -n "$counters" ] && counters="$counters "
        counters="$counters-$behind"
      fi
      if [ "$dirty" != "0" ]; then
        [ -n "$counters" ] && counters="$counters  "
        counters="${counters}dirty:$dirty"
      fi
      printf '  %-*s %-28s %-15s %s%s\n' "$name_w" "$name" "$display_branch" "$upstream" "$counters" "$raw_mark"
    fi
  done

  # Steering parity with context/done (spec-warnings steering registry):
  # raw-mode branches get the conversion pointer on stderr; the stdout table
  # keeps only the ' raw' mark.
  for entry in "${repo_entries[@]}"; do
    IFS='|' read -r name branch ahead behind dirty is_scoped upstream <<< "$entry"
    [ "$is_scoped" = "0" ] || continue
    printf 'orbit: %s: raw mode branch — run: orbit switch -c %s (convert to scoped)\n' "$name" "$branch" >&2
  done
}

orbit_goal() {
  local root ws goal=""

  root=$(orbit_require_root) || return 1
  ws=$(orbit_infer_workspace "$root") || return 1

  local ws_dir="$root/$ws"
  local orbit_file="$ws_dir/.orbit"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --clear)
        [ "$#" -le 1 ] || orbit_fail "unexpected argument after --clear: $2"
        if [ -f "$orbit_file" ]; then
          git config --file "$orbit_file" --unset workspace.goal 2>/dev/null || true
        fi
        printf 'goal cleared\n'
        orbit_random_msg ORBIT_GOAL_CLEAR_FAREWELLS
        return 0
        ;;
      -*) orbit_fail "unknown option: $1" ;;
      *)
        if [ -z "$goal" ]; then
          goal="$1"
        else
          orbit_fail "unexpected argument: $1"
        fi
        ;;
    esac
    shift
  done

  if [ -z "$goal" ]; then
    local use_editor=false
    if [ -n "${ORBIT_EDITOR:-}" ]; then
      use_editor=true
    elif [ -t 0 ]; then
      use_editor=true
    fi

    if [ "$use_editor" = true ]; then
      local current_goal
      current_goal=$(git config --file "$orbit_file" --get workspace.goal 2>/dev/null || true)
      local tmpf
      tmpf=$(mktemp "${TMPDIR:-/tmp}/orbit-goal-XXXXXX")
      local pidx=$(( RANDOM % ${#ORBIT_GOAL_PROMPTS[@]} ))
      if [ -n "$current_goal" ]; then
        printf '%s\n' "$current_goal" > "$tmpf"
        printf '\n# %s\n# Lines starting with # are ignored. Empty goal keeps current.\n' "${ORBIT_GOAL_PROMPTS[$pidx]}" >> "$tmpf"
      else
        printf '\n# %s\n# Lines starting with # are ignored. Empty goal aborts.\n' "${ORBIT_GOAL_PROMPTS[$pidx]}" > "$tmpf"
      fi
      local editor="${ORBIT_EDITOR:-${VISUAL:-${EDITOR:-vi}}}"
      "$editor" "$tmpf" </dev/tty >/dev/tty 2>/dev/null || "$editor" "$tmpf"
      goal=$(awk '/^#/{next} {lines[++n]=$0} END{s=1;e=n; while(s<=e && lines[s]=="")s++; while(e>=s && lines[e]=="")e--; for(i=s;i<=e;i++)print lines[i]}' "$tmpf")
      rm -f "$tmpf"
      if [ -z "$goal" ]; then
        if [ -n "$current_goal" ]; then
          return 0
        fi
        orbit_fail "aborting: empty goal"
      fi
    else
      goal=$(cat)
    fi
  fi
  [ -n "$goal" ] || orbit_fail "aborting: empty goal"

  orbit_ensure_workspace_orbit "$ws_dir"

  # Setting a goal signals new work: reactivate a done workspace so it leaves
  # prune eligibility, and clear the previous cycle's completion record.
  local prev_status
  prev_status=$(git config --file "$orbit_file" --get workspace.status 2>/dev/null || true)
  if [ "$prev_status" = "done" ]; then
    git config --file "$orbit_file" --unset workspace.status 2>/dev/null || true
    git config --file "$orbit_file" --unset workspace.done-at 2>/dev/null || true
    git config --file "$orbit_file" --unset workspace.done-date 2>/dev/null || true
    git config --file "$orbit_file" --remove-section pr 2>/dev/null || true
  fi

  git config --file "$orbit_file" workspace.goal "$goal"
  printf 'goal set: %s\n' "$goal"
  if [ "$prev_status" = "done" ]; then
    printf 'orbit: workspace reactivated (was done; cleared completion record and PR history)\n' >&2
  fi
  orbit_random_msg ORBIT_GOAL_FAREWELLS
}

orbit_jot() {
  local root ws repo_name="" text="" pop=false json_mode=0

  root=$(orbit_require_root) || return 1
  ws=$(orbit_infer_workspace "$root") || return 1

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pop) pop=true; shift ;;
      --json) json_mode=1; shift ;;
      -*) orbit_fail "unknown option: $1" ;;
      *)
        if [ -z "$repo_name" ]; then
          # Only a plain pool-repo name can name a repo here; a path-like
          # argument is treated as jot text, never resolved as a worktree.
          if orbit_valid_repo_name "$1" && { [ -d "$root/$ws/$1/.git" ] || [ -f "$root/$ws/$1/.git" ]; }; then
            repo_name="$1"
          else
            if [ -n "$text" ]; then
              orbit_fail "unexpected argument: $1"
            fi
            text="$1"
          fi
        elif [ -z "$text" ]; then
          text="$1"
        else
          orbit_fail "unexpected argument: $1"
        fi
        shift
        ;;
    esac
  done

  if [ -z "$repo_name" ]; then
    repo_name=$(orbit_infer_repo "$root" "$ws" 2>/dev/null) || orbit_fail "cannot infer repo from CWD, specify repo name"
  fi

  local ws_dir="$root/$ws"
  local orbit_file="$ws_dir/.orbit"
  orbit_ensure_workspace_orbit "$ws_dir"

  if [ "$pop" = true ]; then
    if [ "$json_mode" -eq 1 ]; then
      local entries=()
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        entries+=("$line")
      done < <(git config --file "$orbit_file" --get-all "jot.$repo_name.entry" 2>/dev/null || true)
      git config --file "$orbit_file" --unset-all "jot.$repo_name.entry" 2>/dev/null || true
      local out
      out="{$(orbit_json_kv repo "$repo_name"),\"entries\":["
      local first=1
      for e in "${entries[@]+${entries[@]}}"; do
        [ "$first" -eq 1 ] || out+=','
        first=0
        out+="\"$(orbit_json_escape "$e")\""
      done
      out+="],$(orbit_json_kv_raw count "${#entries[@]}")}"
      printf '%s\n' "$out"
    else
      git config --file "$orbit_file" --get-all "jot.$repo_name.entry" 2>/dev/null || true
      git config --file "$orbit_file" --unset-all "jot.$repo_name.entry" 2>/dev/null || true
    fi
    return 0
  fi

  if [ -z "$text" ]; then
    local use_editor=false
    if [ -n "${ORBIT_EDITOR:-}" ]; then
      use_editor=true
    elif [ -t 0 ]; then
      use_editor=true
    fi

    if [ "$use_editor" = true ]; then
      local tmpf
      tmpf=$(mktemp "${TMPDIR:-/tmp}/orbit-jot-XXXXXX")
      printf '\n# Jot a note for %s. Lines starting with # are ignored. Empty aborts.\n' "$repo_name" > "$tmpf"
      local editor="${ORBIT_EDITOR:-${VISUAL:-${EDITOR:-vi}}}"
      "$editor" "$tmpf" </dev/tty >/dev/tty 2>/dev/null || "$editor" "$tmpf"
      text=$(awk '/^#/{next} {lines[++n]=$0} END{s=1;e=n; while(s<=e && lines[s]=="")s++; while(e>=s && lines[e]=="")e--; for(i=s;i<=e;i++)print lines[i]}' "$tmpf")
      rm -f "$tmpf"
    else
      text=$(cat)
    fi
  fi

  [ -n "$text" ] || orbit_fail "aborting: empty jot"

  # Subsection form ([jot "<repo>"] entry), matching repos.<name>.url: a plain
  # jot.<repo> key cannot hold every contract-legal repo name (my_repo, 2048 —
  # git-config key segments reject '_' and leading digits), a subsection can.
  git config --file "$orbit_file" --add "jot.$repo_name.entry" "$text"

  local count buf half
  count=$(git config --file "$orbit_file" --get-all "jot.$repo_name.entry" 2>/dev/null | grep -c . || true)
  buf=$(orbit_jot_buffer_size "$root")
  half=$(( buf / 2 ))
  if [ "$count" -gt "$buf" ]; then
    printf 'orbit: %s has %s jots (overflow): jot %s --pop, then merge into memo\n' \
      "$repo_name" "$count" "$repo_name" >&2
  elif [ "$count" -gt "$half" ]; then
    printf 'orbit: %s has %s jots (building)\n' "$repo_name" "$count" >&2
  fi
}

orbit_done() {
  local root ws pr_urls=() json_mode=0

  root=$(orbit_require_root) || return 1
  ws=$(orbit_infer_workspace "$root") || return 1

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json_mode=1; shift ;;
      --pr) [ "$#" -ge 2 ] || orbit_fail "--pr requires a URL"; pr_urls+=("$2"); shift 2 ;;
      *) orbit_fail "unknown argument: $1" ;;
    esac
  done

  local ws_dir="$root/$ws"
  local orbit_file="$ws_dir/.orbit"

  orbit_ensure_workspace_orbit "$ws_dir"

  # Per-repo wrap-up gate (advisory, never blocks done): for each repo surface
  # what remains — one issue per line, with the literal command to close it.
  # Keywords (pop + merge / explore + write / curate once) are quoted verbatim
  # by skills/orbit/SKILL.md and skills/CONSTRAINTS.md: keep them intact.
  local budget_hint=0 any_warn=0
  local rs_name rs_count rs_mstate rs_branch rs_scoped
  while IFS='|' read -r rs_name rs_count _ _ rs_mstate rs_branch rs_scoped; do
    [ -n "$rs_name" ] || continue
    if [ "$rs_count" -gt 0 ]; then
      printf 'orbit: %s: %s jots remain — run: orbit jot %s --pop, then merge into memo (pop + merge)\n' \
        "$rs_name" "$rs_count" "$rs_name" >&2
      budget_hint=1 any_warn=1
    fi
    if [ "$rs_mstate" = "thin" ] && [ "$rs_count" -eq 0 ]; then
      printf 'orbit: %s: memo thin, no capture this session — explore + write\n' "$rs_name" >&2
      any_warn=1
    fi
    if [ "$rs_mstate" = "over" ]; then
      printf 'orbit: %s: memo over budget — curate once\n' "$rs_name" >&2
      budget_hint=1 any_warn=1
    fi
    if [ "$rs_scoped" = "0" ]; then
      printf 'orbit: %s: raw mode branch — run: orbit switch -c %s (convert to scoped)\n' \
        "$rs_name" "$rs_branch" >&2
      any_warn=1
    fi
  done < <(orbit_collect_repo_status "$root" "$ws_dir")

  if [ "$budget_hint" -eq 1 ]; then
    printf 'orbit: card budget is %s~%s lines: curate the memo to roles + how to use, don'\''t just append\n' \
      "$(orbit_memo_min "$root")" "$(orbit_memo_max "$root")" >&2
  fi

  # Any per-repo debt above means session knowledge is still outside the memo.
  # done ends the session; working memory and the jot queue do not survive it.
  if [ "$any_warn" -eq 1 ]; then
    printf 'orbit: only memo survives done\n' >&2
  fi

  local now now_date
  now=$(date +%s)
  now_date=$(date -r "$now" +%Y-%m-%d 2>/dev/null || date -d "@$now" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)

  git config --file "$orbit_file" workspace.status "done"
  git config --file "$orbit_file" workspace.done-at "$now"
  git config --file "$orbit_file" workspace.done-date "$now_date"

  if [ "${#pr_urls[@]}" -gt 0 ]; then
    for url in "${pr_urls[@]}"; do
      git config --file "$orbit_file" --add pr.url "$url"
    done
  fi

  if [ "$json_mode" -eq 1 ]; then
    local all_pr_urls=()
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      all_pr_urls+=("$url")
    done < <(git config --file "$orbit_file" --get-all pr.url 2>/dev/null || true)

    local out="{"
    out+="$(orbit_json_kv workspace "$ws"),"
    out+="$(orbit_json_kv status "done"),"
    out+="$(orbit_json_kv_raw doneAt "$now"),"
    out+='"prs":['
    local first=1
    for url in "${all_pr_urls[@]+${all_pr_urls[@]}}"; do
      [ "$first" -eq 1 ] || out+=','
      first=0
      out+="\"$(orbit_json_escape "$url")\""
    done
    out+=']}'
    printf '%s\n' "$out"
    return 0
  fi

  printf 'workspace %s marked done\n' "$ws"
  if [ "${#pr_urls[@]}" -gt 0 ]; then
    printf '  pr: %s\n' "${pr_urls[@]}"
  fi
  orbit_random_msg ORBIT_DONE_FAREWELLS
}

orbit_repos() {
  local json_mode=0 urls_mode=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json_mode=1; shift ;;
      --urls) urls_mode=1; shift ;;
      *) orbit_fail "usage: orbit repos [--json] [--urls]" ;;
    esac
  done

  local root
  root=$(orbit_require_root) || return 1

  local index="$root/.repos/.orbit"
  local has_repos=0

  # Mark repos already present in the current workspace (if any)
  local cur_ws=""
  cur_ws=$(orbit_infer_workspace "$root" 2>/dev/null) || cur_ws=""

  local names=() urls=() briefs=() heads=() stales=() completes=() memo_states=() in_ws_marks=()
  for repo_dir in "$root/.repos"/*/; do
    [ -d "$repo_dir" ] || continue
    local name url brief head idx_url idx_brief idx_head
    name=$(basename "$repo_dir")
    has_repos=1

    idx_url=$(git config --file "$index" --get "repos.$name.url" 2>/dev/null || true)
    idx_brief=$(git config --file "$index" --get "repos.$name.brief" 2>/dev/null || true)
    idx_head=$(git config --file "$index" --get "repos.$name.head" 2>/dev/null || true)

    url="$idx_url"
    if [ -z "$url" ]; then
      url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || echo "-")
    fi

    # repos only needs the brief text; the source tag drives no rendering here
    IFS= read -r brief <<< "$(orbit_pool_brief "$root" "$index" "$name" "$repo_dir")"
    [ -n "$brief" ] || brief="-"

    head="$idx_head"
    if [ -z "$head" ]; then
      head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null) || head="-"
    fi

    local incomplete_flag=false
    if [ ! -f "$root/.repos/.$name.md" ] || [ -z "$idx_url" ] || [ -z "$idx_brief" ] || [ -z "$idx_head" ]; then
      incomplete_flag=true
    fi

    local memo_behind=0
    local current_head
    current_head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)
    if [ -n "$idx_head" ] && [ -n "$current_head" ] && [ "$idx_head" != "$current_head" ] && [ -f "$root/.repos/.$name.md" ]; then
      memo_behind=$(git -C "$repo_dir" rev-list "$idx_head".."$current_head" --count 2>/dev/null || echo 0)
    fi

    # Human table carries memo state as a column (was: unsilenceable stderr spray)
    local memo_state
    if [ ! -f "$root/.repos/.$name.md" ]; then
      memo_state="none"
    elif [ "$memo_behind" != "0" ]; then
      memo_state="stale $memo_behind"
    else
      memo_state="ok"
    fi

    local in_ws=""
    if [ -n "$cur_ws" ] && { [ -d "$root/$cur_ws/$name/.git" ] || [ -f "$root/$cur_ws/$name/.git" ]; }; then
      in_ws="*"
    fi

    names+=("$name")
    urls+=("$url")
    briefs+=("$brief")
    heads+=("$head")
    stales+=("$memo_behind")
    completes+=("$incomplete_flag")
    memo_states+=("$memo_state")
    in_ws_marks+=("$in_ws")
  done

  if [ "$has_repos" -eq 0 ]; then
    if [ "$json_mode" -eq 1 ]; then
      printf '[]\n'
    else
      printf '(no repos in pool)\n'
    fi
    return 0
  fi

  if [ "$json_mode" -eq 1 ]; then
    local out='['
    local first=1 i
    for i in "${!names[@]}"; do
      [ "$first" -eq 1 ] || out+=','
      first=0
      out+='{'
      out+="$(orbit_json_kv name "${names[$i]}"),"
      out+="$(orbit_json_kv url "${urls[$i]}"),"
      out+="$(orbit_json_kv brief "${briefs[$i]}"),"
      out+="$(orbit_json_kv head "${heads[$i]}"),"
      out+="$(orbit_json_kv_raw incomplete "${completes[$i]}"),"
      out+="$(orbit_json_kv_raw memoBehind "${stales[$i]}")"
      out+='}'
    done
    out+=']'
    printf '%s\n' "$out"
    return 0
  fi

  local name_w=4
  for i in "${!names[@]}"; do
    [ "${#names[$i]}" -gt "$name_w" ] && name_w=${#names[$i]}
  done

  if [ "$urls_mode" -eq 1 ]; then
    printf '%-*s  %-5s %-9s %-40s %s\n' "$name_w" "NAME" "ADDED" "MEMO" "URL" "BRIEF"
    local i
    for i in "${!names[@]}"; do
      printf '%-*s  %-5s %-9s %-40.40s %s\n' "$name_w" "${names[$i]}" "${in_ws_marks[$i]}" "${memo_states[$i]}" "${urls[$i]}" "${briefs[$i]}"
    done
  else
    printf '%-*s  %-5s %-9s %s\n' "$name_w" "NAME" "ADDED" "MEMO" "BRIEF"
    local i
    for i in "${!names[@]}"; do
      printf '%-*s  %-5s %-9s %s\n' "$name_w" "${names[$i]}" "${in_ws_marks[$i]}" "${memo_states[$i]}" "${briefs[$i]}"
    done
  fi
}

orbit_info() {
  local json_mode=0 repo_name=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json_mode=1; shift ;;
      -*) orbit_fail "unknown option: $1" ;;
      *)
        if [ -z "$repo_name" ]; then
          repo_name="$1"
        else
          orbit_fail "unexpected argument: $1"
        fi
        shift
        ;;
    esac
  done

  [ -n "$repo_name" ] || orbit_fail "usage: orbit info [--json] <repo>"
  orbit_require_repo_name "$repo_name"

  local root
  root=$(orbit_require_root) || return 1

  local repo_dir="$root/.repos/$repo_name"
  [ -d "$repo_dir" ] || orbit_fail "repo not in pool: $repo_name"

  local default_branch
  default_branch=$(orbit_default_branch "$repo_dir" 2>/dev/null) || true
  if [ -n "$default_branch" ]; then
    # Reconcile fetch refspecs, then bare fetch so refs for refspecs just
    # registered (branch pushed since last run) materialize too.
    while IFS= read -r line; do
      printf 'orbit: %s: %s\n' "$repo_name" "$line" >&2
    done < <(orbit_reconcile_fetch_refspecs "$repo_dir" 0)
    git -C "$repo_dir" fetch origin 2>/dev/null || true
  fi

  orbit_upstream_check "$repo_name" "$root"
  orbit_staleness_check "$repo_name" "$root"

  local content=""
  local md_file="$root/.repos/.$repo_name.md"
  if [ -f "$md_file" ]; then
    content=$(cat "$md_file")
  else
    local readme=""
    for f in "$repo_dir/README.md" "$repo_dir/README" "$repo_dir/readme.md"; do
      if [ -f "$f" ]; then readme="$f"; break; fi
    done

    if [ -n "$readme" ]; then
      local max total
      max=$(orbit_memo_max "$root")
      total=$(grep -c '' "$readme" 2>/dev/null || echo 0)
      content=$(head -n "$max" "$readme")
      if [ "$total" -gt "$max" ]; then
        printf 'orbit: %s has no memo; showing first %s of %s README lines\n' "$repo_name" "$max" "$total" >&2
      else
        printf 'orbit: %s has no memo, showing README\n' "$repo_name" >&2
      fi
    else
      printf 'orbit: %s has no memo\n' "$repo_name" >&2
      content="(no memo available)"
    fi
  fi

  if [ "$json_mode" -eq 1 ]; then
    local remote_ahead=0 memo_behind=0
    if [ -n "$default_branch" ]; then
      local local_head remote_head
      local_head=$(git -C "$repo_dir" rev-parse "refs/heads/$default_branch" 2>/dev/null) || true
      remote_head=$(git -C "$repo_dir" rev-parse "refs/remotes/origin/$default_branch" 2>/dev/null) || true
      if [ -n "$local_head" ] && [ -n "$remote_head" ] && [ "$local_head" != "$remote_head" ]; then
        remote_ahead=$(git -C "$repo_dir" rev-list "$local_head".."$remote_head" --count 2>/dev/null || echo 0)
      fi
    fi
    local index="$root/.repos/.orbit"
    local stored
    stored=$(git config --file "$index" --get "repos.$repo_name.head" 2>/dev/null || true)
    if [ -n "$stored" ] && [ -f "$md_file" ]; then
      local current_head
      current_head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)
      if [ -n "$current_head" ] && [ "$stored" != "$current_head" ]; then
        memo_behind=$(git -C "$repo_dir" rev-list "$stored".."$current_head" --count 2>/dev/null || echo 0)
      fi
    fi
    local out="{"
    out+="$(orbit_json_kv repo "$repo_name"),"
    out+="$(orbit_json_kv content "$content"),"
    out+="$(orbit_json_kv_raw remoteAhead "$remote_ahead"),"
    out+="$(orbit_json_kv_raw memoBehind "$memo_behind")"
    out+='}'
    printf '%s\n' "$out"
    return 0
  fi

  printf '%s\n' "$content"
}

orbit_memo_scaffold() {
  local repo_name="$1" root="$2"
  local repo_dir="$root/.repos/$repo_name"

  [ -d "$repo_dir" ] || orbit_fail "repo not in pool: $repo_name"

  cat <<EOF
# ${repo_name}

TODO — one sentence, ≤ 120 chars, what this repo is

## When to add (roles)
- TODO — a reason a workspace would pull this repo in (list every role; a repo may fill many)

## How to use
- \`TODO\` — MVP/VIP file or dir path + why it matters + when to reach for it (list as many as needed; e.g. CLI entry, core package)
EOF
}

orbit_memo() {
  if [ "$#" -eq 0 ]; then
    orbit_memo_refresh_all
    return 0
  fi

  local repo_name="$1"; shift
  local refresh_only=0 scaffold_mode=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --refresh)  refresh_only=1; shift ;;
      --scaffold) scaffold_mode=1; shift ;;
      *) orbit_fail "unknown option: $1" ;;
    esac
  done

  local root
  root=$(orbit_require_root) || return 1
  orbit_require_repo_name "$repo_name"
  local repo_dir="$root/.repos/$repo_name"
  [ -d "$repo_dir" ] || orbit_fail "repo not in pool: $repo_name"

  if [ "$scaffold_mode" -eq 1 ]; then
    orbit_memo_scaffold "$repo_name" "$root"
    return 0
  fi

  if [ "$refresh_only" -eq 1 ]; then
    orbit_memo_refresh_one "$repo_name" "$root"
    return 0
  fi

  local md_file="$root/.repos/.$repo_name.md"
  local content
  content=$(cat)
  [ -n "$content" ] || orbit_fail "empty input; pipe markdown content to 'orbit memo $repo_name'"

  local brief
  brief=$(printf '%s\n' "$content" | orbit_brief_extract /dev/stdin) || orbit_fail "cannot extract brief from input (need a valid text paragraph after title)"

  printf '%s\n' "$content" > "$md_file"

  local index="$root/.repos/.orbit"
  local url head
  url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || echo "-")
  head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null) || head="-"
  git config --file "$index" "repos.$repo_name.url" "$url"
  git config --file "$index" "repos.$repo_name.brief" "$brief"
  git config --file "$index" "repos.$repo_name.head" "$head"

  # Over-budget advisory: one-shot stderr when this write left the card well
  # past the ceiling (maxLines + minLines buffer, so best-effort curation that
  # lands slightly over the ceiling is left alone). No loop: the same state
  # resurfaces via per-repo status (context/done), computed inline each time.
  local ws
  if ws=$(orbit_infer_workspace "$root" 2>/dev/null) && [ -n "$ws" ]; then
    local n threshold
    n=$(grep -c '[^[:space:]]' "$md_file" 2>/dev/null || echo 0)
    threshold=$(orbit_memo_overlong_threshold "$root")
    if [ "$n" -gt "$threshold" ]; then
      printf 'orbit: %s memo is over budget (%s lines): curate the card back to %s~%s lines, don'\''t just append\n' \
        "$repo_name" "$n" "$(orbit_memo_min "$root")" "$(orbit_memo_max "$root")" >&2
    fi
  fi

  printf 'wrote memo for %s (brief: %s)\n' "$repo_name" "$brief"
}

orbit_memo_refresh_one() {
  local repo_name="$1" root="$2"
  local repo_dir="$root/.repos/$repo_name"
  local index="$root/.repos/.orbit"
  local md_file="$root/.repos/.$repo_name.md"

  local url head brief=""
  url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || echo "-")
  head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null) || head="-"

  if [ -f "$md_file" ]; then
    brief=$(orbit_brief_extract "$md_file" || true)
  fi

  git config --file "$index" "repos.$repo_name.url" "$url"
  git config --file "$index" "repos.$repo_name.head" "$head"
  if [ -n "$brief" ]; then
    git config --file "$index" "repos.$repo_name.brief" "$brief"
  else
    git config --file "$index" --unset "repos.$repo_name.brief" 2>/dev/null || true
  fi

  printf 'refreshed index: %s\n' "$repo_name"
}

orbit_memo_refresh_all() {
  local root
  root=$(orbit_require_root) || return 1

  local n_refreshed=0
  for repo_dir in "$root/.repos"/*/; do
    [ -d "$repo_dir" ] || continue
    local name
    name=$(basename "$repo_dir")
    orbit_memo_refresh_one "$name" "$root"
    n_refreshed=$((n_refreshed + 1))
  done
  printf 'refreshed index: %d %s\n' "$n_refreshed" "$(orbit_plural "$n_refreshed" repo repos)"
}

# --- Prune ---

orbit_parse_duration() {
  local input="$1"
  local num unit
  num="${input%[dwmy]}"
  unit="${input##*[0-9]}"
  [[ "$num" =~ ^[0-9]+$ ]] || return 1
  case "$unit" in
    d) printf '%s\n' "$(( num * 86400 ))" ;;
    w) printf '%s\n' "$(( num * 604800 ))" ;;
    m) printf '%s\n' "$(( num * 2592000 ))" ;;
    y) printf '%s\n' "$(( num * 31536000 ))" ;;
    *) return 1 ;;
  esac
}

orbit_pr_merged() {
  local url="$1"
  if ! command -v gh >/dev/null 2>&1; then
    printf 'orbit: gh CLI not installed, skipping PR status check\n' >&2
    return 1
  fi
  local state
  state=$(gh pr view "$url" --json state -q .state 2>/dev/null || true)
  [ "$state" = "MERGED" ]
}

orbit_collect_workspace_branches() {
  local repo_dir="$1" ws_name="$2"
  local prefix
  prefix=$(orbit_require_prefix) || return 1
  local branches=()
  local worktree_branch
  worktree_branch=$(git -C "$repo_dir" branch --show-current 2>/dev/null || true)
  if [ -n "$worktree_branch" ]; then
    branches+=("$worktree_branch")
  fi
  local main_repo
  main_repo=$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -z "$main_repo" ]; then
    main_repo=$( (cd "$repo_dir" && git rev-parse --git-common-dir 2>/dev/null) || true)
    if [ -n "$main_repo" ] && [ "${main_repo#/}" = "$main_repo" ]; then
      main_repo="$(cd "$repo_dir" && cd "$main_repo" && pwd)"
    fi
  fi
  if [ -n "$main_repo" ] && [ -d "$main_repo" ]; then
    main_repo="${main_repo%/.git}"
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      branches+=("$b")
    done < <(git -C "$main_repo" for-each-ref --format='%(refname:short)' "refs/heads/$prefix/$ws_name/")
  fi
  # deduplicate and output
  printf '%s\n' "${branches[@]+${branches[@]}}" | sort -u
}

# True when every change on <branch> is already contained in <upstream>'s
# tree — the signature of a squash/rebase merge, which rewrites SHAs and
# therefore defeats the ancestor check. Ordered by cost: `git merge-tree`
# first (O(merged paths), independent of commit count, and definitive in BOTH
# directions when it exits 0 — a differing tree proves the branch adds
# content); `git cherry` only when merge-tree cannot answer (git < 2.38, or a
# conflicting merge), since it costs O(commits × diff) over the whole range
# and only catches 1:1 patch equivalence. merge-tree writes a few tree
# objects to the ODB (invisible git-internal cache, also under --dry-run).
orbit_branch_content_upstream() {
  local main_repo="$1" branch="$2" upstream="$3" merged_tree
  if merged_tree=$(git -C "$main_repo" merge-tree --write-tree "$upstream" "$branch" 2>/dev/null); then
    [ "$merged_tree" = "$(git -C "$main_repo" rev-parse "$upstream^{tree}" 2>/dev/null)" ]
    return
  fi
  # An unresolvable upstream — or any cherry failure — is "cannot tell", not
  # "content upstream": an empty '+' set would otherwise invert into a false
  # positive, and the hint hands out branch -D verbatim. Capture first and
  # match without a pipe (a pipe can SIGPIPE the producer under pipefail).
  local cherry_out
  cherry_out=$(git -C "$main_repo" cherry "$upstream" "$branch" 2>/dev/null) || return 1
  ! grep -q '^+' <<< "$cherry_out"
}

orbit_branch_protection_delete() {
  local main_repo="$1" branch="$2" pr_urls_str="$3" force_flag="$4" verify_flag="$5" dry_run_flag="$6"
  # Returns 0 if the branch was (or would be) deleted, 1 if skipped.

  if [ "$force_flag" = "1" ]; then
    if [ "$dry_run_flag" = "1" ]; then
      printf '    would force-delete branch: %s\n' "$branch"
    else
      git -C "$main_repo" branch -D "$branch" 2>/dev/null || true
      printf '    deleted branch (force): %s\n' "$branch"
    fi
    return 0
  fi

  # Layer 1: --verify + PR URLs → check merged
  if [ "$verify_flag" = "1" ] && [ -n "$pr_urls_str" ]; then
    local all_merged=1
    for url in $pr_urls_str; do
      if ! orbit_pr_merged "$url"; then
        all_merged=0
        break
      fi
    done
    if [ "$all_merged" = "1" ]; then
      if [ "$dry_run_flag" = "1" ]; then
        printf '    would delete branch (PR merged): %s\n' "$branch"
      else
        git -C "$main_repo" branch -D "$branch" 2>/dev/null || true
        printf '    deleted branch (PR merged): %s\n' "$branch"
      fi
      return 0
    fi
  fi

  # Layer 2: merged into origin/<default-branch>
  local default_branch
  default_branch=$(orbit_default_branch "$main_repo" 2>/dev/null || true)
  if [ -n "$default_branch" ] && git -C "$main_repo" merge-base --is-ancestor "$branch" "origin/$default_branch" 2>/dev/null; then
    if [ "$dry_run_flag" = "1" ]; then
      printf '    would delete branch (merged): %s\n' "$branch"
    else
      git -C "$main_repo" branch -d "$branch" 2>/dev/null || true
      printf '    deleted branch (merged): %s\n' "$branch"
    fi
    return 0
  fi

  # Layer 3: skip — but a squash/rebase merge rewrites SHAs and defeats the
  # ancestor check above, so a branch can be unmerged in form yet fully merged
  # in content. Name that case and hand the operator the exact cleanup
  # command: prune runs at the project root, where the operator is human.
  # In dry-run the skip is part of the report (stdout); in a real run it is a
  # diagnostic accompanying the mutation (stderr).
  local note=""
  if [ -n "$default_branch" ] && orbit_branch_content_upstream "$main_repo" "$branch" "origin/$default_branch"; then
    note=" (content already upstream — squash/rebase merge? clean up: git -C \"$main_repo\" branch -D \"$branch\")"
  fi
  if [ "$dry_run_flag" = "1" ]; then
    printf '    would skip unmerged branch: %s%s\n' "$branch" "$note"
  else
    printf 'orbit: skipping unmerged branch: %s%s\n' "$branch" "$note" >&2
  fi
  return 1
}

orbit_prune() {
  local older="" dry_run=0 force=0 verify=0 target_ws=""
  local orig_args=("$@")

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --older) [ "$#" -ge 2 ] || orbit_fail "--older requires a duration"; older="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --force) force=1; shift ;;
      --verify) verify=1; shift ;;
      -*) orbit_fail "unknown option: $1" ;;
      *) [ -z "$target_ws" ] || orbit_fail "unexpected argument: $1"; target_ws="$1"; shift ;;
    esac
  done

  local root
  root=$(orbit_require_root) || return 1

  # Prune is a root-level destructive operation: target-independent guard,
  # shared with the other root-scoped commands (see orbit_require_root_scope).
  orbit_require_root_scope "$root" "prune" "prune" ${orig_args[@]+"${orig_args[@]}"}

  local older_seconds=0
  if [ -n "$older" ]; then
    older_seconds=$(orbit_parse_duration "$older") || orbit_fail "invalid duration: $older"
  fi

  local now
  now=$(date +%s)

  # Collect candidate workspaces
  local candidates=()
  for ws_dir in "$root"/*/; do
    [ -d "$ws_dir" ] || continue
    local ws_name
    ws_name=$(basename "$ws_dir")
    orbit_reserved_workspace "$ws_name" && continue

    # If specific workspace given, filter
    if [ -n "$target_ws" ] && [ "$ws_name" != "$target_ws" ]; then
      continue
    fi

    local orbit_file="$ws_dir/.orbit"
    local status_val
    status_val=$(git config --file "$orbit_file" --get workspace.status 2>/dev/null || true)
    [ "$status_val" = "done" ] || continue

    # --older check
    if [ "$older_seconds" -gt 0 ]; then
      local done_at
      done_at=$(git config --file "$orbit_file" --get workspace.done-at 2>/dev/null || true)
      if [ -z "$done_at" ]; then
        done_at=$(git config --file "$orbit_file" --get workspace.created 2>/dev/null || true)
      fi
      if [ -z "$done_at" ]; then
        done_at=$(stat -f %m "$ws_dir" 2>/dev/null || stat -c %Y "$ws_dir" 2>/dev/null || echo "$now")
      fi
      local age=$(( now - done_at ))
      [ "$age" -gt "$older_seconds" ] || continue
    fi

    candidates+=("$ws_name")
  done

  if [ -n "$target_ws" ] && [ "${#candidates[@]}" -eq 0 ]; then
    orbit_fail "workspace not found or not marked done: $target_ws"
  fi

  if [ "${#candidates[@]}" -eq 0 ]; then
    printf 'nothing to prune\n'
    return 0
  fi

  for ws in "${candidates[@]}"; do
    local ws_dir="$root/$ws"
    local orbit_file="$ws_dir/.orbit"

    # Collect all PR URLs from workspace metadata
    local pr_urls_str=""
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      pr_urls_str="$pr_urls_str $url"
    done < <(git config --file "$orbit_file" --get-all pr.url 2>/dev/null || true)
    pr_urls_str="${pr_urls_str# }"

    # --verify mode: all PRs must be merged
    if [ "$verify" = "1" ] && [ -n "$pr_urls_str" ]; then
      local all_merged=1
      for url in $pr_urls_str; do
        if ! orbit_pr_merged "$url"; then
          all_merged=0
          break
        fi
      done
      if [ "$all_merged" = "0" ]; then
        printf 'orbit: skipping %s: not all PRs merged\n' "$ws" >&2
        continue
      fi
    fi

    # Collect repo worktrees first so the header can lead the report.
    # foreign_repos: git repos in the workspace that are NOT worktrees of a pool
    # repo. A pool worktree always has a .git *file* (gitdir pointer); a .git
    # *directory* is an independent clone even when it sits under a pool repo's
    # name — its objects live in its own .git, so the rm -rf below destroys
    # history that exists nowhere else. The scan is deliberately top-level:
    # guard scope is the workspace's direct children (see spec-lifecycle).
    local ws_repo_dirs=() foreign_repos=()
    for repo_dir in "$ws_dir"/*/; do
      [ -d "$repo_dir" ] || continue
      [ -d "$repo_dir/.git" ] || [ -f "$repo_dir/.git" ] || continue
      local repo_name
      repo_name=$(basename "$repo_dir")
      if [ -f "$repo_dir/.git" ] && [ -d "$root/.repos/$repo_name" ]; then
        ws_repo_dirs+=("$repo_dir")
      else
        foreign_repos+=("$repo_name")
      fi
    done

    # Data protection: never destroy uncommitted changes without --force.
    # Branch deletion has merged-checks below, but worktree removal nukes
    # working-tree state outright — gate it here. The guard must cover
    # everything rm -rf destroys, not just the pool-backed worktrees: a repo
    # with no pool counterpart loses its object database too.
    #
    # All reasons are collected before reporting: --force releases them as one
    # decision, so the operator has to see the whole set to make that decision
    # once, instead of fixing one reason per run and being surprised by the next.
    if [ "$force" = "0" ]; then
      local skip_reasons=""
      local dirty_repos=()
      for repo_dir in ${ws_repo_dirs[@]+"${ws_repo_dirs[@]}"}; do
        # An unreadable status is "cannot tell", not "clean" — treat it as dirty.
        local st_out st_rc=0
        st_out=$(git -C "$repo_dir" status --porcelain 2>/dev/null) || st_rc=$?
        if [ "$st_rc" -ne 0 ] || [ -n "$st_out" ]; then
          dirty_repos+=("$(basename "$repo_dir")")
        fi
      done
      [ "${#dirty_repos[@]}" -gt 0 ] && skip_reasons="uncommitted changes in: ${dirty_repos[*]}"

      if [ "${#foreign_repos[@]}" -gt 0 ]; then
        [ -n "$skip_reasons" ] && skip_reasons="$skip_reasons; "
        skip_reasons="${skip_reasons}git repos not from the pool: ${foreign_repos[*]}"
      fi

      # Knowledge protection: jots live in the workspace .orbit, which rm -rf
      # takes with it. done only warns once; this is the last checkpoint before
      # the queue is gone for good.
      local jotted_repos=() jot_repo jot_count
      while IFS= read -r jot_repo; do
        [ -n "$jot_repo" ] || continue
        jot_count=$(git config --file "$ws_dir/.orbit" --get-all "jot.$jot_repo.entry" 2>/dev/null | grep -c . || true)
        [ "${jot_count:-0}" -gt 0 ] || continue
        jotted_repos+=("$jot_repo ($jot_count)")
      done < <(git config --file "$ws_dir/.orbit" --name-only --get-regexp '^jot\..*\.entry$' 2>/dev/null | sed 's/^jot\.//; s/\.entry$//' | sort -u || true)
      if [ "${#jotted_repos[@]}" -gt 0 ]; then
        [ -n "$skip_reasons" ] && skip_reasons="$skip_reasons; "
        skip_reasons="${skip_reasons}unmerged jots in: ${jotted_repos[*]}"
      fi

      if [ -n "$skip_reasons" ]; then
        if [ "$dry_run" = "1" ]; then
          printf 'would skip: %s (%s)\n' "$ws" "$skip_reasons"
        else
          printf 'orbit: skipping %s: %s\n' "$ws" "$skip_reasons" >&2
        fi
        continue
      fi
    fi

    local n_deleted=0 n_skipped=0 n_worktrees=0

    if [ "$dry_run" = "1" ]; then
      printf 'would prune: %s (%d %s)\n' "$ws" "${#ws_repo_dirs[@]}" "$(orbit_plural "${#ws_repo_dirs[@]}" repo repos)"
    else
      printf 'pruning: %s (%d %s)\n' "$ws" "${#ws_repo_dirs[@]}" "$(orbit_plural "${#ws_repo_dirs[@]}" repo repos)"
    fi

    if [ "${#ws_repo_dirs[@]}" -eq 0 ]; then
      printf '  (no repos)\n'
    fi

    # Process each repo worktree in workspace
    if [ "${#ws_repo_dirs[@]}" -gt 0 ]; then
    for repo_dir in "${ws_repo_dirs[@]}"; do
      local repo_name
      repo_name=$(basename "$repo_dir")
      local main_repo="$root/.repos/$repo_name"

      printf '  %s:\n' "$repo_name"

      # Collect branches
      local ws_branches
      ws_branches=$(orbit_collect_workspace_branches "$repo_dir" "$ws")

      # Remove worktree
      if [ "$dry_run" = "1" ]; then
        printf '    would remove worktree\n'
      else
        if git -C "$main_repo" worktree remove "$repo_dir" --force 2>/dev/null; then
          printf '    removed worktree\n'
        else
          printf '    worktree not registered to the pool repo; left to directory removal\n'
        fi
      fi
      n_worktrees=$((n_worktrees + 1))

      # Delete branches (config sections are removed by git along with the branch)
      while IFS= read -r branch; do
        [ -n "$branch" ] || continue
        if orbit_branch_protection_delete "$main_repo" "$branch" "$pr_urls_str" "$force" "$verify" "$dry_run"; then
          n_deleted=$((n_deleted + 1))
        else
          n_skipped=$((n_skipped + 1))
        fi
      done <<< "$ws_branches"

      # Branches shaped like this workspace's but outside the configured prefix
      # are not orbit's to delete — raw-mode branches, or branches created while
      # branch.prefix held a different value (config is cache: losing it reverts
      # the prefix to the default and would orphan them silently). Git is the
      # structural source of truth here, so the branch names are the record —
      # name them rather than let them leak unseen.
      local ws_prefix left_behind=() lb
      ws_prefix=$(orbit_require_prefix) || return 1
      while IFS= read -r lb; do
        [ -n "$lb" ] || continue
        case "$lb" in
          "$ws_prefix/$ws/"*) continue ;;
          */"$ws"/*) left_behind+=("$lb") ;;
        esac
      done < <(git -C "$main_repo" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null || true)
      if [ "${#left_behind[@]}" -gt 0 ]; then
        if [ "$dry_run" = "1" ]; then
          printf '    would leave branch outside branch.prefix: %s\n' "${left_behind[*]}"
        else
          printf 'orbit: %s: left branch outside branch.prefix: %s\n' "$repo_name" "${left_behind[*]}" >&2
        fi
      fi

      # Clean leftover upstream config sections (branches that were skipped)
      if [ "$dry_run" = "0" ]; then
        local prefix
        prefix=$(orbit_require_prefix) || return 1
        while IFS= read -r branch; do
          [ -n "$branch" ] || continue
          git -C "$main_repo" config --remove-section "branch.$branch" 2>/dev/null || true
        done < <(git -C "$main_repo" for-each-ref --format='%(refname:short)' "refs/heads/$prefix/$ws/" 2>/dev/null || true)
      fi

      # Reconcile fetch refspecs (remote branch deleted, e.g. after PR merge;
      # or pushed since and not yet registered)
      while IFS= read -r line; do
        printf '    %s\n' "$line"
      done < <(orbit_reconcile_fetch_refspecs "$main_repo" "$dry_run")
    done
    fi

    # Remove workspace directory
    if [ "$dry_run" = "1" ]; then
      printf 'would remove workspace directory\n'
    else
      rm -rf "${root:?}/${ws:?}"
      printf 'pruned: %s (%d %s removed, %d %s deleted, %d skipped)\n' \
        "$ws" "$n_worktrees" "$(orbit_plural "$n_worktrees" worktree worktrees)" \
        "$n_deleted" "$(orbit_plural "$n_deleted" branch branches)" "$n_skipped"
    fi
  done
}

# --- Doctor ---

orbit_doctor() {
  local all_ok=1

  printf 'Orbit Environment Diagnostics\n'
  printf '================================\n'
  printf 'orbit %s\n\n' "$ORBIT_VERSION"

  # 1. git version check (≥ 2.20)
  if command -v git >/dev/null 2>&1; then
    local git_ver
    git_ver=$(git --version | awk '{print $3}')
    if [ "$(printf '%s\n' "2.20" "$git_ver" | sort -V | head -n1)" = "2.20" ]; then
      printf '[OK]   git %s\n' "$git_ver"
    else
      printf '[FAIL] git %s (need >= 2.20)\n' "$git_ver"
      all_ok=0
    fi
  else
    printf '[FAIL] git not found\n'
    all_ok=0
  fi

  if command -v git >/dev/null 2>&1 && ! orbit_git_supports_orphan_worktree; then
    # < 2.42: one consolidated warning naming every affected capability
    local missing=""
    if ! orbit_git_supports_autosetupremote; then
      # backticks are literal text in the user-facing warning
      # shellcheck disable=SC2016
      missing='raw-mode bare `git push` needs >= 2.37'
    fi
    [ -n "$missing" ] && missing="$missing; "
    missing="${missing}empty-repo bootstrap (orbit add --orphan) needs >= 2.42"
    printf '[WARN] git %s: upgrade to >= 2.42 (%s)\n' "$git_ver" "$missing"
  fi

  # 2. bash version check (≥ 3.2)
  if [ "${BASH_VERSINFO[0]}" -gt 3 ] || { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
    printf '[OK]   bash %s\n' "$BASH_VERSION"
  else
    printf '[FAIL] bash %s (need >= 3.2)\n' "$BASH_VERSION"
    all_ok=0
  fi

  # 3. Optional tools
  if command -v jq >/dev/null 2>&1; then
    printf '[OK]   jq (optional)\n'
  else
    printf '[WARN] jq not found (optional, improves JSON handling)\n'
  fi

  if command -v gh >/dev/null 2>&1; then
    printf '[OK]   gh (optional)\n'
  else
    printf '[WARN] gh not found (optional, enables PR-aware prune)\n'
  fi

  # Prune's session-rooted guard is best-effort: it reads ancestor cwds via
  # /proc (Linux) or lsof (macOS). Without either, only the root-level guard
  # applies — surface that instead of failing silently open.
  if [ -d "/proc/$$" ] || command -v lsof >/dev/null 2>&1; then
    printf '[OK]   process ancestry (/proc or lsof; prune initiation guard)\n'
  else
    printf '[WARN] no /proc and no lsof: prune cannot detect sessions rooted in a workspace (root-level guard still applies)\n'
  fi

  # 4. Project structure (if in orbit project)
  local root
  if root=$(orbit_find_root 2>/dev/null); then
    printf '\nProject: %s\n' "$root"
    if [ -d "$root/.repos" ]; then
      printf '[OK]   .repos/ exists\n'
      if [ -f "$root/.repos/.orbit" ]; then
        printf '[OK]   .repos/.orbit index\n'
      else
        printf '[WARN] .repos/.orbit not found (created on first clone)\n'
      fi
      local repo_count=0
      for d in "$root/.repos"/*/; do
        [ -d "$d" ] && repo_count=$((repo_count + 1))
      done
      printf '[INFO] repos in pool: %d\n' "$repo_count"
      local ws_count=0
      for d in "$root"/*/; do
        [ -d "$d" ] || continue
        local dirname
        dirname=$(basename "$d")
        orbit_reserved_workspace "$dirname" && continue
        ws_count=$((ws_count + 1))
      done
      printf '[INFO] workspaces: %d\n' "$ws_count"
    else
      printf '[WARN] .repos/ not found (run orbit clone to start)\n'
    fi
  else
    printf '\n[INFO] not in orbit project\n'
  fi

  printf '\n'
  if [ "$all_ok" -eq 1 ]; then
    printf 'All critical checks passed.\n'
  else
    # the verdict belongs to the report — keep it on stdout with the rest
    printf 'Some critical checks failed.\n'
    return 1
  fi
}

# --- Config ---

orbit_config() {
  local root
  root=$(orbit_require_root) || return 1
  local orbit_file="$root/.repos/.orbit"

  if [ "$#" -eq 0 ]; then
    # git config --list lowercases keys; restore the documented camelCase forms
    git config --file "$orbit_file" --list 2>/dev/null | grep -v '^repos\.' | \
      sed -e 's/^memo\.minlines=/memo.minLines=/' \
          -e 's/^memo\.maxlines=/memo.maxLines=/' \
          -e 's/^jot\.buffersize=/jot.bufferSize=/' || true
    return 0
  fi

  local key="$1"
  if [ "$#" -eq 1 ]; then
    local val
    if val=$(git config --file "$orbit_file" --get "$key" 2>/dev/null); then
      printf '%s\n' "$val"
    else
      printf '(unset)\n' >&2
      return 1
    fi
    return 0
  fi

  [ "$#" -le 2 ] || orbit_fail "usage: orbit config <key> [<value> | --unset]"
  local value="$2"

  # repos.* is the pool index orbit maintains, not project configuration. It is
  # rebuildable (Principle 3), but relying on that to excuse hand-editing means
  # the safety of this command rests on another principle rather than on itself.
  case "$key" in
    repos.*) orbit_fail "repos.* is pool index data, not project config; refresh it with memo <repo> --refresh" ;;
  esac

  # branch.prefix is embedded in every branch orbit has already created and is
  # what prune matches on to find them again. A bad value would persist, and a
  # changed one would orphan the existing branches — validate on write, and
  # refuse to move it while any branch still carries the current one.
  if [ "$key" = "branch.prefix" ]; then
    local target="$value" current existing
    [ "$value" = "--unset" ] && target="$ORBIT_DEFAULT_BRANCH_PREFIX"
    if ! orbit_valid_branch_prefix "$target"; then
      orbit_fail "invalid branch.prefix: $target (one path segment, valid in a git refname)"
      return 1
    fi
    current=$(orbit_require_prefix) || return 1
    if [ "$target" != "$current" ] && existing=$(orbit_branches_under_prefix "$root" "$current"); then
      orbit_fail "branch.prefix is part of existing branch names under '$current/': $existing"
      return 1
    fi
  fi

  if [ "$value" = "--unset" ]; then
    git config --file "$orbit_file" --unset "$key" 2>/dev/null || true
    printf 'unset: %s\n' "$key"
  else
    git config --file "$orbit_file" "$key" "$value"
    printf 'set: %s = %s\n' "$key" "$value"
  fi
}

# --- Context ---

# `orbit context` is the model-facing context aggregation command — its stdout
# is a readable markdown block for agents/humans, not machine data (the machine
# channel is --json). Three purpose-scoped entries:
#   --startup   session-start block; routes to prime (empty) / reignite (repos)
#   (bare)      cruise block: cheap durables + conditional per-repo status
#   <key>       single-value query: workspace|path|goal|state
# --prime / --reignite are explicit routing targets for humans and debugging;
# the skill exposes only --startup and the bare form. Fails fast outside a
# workspace (hooks treat failure as no-op).
orbit_context() {
  local json_mode=0 startup_mode=0 prime_mode=0 reignite_mode=0 query_key=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json_mode=1; shift ;;
      --startup) startup_mode=1; shift ;;
      --prime) prime_mode=1; shift ;;
      --reignite) reignite_mode=1; shift ;;
      -*) orbit_fail "usage: orbit context [<key>] [--startup|--prime|--reignite] [--json]" ;;
      *)
        if [ -z "$query_key" ]; then
          query_key="$1"
        else
          orbit_fail "usage: orbit context [<key>] [--startup|--prime|--reignite] [--json]"
        fi
        shift
        ;;
    esac
  done

  local mode_count=$(( startup_mode + prime_mode + reignite_mode ))
  [ "$mode_count" -le 1 ] || orbit_fail "--startup, --prime and --reignite are mutually exclusive"
  if [ -n "$query_key" ] && [ "$mode_count" -gt 0 ]; then
    orbit_fail "a key cannot be combined with --startup/--prime/--reignite"
  fi

  local root
  root=$(orbit_require_root) || return 1

  local ws
  ws=$(orbit_infer_workspace "$root") || return 1

  local ws_dir="$root/$ws"

  orbit_ensure_workspace_orbit "$ws_dir"

  if [ -n "$query_key" ]; then
    case "$query_key" in
      workspace) printf '%s\n' "$ws" ;;
      path)      printf '%s\n' "$ws_dir" ;;
      goal)      printf '%s\n' "$(git config --file "$ws_dir/.orbit" --get workspace.goal 2>/dev/null || true)" ;;
      state)     local s; s=$(git config --file "$ws_dir/.orbit" --get workspace.status 2>/dev/null || true); printf '%s\n' "${s:-active}" ;;
      *)         orbit_fail "unknown key: $query_key (available: workspace, path, goal, state)" ;;
    esac
    return 0
  fi

  local goal state_val
  goal=$(git config --file "$ws_dir/.orbit" --get workspace.goal 2>/dev/null || true)
  state_val=$(git config --file "$ws_dir/.orbit" --get workspace.status 2>/dev/null || true)
  [ -n "$state_val" ] || state_val="active"

  local index="$root/.repos/.orbit"

  # --startup routes on worktree presence: empty -> prime, populated -> reignite.
  if [ "$startup_mode" -eq 1 ]; then
    prime_mode=1
    local d
    for d in "$ws_dir"/*/; do
      [ -d "$d" ] || continue
      if [ -d "$d/.git" ] || [ -f "$d/.git" ]; then
        prime_mode=0
        reignite_mode=1
        break
      fi
    done
  fi

  if [ "$prime_mode" -eq 1 ]; then
    orbit_context_prime "$root" "$ws" "$ws_dir" "$goal" "$state_val" "$index" "$json_mode"
    return 0
  fi

  if [ "$reignite_mode" -eq 1 ]; then
    orbit_context_reignite "$root" "$ws" "$ws_dir" "$goal" "$state_val" "$index" "$json_mode"
    return 0
  fi

  # --- bare: cruise block (compact/resume recovery) ---
  # Cheap durables (path/goal/state — compaction may have wiped them) plus
  # conditional per-repo status (only repos with something pending). No memos,
  # no roster, no fetch — heavy durables live in --startup.
  local n c l b m br sc
  if [ "$json_mode" -eq 1 ]; then
    local out='{' first=1
    out+="$(orbit_json_kv workspace "$ws"),"
    out+="$(orbit_json_kv path "$ws_dir"),"
    out+="$(orbit_json_kv goal "$goal"),"
    out+="$(orbit_json_kv state "$state_val"),"
    out+='"mode":"cruise","worktrees":['
    while IFS='|' read -r n c l b m br sc; do
      [ -n "$n" ] || continue
      [ "$c" -gt 0 ] || [ -n "$b" ] || [ "$m" != "ok" ] || [ "$sc" = "0" ] || continue
      [ "$first" -eq 1 ] || out+=','
      first=0
      out+='{'
      out+="$(orbit_json_kv name "$n"),"
      out+="$(orbit_json_kv_raw jots "$c"),"
      out+="$(orbit_json_kv jotLevel "$l"),"
      out+="$(orbit_json_kv behind "$b"),"
      out+="$(orbit_json_kv memoState "$m"),"
      out+="$(orbit_json_kv branch "$br"),"
      out+="$(orbit_json_kv_raw scoped "$sc")"
      out+='}'
    done < <(orbit_collect_repo_status "$root" "$ws_dir")
    out+=']}'
    printf '%s\n' "$out"
    return 0
  fi

  printf 'path: %s\n' "$ws_dir"
  [ -n "$goal" ] && printf 'goal: %s\n' "$goal"
  printf 'state: %s\n' "$state_val"
  if [ "$state_val" = "done" ]; then
    printf '\n[!] this workspace is marked DONE — ask the user before continuing (reopen / prune / start elsewhere)\n'
  fi

  local first_line=1 parts
  while IFS='|' read -r n c l b m br sc; do
    [ -n "$n" ] || continue
    [ "$c" -gt 0 ] || [ -n "$b" ] || [ "$m" != "ok" ] || [ "$sc" = "0" ] || continue
    [ "$first_line" -eq 1 ] && { printf '\n'; first_line=0; }
    parts=""
    if [ "$c" -gt 0 ]; then
      if [ -n "$l" ]; then parts="$c jots ($l)"; else parts="$c jots"; fi
    fi
    if [ "$b" = "untracked" ]; then
      [ -n "$parts" ] && parts="$parts | "
      parts="${parts}no upstream (fetch origin $br to track)"
    elif [ -n "$b" ]; then
      [ -n "$parts" ] && parts="$parts | "
      parts="${parts}${b} behind upstream"
    fi
    if [ "$m" != "ok" ]; then
      [ -n "$parts" ] && parts="$parts | "
      if [ "$m" = "over" ]; then parts="${parts}memo over budget"; else parts="${parts}memo thin"; fi
    fi
    if [ "$sc" = "0" ]; then
      [ -n "$parts" ] && parts="$parts | "
      parts="${parts}raw mode branch (orbit switch -c $br to convert to scoped)"
    fi
    printf 'repo %s: %s\n' "$n" "$parts"
  done < <(orbit_collect_repo_status "$root" "$ws_dir")
}

# prime: cold start with an empty workspace — orientation block: durables plus
# the pool roster (the "add menu"). No per-repo status (no worktrees), no memos.
orbit_context_prime() {
  local root="$1" ws="$2" ws_dir="$3" goal="$4" state_val="$5" index="$6" json_mode="$7"

  local pool_names=() pool_briefs=() pool_urls=() pool_srcs=() pool_nomemo=() pool_desync=()
  local pd pname pbrief psrc purl
  for pd in "$root/.repos"/*/; do
    [ -d "$pd" ] || continue
    pname=$(basename "$pd")
    { IFS= read -r pbrief; IFS= read -r psrc || true; } <<< "$(orbit_pool_brief "$root" "$index" "$pname" "$pd")"
    if [ -z "$pbrief" ] && [ "$json_mode" -eq 0 ]; then
      pbrief="-"
    fi
    purl=$(git config --file "$index" --get "repos.$pname.url" 2>/dev/null || true)
    if [ -z "$purl" ]; then
      purl=$(git -C "$pd" remote get-url origin 2>/dev/null || true)
    fi
    pool_names+=("$pname")
    pool_briefs+=("$pbrief")
    pool_urls+=("$purl")
    pool_srcs+=("$psrc")
    case "$psrc" in
      readme|none) pool_nomemo+=("$pname") ;;
      memo)        pool_desync+=("$pname") ;;
    esac
  done

  if [ "$json_mode" -eq 1 ]; then
    local out='{' first=1 p
    out+="$(orbit_json_kv workspace "$ws"),"
    out+="$(orbit_json_kv path "$ws_dir"),"
    out+="$(orbit_json_kv goal "$goal"),"
    out+="$(orbit_json_kv state "$state_val"),"
    out+='"mode":"prime","repos":['
    for p in "${!pool_names[@]}"; do
      [ "$first" -eq 1 ] || out+=','
      first=0
      out+='{'
      out+="$(orbit_json_kv name "${pool_names[$p]}"),"
      out+="$(orbit_json_kv url "${pool_urls[$p]}"),"
      out+="$(orbit_json_kv brief "${pool_briefs[$p]}")"
      out+='}'
    done
    out+=']}'
    printf '%s\n' "$out"
    return 0
  fi

  printf 'path: %s\n' "$ws_dir"
  [ -n "$goal" ] && printf 'goal: %s\n' "$goal"
  printf 'state: %s\n' "$state_val"
  if [ "$state_val" = "done" ]; then
    printf '[!] this workspace is marked DONE — ask the user before continuing (reopen / prune / start elsewhere)\n'
  fi
  printf '\n'
  if [ "${#pool_names[@]}" -eq 0 ]; then
    printf 'pool is empty — clone a repo into the pool first: orbit clone <url>\n'
  else
    printf 'available in pool (orbit add <repo> to pull source; orbit info <repo> for detail):\n'
    local i name_w=0
    for i in "${!pool_names[@]}"; do
      [ "${#pool_names[$i]}" -gt "$name_w" ] && name_w=${#pool_names[$i]}
    done
    for i in "${!pool_names[@]}"; do
      # Fallback briefs (README extract / none) are uncurated — append the
      # remote URL as the authoritative identity hint. Curated memo/index
      # briefs stay lean.
      case "${pool_srcs[$i]}" in
        readme|none)
          if [ -n "${pool_urls[$i]}" ]; then
            printf '  %-*s %s (%s)\n' "$name_w" "${pool_names[$i]}" "${pool_briefs[$i]}" "${pool_urls[$i]}"
          else
            printf '  %-*s %s\n' "$name_w" "${pool_names[$i]}" "${pool_briefs[$i]}"
          fi
          ;;
        *)
          printf '  %-*s %s\n' "$name_w" "${pool_names[$i]}" "${pool_briefs[$i]}"
          ;;
      esac
    done
    # Steering is inlined as stdout sections — hook injection carries only
    # stdout, so notes emitted on stderr would never reach the agent
    # (docs/spec-metadata.md "Fallback Rules").
    if [ "${#pool_nomemo[@]}" -gt 0 ]; then
      printf '\nno memo (write the card via orbit memo <repo>; a README-derived brief above is a display fallback, not a memo):\n'
      printf '  %s\n' "${pool_nomemo[@]}"
    fi
    if [ "${#pool_desync[@]}" -gt 0 ]; then
      printf '\nindex out of sync (repair via orbit memo <repo> --refresh):\n'
      printf '  %s\n' "${pool_desync[@]}"
    fi
  fi
}

# reignite: session (re)start with worktrees present — rebuilds what the ignite
# phase had read: each repo's memo card + two-layer staleness (memoBehind +
# remoteAhead; fetches like `orbit info`, advisory only — sync stays on-demand),
# conditional per-repo status, and small jot queues inlined. No roster, no source.
orbit_context_reignite() {
  local root="$1" ws="$2" ws_dir="$3" goal="$4" state_val="$5" index="$6" json_mode="$7"
  local buf
  buf=$(orbit_jot_buffer_size "$root")

  local d name branch md_file default_branch stored current local_head remote_head
  local memo_behind remote_ahead count level upstream behind mstate staleness parts jline

  if [ "$json_mode" -eq 1 ]; then
    local out='{' first=1
    out+="$(orbit_json_kv workspace "$ws"),"
    out+="$(orbit_json_kv path "$ws_dir"),"
    out+="$(orbit_json_kv goal "$goal"),"
    out+="$(orbit_json_kv state "$state_val"),"
    out+='"mode":"reignite","worktrees":['
    for d in "$ws_dir"/*/; do
      [ -d "$d" ] || continue
      [ -d "$d/.git" ] || [ -f "$d/.git" ] || continue
      name=$(basename "$d")
      branch=$(git -C "$d" branch --show-current 2>/dev/null || echo "detached")
      default_branch=$(orbit_default_branch "$root/.repos/$name" 2>/dev/null || true)
      memo_behind=0 remote_ahead=0
      if [ -n "$default_branch" ]; then
        while IFS= read -r line; do
          printf 'orbit: %s: %s\n' "$name" "$line" >&2
        done < <(orbit_reconcile_fetch_refspecs "$root/.repos/$name" 0)
        git -C "$root/.repos/$name" fetch origin 2>/dev/null || true
        local_head=$(git -C "$root/.repos/$name" rev-parse "refs/heads/$default_branch" 2>/dev/null || true)
        remote_head=$(git -C "$root/.repos/$name" rev-parse "refs/remotes/origin/$default_branch" 2>/dev/null || true)
        if [ -n "$local_head" ] && [ -n "$remote_head" ] && [ "$local_head" != "$remote_head" ]; then
          remote_ahead=$(git -C "$root/.repos/$name" rev-list "$local_head".."$remote_head" --count 2>/dev/null || echo 0)
        fi
      fi
      md_file="$root/.repos/.$name.md"
      stored=$(git config --file "$index" --get "repos.$name.head" 2>/dev/null || true)
      if [ -n "$stored" ] && [ -f "$md_file" ]; then
        current=$(git -C "$root/.repos/$name" rev-parse HEAD 2>/dev/null || true)
        if [ -n "$current" ] && [ "$stored" != "$current" ]; then
          memo_behind=$(git -C "$root/.repos/$name" rev-list "$stored".."$current" --count 2>/dev/null || echo 0)
        fi
      fi
      count=$(git config --file "$ws_dir/.orbit" --get-all "jot.$name.entry" 2>/dev/null | grep -c . || true)
      [ -n "$count" ] || count=0
      level=$(orbit_jot_level "$count" "$buf")
      behind=$(orbit_repo_upstream_behind "$d")
      mstate=$(orbit_memo_state "$md_file" "$root")

      [ "$first" -eq 1 ] || out+=','
      first=0
      out+='{'
      out+="$(orbit_json_kv name "$name"),"
      out+="$(orbit_json_kv branch "$branch"),"
      out+="$(orbit_json_kv_raw memoBehind "$memo_behind"),"
      out+="$(orbit_json_kv_raw remoteAhead "$remote_ahead"),"
      out+="$(orbit_json_kv_raw jots "$count"),"
      out+="$(orbit_json_kv jotLevel "$level"),"
      out+="$(orbit_json_kv behind "$behind"),"
      out+="$(orbit_json_kv memoState "$mstate"),"
      out+='"jotEntries":['
      local ef=1
      while IFS= read -r jline; do
        [ -n "$jline" ] || continue
        [ "$ef" -eq 1 ] || out+=','
        ef=0
        out+="\"$(orbit_json_escape "$jline")\""
      done < <(git config --file "$ws_dir/.orbit" --get-all "jot.$name.entry" 2>/dev/null || true)
      out+='],'
      if [ -f "$md_file" ]; then
        out+="$(orbit_json_kv memo "$(cat "$md_file")")"
      else
        out+="$(orbit_json_kv memo "")"
      fi
      out+='}'
    done
    out+=']}'
    printf '%s\n' "$out"
    return 0
  fi

  printf 'path: %s\n' "$ws_dir"
  [ -n "$goal" ] && printf 'goal: %s\n' "$goal"
  printf 'state: %s\n\n' "$state_val"
  if [ "$state_val" = "done" ]; then
    printf '[!] this workspace is marked DONE — ask the user before continuing (reopen / prune / start elsewhere)\n\n'
  fi

  for d in "$ws_dir"/*/; do
    [ -d "$d" ] || continue
    [ -d "$d/.git" ] || [ -f "$d/.git" ] || continue
    name=$(basename "$d")
    branch=$(git -C "$d" branch --show-current 2>/dev/null || echo "detached")

    # Two-layer staleness (fetch like orbit info; advisory only, no sync).
    default_branch=$(orbit_default_branch "$root/.repos/$name" 2>/dev/null || true)
    memo_behind=0 remote_ahead=0
    if [ -n "$default_branch" ]; then
      while IFS= read -r line; do
        printf 'orbit: %s: %s\n' "$name" "$line" >&2
      done < <(orbit_reconcile_fetch_refspecs "$root/.repos/$name" 0)
      git -C "$root/.repos/$name" fetch origin 2>/dev/null || true
      local_head=$(git -C "$root/.repos/$name" rev-parse "refs/heads/$default_branch" 2>/dev/null || true)
      remote_head=$(git -C "$root/.repos/$name" rev-parse "refs/remotes/origin/$default_branch" 2>/dev/null || true)
      if [ -n "$local_head" ] && [ -n "$remote_head" ] && [ "$local_head" != "$remote_head" ]; then
        remote_ahead=$(git -C "$root/.repos/$name" rev-list "$local_head".."$remote_head" --count 2>/dev/null || echo 0)
      fi
    fi
    md_file="$root/.repos/.$name.md"
    stored=$(git config --file "$index" --get "repos.$name.head" 2>/dev/null || true)
    if [ -n "$stored" ] && [ -f "$md_file" ]; then
      current=$(git -C "$root/.repos/$name" rev-parse HEAD 2>/dev/null || true)
      if [ -n "$current" ] && [ "$stored" != "$current" ]; then
        memo_behind=$(git -C "$root/.repos/$name" rev-list "$stored".."$current" --count 2>/dev/null || echo 0)
      fi
    fi

    count=$(git config --file "$ws_dir/.orbit" --get-all "jot.$name.entry" 2>/dev/null | grep -c . || true)
    [ -n "$count" ] || count=0
    level=$(orbit_jot_level "$count" "$buf")
    behind=$(orbit_repo_upstream_behind "$d")
    mstate=$(orbit_memo_state "$md_file" "$root")
    local is_scoped
    case "$branch" in
      ws/"$ws"/*) is_scoped=1 ;;
      *) is_scoped=0 ;;
    esac

    printf -- '--- %s (branch: %s) ---\n' "$name" "$branch"
    staleness=""
    [ "$memo_behind" != "0" ] && staleness="memo is $memo_behind commits behind HEAD"
    if [ "$remote_ahead" != "0" ]; then
      [ -n "$staleness" ] && staleness="$staleness | "
      staleness="${staleness}${remote_ahead} new commits on origin/$default_branch"
    fi
    [ -n "$staleness" ] && printf 'staleness: %s\n' "$staleness"
    parts=""
    if [ "$count" -gt 0 ]; then
      if [ -n "$level" ]; then parts="$count jots ($level)"; else parts="$count jots"; fi
    fi
    if [ "$behind" = "untracked" ]; then
      [ -n "$parts" ] && parts="$parts | "
      parts="${parts}no upstream (fetch origin $branch to track)"
    elif [ -n "$behind" ]; then
      [ -n "$parts" ] && parts="$parts | "
      parts="${parts}${behind} behind upstream"
    fi
    if [ "$mstate" != "ok" ]; then
      [ -n "$parts" ] && parts="$parts | "
      if [ "$mstate" = "over" ]; then parts="${parts}memo over budget"; else parts="${parts}memo thin"; fi
    fi
    if [ "$is_scoped" = "0" ]; then
      [ -n "$parts" ] && parts="$parts | "
      parts="${parts}raw mode branch (orbit switch -c $branch to convert to scoped)"
    fi
    [ -n "$parts" ] && printf 'status: %s\n' "$parts"
    if [ "$count" -gt 0 ]; then
      if [ "$count" -le "$buf" ]; then
        printf 'jots (pop with: orbit jot %s --pop):\n' "$name"
        while IFS= read -r jline; do
          [ -n "$jline" ] || continue
          printf '  - %s\n' "$jline"
        done < <(git config --file "$ws_dir/.orbit" --get-all "jot.$name.entry" 2>/dev/null || true)
      else
        printf 'jots: %s entries queued — pop to view: orbit jot %s --pop\n' "$count" "$name"
      fi
    fi
    printf '\n'
    if [ -f "$md_file" ]; then
      printf '%s\n\n' "$(cat "$md_file")"
    else
      printf '(no memo yet — explore and write one with: orbit memo %s)\n\n' "$name"
    fi
  done
}

# --- Completion ---

orbit_completion_zsh() {
  cat <<'ZSH_EOF'
#compdef orbit
#
# Zsh completion for orbit — Git-native multi-repo workspace manager

_orbit_find_root() {
  local dir="$PWD"
  if [[ -n "${ORBIT_ROOT:-}" ]] && [[ -d "$ORBIT_ROOT/.repos" ]]; then
    printf '%s' "$ORBIT_ROOT"
    return
  fi
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/.repos" ]]; then
      printf '%s' "$dir"
      return
    fi
    dir="${dir:h}"
  done
}

_orbit_repos() {
  local root
  root=$(_orbit_find_root)
  [[ -z "$root" ]] && return
  local repos_dir="$root/.repos"
  [[ -d "$repos_dir" ]] || return
  local -a repos
  repos=("$repos_dir"/*(N/:t))
  repos=(${repos:#.*})
  compadd -a repos
}

_orbit_workspaces() {
  local root
  root=$(_orbit_find_root)
  [[ -z "$root" ]] && return
  local -a workspaces
  workspaces=("$root"/*(N/:t))
  workspaces=(${workspaces:#.repos})
  workspaces=(${workspaces:#.*})
  compadd -a workspaces
}

_orbit() {
  local -a commands
  commands=(
    'clone:Clone a repo into the source pool'
    'new:Create a new workspace'
    'add:Add a repo to current workspace'
    'switch:Switch to or create a branch'
    'sync:Sync pool repos with upstream'
    'status:Show workspace status'
    'goal:Read or set workspace goal'
    'jot:Record a discovery for later memo merge'
    'done:Mark workspace as done'
    'repos:List repos in pool'
    'info:Show repo memo'
    'memo:Write or refresh repo memos'
    'prune:Clean up done workspaces'
    'context:Show workspace context for agents'
    'config:Read or set project configuration'
    'doctor:Check environment health'
    'completion:Generate shell completion script'
    'version:Show orbit version'
  )

  _arguments -C \
    '1:command:->command' \
    '*::arg:->args'

  case "$state" in
    command)
      _describe -t commands 'orbit command' commands
      ;;
    args)
      case "$words[1]" in
        clone)
          _arguments \
            '--push[Enable push access]' \
            '--name[Set repo name]:name:' \
            '--branch[Specify branch]:branch:'
          ;;
        new)
          _arguments \
            '--name[Set workspace name]:name:' \
            '--no-goal[Create without a goal]' \
            '--exec[Execute command after creation]:command:'
          ;;
        add)
          _arguments \
            '--ref[Checkout specific ref]:ref:' \
            '(-s --silent)'{-s,--silent}'[Suppress the memo echo]' \
            '*:repo:_orbit_repos'
          ;;
        switch)
          _arguments \
            '-c[Create new branch]' \
            '*:repo:_orbit_repos'
          ;;
        sync)
          _arguments \
            '--force[Reset pool checkout to upstream, discarding local commits (project root only)]' \
            '--branch[Switch pool tracking branch (project root only)]:branch:' \
            '*:repo:_orbit_repos'
          ;;
        status)
          _arguments \
            '--json[Output as JSON]' \
            '*:workspace:_orbit_workspaces'
          ;;
        goal)
          _arguments \
            '--clear[Clear the workspace goal]'
          ;;
        jot)
          _arguments \
            '--pop[Pop all entries and clear]' \
            '--json[Output as JSON]' \
            '*:repo:_orbit_repos'
          ;;
        done)
          _arguments \
            '--pr[Include PR info]' \
            '--json[Output as JSON]'
          ;;
        repos)
          _arguments \
            '--json[Output as JSON]'
          ;;
        info)
          _arguments \
            '--json[Output as JSON]' \
            '*:repo:_orbit_repos'
          ;;
        memo)
          _arguments \
            '--refresh[Refresh memo index]' \
            '--scaffold[Generate scaffold to stdout]' \
            '*:repo:_orbit_repos'
          ;;
        context)
          _arguments \
            '1:key:(workspace path goal state)' \
            '--startup[Session-start block (routes prime/reignite)]' \
            '--prime[Cold-start block: durables + pool roster]' \
            '--reignite[Restart block: memos + per-repo status]' \
            '--json[Output as JSON]'
          ;;
        config)
          _arguments \
            '1:key:(agent.recommend memo.minLines memo.maxLines explore.paths jot.bufferSize)' \
            '2:value:'
          ;;
        completion)
          _arguments \
            '1:shell:(zsh bash)'
          ;;
        prune)
          _arguments \
            '--older[Filter by age]:days:' \
            '--dry-run[Show what would be pruned]' \
            '--force[Destroy uncommitted changes and unmerged branches]' \
            '--verify[Verify before pruning]' \
            '*:workspace:_orbit_workspaces'
          ;;
      esac
      ;;
  esac
}

_orbit "$@"
ZSH_EOF
}

orbit_completion_bash() {
  cat <<'BASH_EOF'
# Bash completion for orbit — Git-native multi-repo workspace manager

_orbit_find_root() {
  local dir="$PWD"
  if [ -n "${ORBIT_ROOT:-}" ] && [ -d "$ORBIT_ROOT/.repos" ]; then
    printf '%s' "$ORBIT_ROOT"
    return
  fi
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/.repos" ]; then
      printf '%s' "$dir"
      return
    fi
    dir=$(dirname "$dir")
  done
}

_orbit_repo_names() {
  local root
  root=$(_orbit_find_root)
  [ -z "$root" ] && return
  local repos_dir="$root/.repos"
  [ -d "$repos_dir" ] || return
  local entry
  for entry in "$repos_dir"/*/; do
    [ -d "$entry" ] || continue
    entry="${entry%/}"
    entry="${entry##*/}"
    case "$entry" in
      .*) ;;
      *) printf '%s\n' "$entry" ;;
    esac
  done
}

_orbit_workspace_names() {
  local root
  root=$(_orbit_find_root)
  [ -z "$root" ] && return
  local entry
  for entry in "$root"/*/; do
    [ -d "$entry" ] || continue
    entry="${entry%/}"
    entry="${entry##*/}"
    case "$entry" in
      .repos|.*) ;;
      *) printf '%s\n' "$entry" ;;
    esac
  done
}

_orbit_completions() {
  local cur prev cmd
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local i cmd=""
  for ((i=1; i < COMP_CWORD; i++)); do
    case "${COMP_WORDS[i]}" in
      -*) ;;
      *) cmd="${COMP_WORDS[i]}"; break ;;
    esac
  done

  if [ -z "$cmd" ]; then
    COMPREPLY=($(compgen -W "clone new add switch sync status goal jot done repos info memo prune context config doctor completion version" -- "$cur"))
    return
  fi

  case "$cmd" in
    clone)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--push --name --branch" -- "$cur"))
      fi
      ;;
    new)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--name --no-goal --exec" -- "$cur"))
      fi
      ;;
    add)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--ref -s --silent" -- "$cur"))
      else
        COMPREPLY=($(compgen -W "$(_orbit_repo_names)" -- "$cur"))
      fi
      ;;
    switch)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "-c" -- "$cur"))
      else
        COMPREPLY=($(compgen -W "$(_orbit_repo_names)" -- "$cur"))
      fi
      ;;
    sync)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--force --branch" -- "$cur"))
      else
        COMPREPLY=($(compgen -W "$(_orbit_repo_names)" -- "$cur"))
      fi
      ;;
    status)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--json" -- "$cur"))
      else
        COMPREPLY=($(compgen -W "$(_orbit_workspace_names)" -- "$cur"))
      fi
      ;;
    goal)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--clear" -- "$cur"))
      fi
      ;;
    jot)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--pop --json" -- "$cur"))
      else
        COMPREPLY=($(compgen -W "$(_orbit_repo_names)" -- "$cur"))
      fi
      ;;
    done)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--pr --json" -- "$cur"))
      fi
      ;;
    repos)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--json" -- "$cur"))
      fi
      ;;
    info)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--json" -- "$cur"))
      else
        COMPREPLY=($(compgen -W "$(_orbit_repo_names)" -- "$cur"))
      fi
      ;;
    memo)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--refresh --scaffold" -- "$cur"))
      else
        COMPREPLY=($(compgen -W "$(_orbit_repo_names)" -- "$cur"))
      fi
      ;;
    context)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--startup --prime --reignite --json" -- "$cur"))
      else
        COMPREPLY=($(compgen -W "workspace path goal state" -- "$cur"))
      fi
      ;;
    config)
      if [[ "$cur" == --* ]]; then
        COMPREPLY=($(compgen -W "--unset" -- "$cur"))
      else
        COMPREPLY=($(compgen -W "agent.recommend memo.minLines memo.maxLines explore.paths jot.bufferSize" -- "$cur"))
      fi
      ;;
    completion)
      COMPREPLY=($(compgen -W "zsh bash" -- "$cur"))
      ;;
    prune)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--older --dry-run --force --verify" -- "$cur"))
      else
        COMPREPLY=($(compgen -W "$(_orbit_workspace_names)" -- "$cur"))
      fi
      ;;
  esac
}

complete -F _orbit_completions orbit
BASH_EOF
}

orbit_completion() {
  local shell="${1:-}"
  case "$shell" in
    zsh)  orbit_completion_zsh ;;
    bash) orbit_completion_bash ;;
    *)    orbit_fail "usage: $ORBIT_CMD completion <zsh|bash>" ;;
  esac
}

# --- Dispatch ---

orbit() {
  local cmd="${1:-}"
  if [ "$#" -gt 0 ]; then shift; fi

  case "$cmd" in
    clone)      orbit_clone "$@" ;;
    new)        orbit_new "$@" ;;
    add)        orbit_add "$@" ;;
    switch)     orbit_switch "$@" ;;
    sync)       orbit_sync "$@" ;;
    status)     orbit_status "$@" ;;
    goal)       orbit_goal "$@" ;;
    jot)        orbit_jot "$@" ;;
    done)       orbit_done "$@" ;;
    repos)      orbit_repos "$@" ;;
    info)       orbit_info "$@" ;;
    memo)       orbit_memo "$@" ;;
    prune)      orbit_prune "$@" ;;
    config)     orbit_config "$@" ;;
    context)    orbit_context "$@" ;;
    doctor)     orbit_doctor "$@" ;;
    completion) orbit_completion "$@" ;;
    version|-v|--version) printf '%s\n' "$ORBIT_VERSION" ;;
    -h|--help|help|'') orbit_usage ;;
    *) orbit_fail "unknown command: $cmd" ;;
  esac
}

orbit "$@"
