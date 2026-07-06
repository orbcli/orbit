#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
LOCAL_ORBIT="$SCRIPT_DIR/orbit.sh"

# Single source knob (same semantics as `claude plugin marketplace add`). It drives
# BOTH the orbit.sh download and the plugin marketplace install. Accepts:
#   - a GitHub repo shorthand   owner/repo             -> raw.githubusercontent.com
#   - a git URL                 https://… | git@…:…    -> shallow single-file clone
#   - a local path              /… | ./… | existing dir
# Override with ORBIT_SOURCE (and ORBIT_REF for the branch/tag). Default: this
# checkout when run from a clone, else the public GitHub repo.
DEFAULT_SOURCE="orbcli/orbit"
ORBIT_REF="${ORBIT_REF:-main}"
if [ -n "${ORBIT_SOURCE:-}" ]; then
  SOURCE="$ORBIT_SOURCE"
elif [ -f "$LOCAL_ORBIT" ]; then
  SOURCE="$SCRIPT_DIR"
else
  SOURCE="$DEFAULT_SOURCE"
fi

TARGET_BIN_DIR="$HOME/.local/bin"
TARGET_HELPER="$TARGET_BIN_DIR/orbit"
# shellcheck disable=SC2016
PATH_EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'

FORCE=0
INSTALL_CLAUDE=0
INSTALL_QODER=0
INSTALL_ZSH=0
INSTALL_BASH=0
SOURCE_TYPE=""   # path | repo | url — set by classify_source

fail() { printf '%s\n' "$*" >&2; exit 1; }

cleanup() {
  [ -n "${SRC_ORBIT_TMP:-}" ] && rm -f "$SRC_ORBIT_TMP"
  [ -n "${CLONE_TMP:-}" ] && rm -rf "$CLONE_TMP"
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

usage() {
  cat <<'EOF'
usage: ./install.sh [--claude] [--qoder|--qodercli] [--zsh] [--bash] [--force]

Always installs the global `orbit` command to ~/.local/bin and ensures it is on
your PATH. Run with no flags (locally or via curl) to install just the runtime.

options:
  --claude    install the Orbit plugin into Claude Code (claude plugin ...)
  --qoder     install the Orbit plugin via the Qoder CLI (qodercli plugins ...)
  --qodercli  alias of --qoder
  --zsh       install zsh tab-completion
  --bash      install bash tab-completion
  --force     reinstall the plugin if already present
  --help      show this message

environment:
  ORBIT_SOURCE  install source: owner/repo, a git URL, or a local path
                (default: this checkout when cloned, else orbcli/orbit)
  ORBIT_REF     branch/tag for the github raw orbit.sh download (default: main)

examples:
  ./install.sh
  ./install.sh --claude --zsh
  curl -sL REMOTE/install.sh | bash
  curl -sL REMOTE/install.sh | bash -s -- --claude
  curl -sL REMOTE/install.sh | bash -s -- --claude --force
  curl -sL REMOTE/install.sh | bash -s -- --qoder
  curl -sL REMOTE/install.sh | bash -s -- --zsh
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude)   INSTALL_CLAUDE=1; shift ;;
    --qoder|--qodercli) INSTALL_QODER=1; shift ;;
    --zsh)      INSTALL_ZSH=1; shift ;;
    --bash)     INSTALL_BASH=1; shift ;;
    --force)    FORCE=1; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) printf '%s\n' "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# --- Fetch orbit.sh from $SOURCE (path: direct; repo: raw; url: sparse clone) ---
resolve_source() {
  case "$SOURCE_TYPE" in
    path)
      [ -f "$SOURCE/orbit.sh" ] || fail "orbit.sh not found in path source: $SOURCE"
      SRC_ORBIT="$SOURCE/orbit.sh"
      ;;
    repo)
      command -v curl >/dev/null 2>&1 || fail "curl is required to download orbit.sh"
      SRC_ORBIT="$(mktemp)"; SRC_ORBIT_TMP="$SRC_ORBIT"
      curl -fsSL "https://raw.githubusercontent.com/$SOURCE/$ORBIT_REF/orbit.sh" -o "$SRC_ORBIT" \
        || fail "failed to download orbit.sh from github:$SOURCE@$ORBIT_REF"
      ;;
    url)
      command -v git >/dev/null 2>&1 || fail "git is required to install from a URL source"
      CLONE_TMP="$(mktemp -d)"
      git clone --depth 1 --filter=blob:none --sparse "$SOURCE" "$CLONE_TMP" >/dev/null 2>&1 \
        || fail "failed to clone $SOURCE"
      [ -f "$CLONE_TMP/orbit.sh" ] || fail "orbit.sh not found at the top level of $SOURCE"
      SRC_ORBIT="$CLONE_TMP/orbit.sh"
      ;;
  esac
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
  rm -f "$TARGET_HELPER"
  cp -L "$SRC_ORBIT" "$TARGET_HELPER"
  chmod +x "$TARGET_HELPER"
  printf '%s\n' "Installed orbit command to: $TARGET_HELPER"
}

install_claude_plugin() {
  command -v claude >/dev/null 2>&1 || fail "claude CLI not found; install Claude Code first"
  [ "$SOURCE_TYPE" != "path" ] || [ -f "$SOURCE/.claude-plugin/marketplace.json" ] \
    || fail "marketplace manifest not found: $SOURCE/.claude-plugin/marketplace.json"
  # A path source (or --force) re-points the marketplace at itself, overriding
  # any prior network install so plugin-dev edits take effect on reinstall.
  if [ "$SOURCE_TYPE" = "path" ] || [ "$FORCE" -eq 1 ]; then
    claude plugin uninstall orbit -y >/dev/null 2>&1 || true
    claude plugin marketplace remove orbcli >/dev/null 2>&1 || true
  fi
  claude plugin marketplace add "$SOURCE" >/dev/null 2>&1 \
    || claude plugin marketplace update orbcli >/dev/null 2>&1 || true
  claude plugin install "orbit@orbcli"
  printf '%s\n' "Installed Orbit plugin into Claude Code"
}

install_qoder_plugin() {
  command -v qodercli >/dev/null 2>&1 || fail "qodercli not found; install the Qoder CLI first"
  [ "$SOURCE_TYPE" != "path" ] || [ -f "$SOURCE/.qoder-plugin/plugin.json" ] \
    || fail "plugin manifest not found: $SOURCE/.qoder-plugin/plugin.json"
  if [ "$SOURCE_TYPE" = "path" ] || [ "$FORCE" -eq 1 ]; then
    qodercli plugins uninstall "orbit@orbcli" -s user >/dev/null 2>&1 || true
    qodercli plugins marketplace remove orbcli >/dev/null 2>&1 || true
  fi
  qodercli plugins marketplace add "$SOURCE" >/dev/null 2>&1 \
    || qodercli plugins marketplace update orbcli >/dev/null 2>&1 || true
  qodercli plugins install "orbit@orbcli" -s user
  printf '%s\n' "Installed Orbit plugin via qodercli"
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

completion_hint() {
  [ "$INSTALL_ZSH" -eq 0 ] && [ "$INSTALL_BASH" -eq 0 ] || return 0
  local flag
  case "${SHELL:-}" in
    */zsh)  flag="--zsh" ;;
    */bash) flag="--bash" ;;
    *)      flag="--zsh (zsh) or --bash (bash)" ;;
  esac
  printf '%s\n' "Tab-completion not installed. To add it:"
  if [ "$SOURCE_TYPE" = "repo" ]; then
    printf '  %s\n' "curl -sL https://raw.githubusercontent.com/$SOURCE/$ORBIT_REF/install.sh | bash -s -- $flag"
  else
    printf '  %s\n' "./install.sh $flag"
  fi
}

# --- Run ---
classify_source
resolve_source
install_cli
ensure_path_export "$(detect_shell_rc)"

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
if [ "$INSTALL_QODER" -eq 1 ]; then
  install_qoder_plugin
fi

printf '%s\n' "Next steps:"
printf '  %s\n' "- Open a new shell or run: source $(detect_shell_rc)"
printf '  %s\n' "- Verify with: orbit doctor"
if [ "$INSTALL_CLAUDE" -eq 1 ]; then
  printf '  %s\n' "- In Claude Code, the Orbit skill and SessionStart hook are now active"
fi
if [ "$INSTALL_QODER" -eq 1 ]; then
  printf '  %s\n' "- In Qoder, the Orbit skill is now active"
fi
completion_hint
