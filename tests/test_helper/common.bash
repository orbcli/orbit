#!/usr/bin/env bash
#
# Shared test helpers for orbit bats-core test suite.
# Loaded by each .bats file via: load test_helper/common
#

# Hermetic git identity so tests don't depend on the runner's global git config
# (CI runners have none, which makes `git commit` fail with status 128).
export GIT_AUTHOR_NAME="orbit-test"
export GIT_AUTHOR_EMAIL="orbit-test@example.com"
export GIT_COMMITTER_NAME="orbit-test"
export GIT_COMMITTER_EMAIL="orbit-test@example.com"

# --- Setup / Teardown ---

common_setup() {
  ORBIT_CMD="${BATS_TEST_DIRNAME}/../orbit.sh"
  SANDBOX="$(mktemp -d)"
  REMOTES="$SANDBOX/remotes"
  mkdir -p "$REMOTES"
  export TEST_PROJECT=""
  # Isolate tests from any real orbit project that may exist in parent dirs.
  cd "$SANDBOX"
}

common_teardown() {
  rm -rf "$SANDBOX"
}

# --- Orbit wrapper ---

orbit() {
  if [ -z "${TEST_PROJECT:-}" ]; then
    echo "orbit test helper: TEST_PROJECT is not set; refusing to run without an isolated project root" >&2
    return 1
  fi
  ORBIT_ROOT="$TEST_PROJECT" bash "$ORBIT_CMD" "$@"
}

# --- Assertion helpers ---

assert_contains() {
  local haystack="$1" needle="$2"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    return 0
  else
    echo "assert_contains failed"
    echo "  expected to contain: $needle"
    echo "  actual: $haystack"
    return 1
  fi
}

assert_file_exists() {
  local path="$1"
  if [ -e "$path" ]; then
    return 0
  else
    echo "assert_file_exists failed: not found: $path"
    return 1
  fi
}

assert_dir_exists() {
  local path="$1"
  if [ -d "$path" ]; then
    return 0
  else
    echo "assert_dir_exists failed: not a directory: $path"
    return 1
  fi
}

# --- Mock repo utilities ---

create_bare_repo() {
  local path="$1" name="${2:-mock}"
  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_XXXXXX")
  git init --bare "$path" >/dev/null 2>&1
  git clone "$path" "$tmp" >/dev/null 2>&1
  (
    cd "$tmp"
    git checkout -b main >/dev/null 2>&1
    printf '# %s\n\nA mock repository for testing.\n' "$name" > README.md
    git add README.md >/dev/null 2>&1
    git commit -m "initial commit" >/dev/null 2>&1
    git push origin main >/dev/null 2>&1
  )
  rm -rf "$tmp"
  git -C "$path" symbolic-ref HEAD refs/heads/main
}

create_empty_bare_repo() {
  git init --bare "$1" >/dev/null 2>&1
  git -C "$1" symbolic-ref HEAD refs/heads/main
}

# Bare repo whose ONLY branch is a non-standard default (e.g. develop) — no
# main/master. Mirrors a real remote whose default isn't main/master.
create_bare_repo_default() {
  local path="$1" branch="$2"
  git init --bare "$path" >/dev/null 2>&1
  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_XXXXXX")
  git clone "$path" "$tmp" >/dev/null 2>&1
  (
    cd "$tmp"
    git checkout -b "$branch" >/dev/null 2>&1
    printf '# %s\n' "$branch" > README.md
    git add README.md >/dev/null 2>&1
    git commit -m "initial commit" >/dev/null 2>&1
    git push origin "$branch" >/dev/null 2>&1
  )
  rm -rf "$tmp"
  git -C "$path" symbolic-ref HEAD "refs/heads/$branch"
}

create_bare_repo_with_branch() {
  local path="$1" branch="$2"
  create_bare_repo "$path" "$(basename "$path" .git)"
  local tmp
  tmp=$(mktemp -d "$SANDBOX/_tmp_XXXXXX")
  git clone "$path" "$tmp" >/dev/null 2>&1
  (
    cd "$tmp"
    git checkout -b "$branch" >/dev/null 2>&1
    echo "branch content" > branch-file.txt
    git add branch-file.txt >/dev/null 2>&1
    git commit -m "add branch content" >/dev/null 2>&1
    git push origin "$branch" >/dev/null 2>&1
  )
  rm -rf "$tmp"
}

# --- Shared file-level fixtures ---

ensure_shared_remote() {
  if [[ -n "${SHARED_REMOTE:-}" && -d "$SHARED_REMOTE" ]]; then
    return
  fi
  SHARED_REMOTE="$BATS_FILE_TMPDIR/shared_remote.git"
  local SANDBOX="$BATS_FILE_TMPDIR"
  create_bare_repo "$SHARED_REMOTE" "shared"
  export SHARED_REMOTE
}

ensure_shared_remote_with_branch() {
  ensure_shared_remote
  if [[ -n "${SHARED_REMOTE_WITH_BRANCH:-}" && -d "$SHARED_REMOTE_WITH_BRANCH" ]]; then
    return
  fi
  SHARED_REMOTE_WITH_BRANCH="$BATS_FILE_TMPDIR/shared_remote_branch.git"
  local SANDBOX="$BATS_FILE_TMPDIR"
  create_bare_repo_with_branch "$SHARED_REMOTE_WITH_BRANCH" "feature-x"
  local tmp
  tmp=$(mktemp -d "$BATS_FILE_TMPDIR/_tmp_XXXXXX")
  git clone "$SHARED_REMOTE_WITH_BRANCH" "$tmp" >/dev/null 2>&1
  (
    cd "$tmp"
    git checkout -b feature-y >/dev/null 2>&1
    echo "branch-y content" > branch-y-file.txt
    git add branch-y-file.txt >/dev/null 2>&1
    git commit -m "add branch-y content" >/dev/null 2>&1
    git push origin feature-y >/dev/null 2>&1
  )
  rm -rf "$tmp"
  export SHARED_REMOTE_WITH_BRANCH
}

ensure_shared_project() {
  ensure_shared_remote
  if [[ -n "${SHARED_PROJECT:-}" && -d "$SHARED_PROJECT" ]]; then
    return
  fi
  SHARED_PROJECT="$BATS_FILE_TMPDIR/shared_project"
  mkdir -p "$SHARED_PROJECT/.repos"
  touch "$SHARED_PROJECT/.repos/.orbit"
  ORBIT_ROOT="$SHARED_PROJECT" bash "${BATS_TEST_DIRNAME}/../orbit.sh" clone "$SHARED_REMOTE" --name myrepo >/dev/null 2>&1
  export SHARED_PROJECT
}

ensure_shared_project_with_branch() {
  ensure_shared_remote_with_branch
  ensure_shared_project
  if [[ -n "${SHARED_PROJECT_WITH_BRANCH:-}" && -d "$SHARED_PROJECT_WITH_BRANCH" ]]; then
    return
  fi
  SHARED_PROJECT_WITH_BRANCH="$BATS_FILE_TMPDIR/shared_project_branch"
  mkdir -p "$SHARED_PROJECT_WITH_BRANCH/.repos"
  touch "$SHARED_PROJECT_WITH_BRANCH/.repos/.orbit"
  ORBIT_ROOT="$SHARED_PROJECT_WITH_BRANCH" bash "${BATS_TEST_DIRNAME}/../orbit.sh" clone "$SHARED_REMOTE_WITH_BRANCH" --name myrepo >/dev/null 2>&1
  export SHARED_PROJECT_WITH_BRANCH
}

# Copy a pre-built project template into dest. Faster than orbit clone per test.
# Usage: clone_project <dest> [template]
# template defaults to $SHARED_PROJECT
clone_project() {
  local dest="$1" template="${2:-$SHARED_PROJECT}"
  cp -R "$template" "$dest"
  TEST_PROJECT="$dest"
}

# Create a mutable copy of the shared bare repo (for tests that push to remote).
clone_remote() {
  local dest="$1" source="${2:-$SHARED_REMOTE}"
  cp -R "$source" "$dest"
}
