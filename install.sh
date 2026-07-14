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

# Where the `orbit` runtime lands. Defaults to ~/.local/bin; override with
# ORBIT_BIN_DIR to install into a caller-managed dir (e.g. a throwaway demo dir).
# A custom dir also means the caller owns PATH + cleanup, so the rc is left alone.
TARGET_BIN_DIR="${ORBIT_BIN_DIR:-$HOME/.local/bin}"
TARGET_HELPER="$TARGET_BIN_DIR/orbit"
# shellcheck disable=SC2016
PATH_EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'

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
  --force     refresh an already-installed plugin: update it in place where the
              agent supports it, otherwise remove and reinstall. Without --force,
              install only adds/refreshes the marketplace and installs — it never
              removes an existing plugin.
  --help      show this message

uninstall:
  --uninstall  uninstall mode (must be combined with at least one target)
  --cli        uninstall the orbit runtime (~/.local/bin/orbit)
  --all        uninstall everything (runtime + all plugins + completions)

environment:
  ORBIT_SOURCE  install source: owner/repo, a git URL, or a local path
                (default: this checkout when cloned, else orbcli/orbit)
  ORBIT_REF     branch/tag for the github raw orbit.sh download (default: main)

examples:
  ./install.sh
  ./install.sh --claude --zsh
  ./install.sh --uninstall --claude --codex
  ./install.sh --uninstall --all
  curl -sL REMOTE/install.sh | bash
  curl -sL REMOTE/install.sh | bash -s -- --claude
  curl -sL REMOTE/install.sh | bash -s -- --codex
  curl -sL REMOTE/install.sh | bash -s -- --claude --force
  curl -sL REMOTE/install.sh | bash -s -- --opencode
  curl -sL REMOTE/install.sh | bash -s -- --qoder
  curl -sL REMOTE/install.sh | bash -s -- --zsh
  curl -sL REMOTE/install.sh | bash -s -- --claude --zsh --force
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
  if [ -f "$TARGET_HELPER" ] && [ "$FORCE" -eq 0 ]; then
    printf '%s\n' "orbit runtime already installed at $TARGET_HELPER — skipping (use --force to reinstall)"
    return 0
  fi
  rm -f "$TARGET_HELPER"
  cp -L "$SRC_ORBIT" "$TARGET_HELPER"
  chmod +x "$TARGET_HELPER"
  printf '%s\n' "Installed orbit command to: $TARGET_HELPER"
}

install_claude_plugin() {
  command -v claude >/dev/null 2>&1 || fail "claude CLI not found; install Claude Code first"
  [ "$SOURCE_TYPE" != "path" ] || [ -f "$SOURCE/.claude-plugin/marketplace.json" ] \
    || fail "marketplace manifest not found: $SOURCE/.claude-plugin/marketplace.json"
  # Point the marketplace at $SOURCE (fresh add) or refresh an existing snapshot.
  claude plugin marketplace add "$SOURCE" >/dev/null 2>&1 \
    || claude plugin marketplace update orbcli >/dev/null 2>&1 || true
  # Claude has no `plugin update`, so --force is a remove-then-install; a refreshed
  # marketplace snapshot (above) is what actually carries new content. Plain install
  # never removes — it just (re)installs, which is a no-op if already present.
  if [ "$FORCE" -eq 1 ]; then
    claude plugin uninstall claude-orbit -y >/dev/null 2>&1 || true
  fi
  claude plugin install "claude-orbit@orbcli"
  printf '%s\n' "Installed Orbit plugin into Claude Code"
}

install_qoder_plugin() {
  command -v qodercli >/dev/null 2>&1 || fail "qodercli not found; install the Qoder CLI first"
  [ "$SOURCE_TYPE" != "path" ] || [ -f "$SOURCE/.qoder-plugin/plugin.json" ] \
    || fail "plugin manifest not found: $SOURCE/.qoder-plugin/plugin.json"
  # Point the marketplace at $SOURCE (fresh add) or refresh an existing snapshot.
  qodercli plugins marketplace add "$SOURCE" >/dev/null 2>&1 \
    || qodercli plugins marketplace update orbcli >/dev/null 2>&1 || true
  if [ "$FORCE" -eq 1 ]; then
    # qodercli has a real `plugins update`, so --force updates in place first;
    # only fall back to remove-then-install if the update path does not apply
    # (e.g. the plugin is not installed yet).
    if qodercli plugins update "qoder-orbit@orbcli" -s user >/dev/null 2>&1; then
      printf '%s\n' "Updated Orbit plugin via qodercli"
      return 0
    fi
    qodercli plugins uninstall "qoder-orbit@orbcli" -s user >/dev/null 2>&1 || true
  fi
  # Plain install never removes; it just installs (no-op if already present).
  qodercli plugins install "qoder-orbit@orbcli" -s user
  printf '%s\n' "Installed Orbit plugin via qodercli"
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
  # Point the marketplace at $SOURCE (fresh add) or refresh an existing snapshot.
  codex plugin marketplace add "$SOURCE" >/dev/null 2>&1 \
    || codex plugin marketplace upgrade orbcli >/dev/null 2>&1 || true
  # Codex has no `plugin update`, so --force is a remove-then-install; the refreshed
  # marketplace snapshot (above) is what carries new content. Plain install never
  # removes — `plugin add` is a no-op if already present.
  if [ "$FORCE" -eq 1 ]; then
    codex plugin remove "codex-orbit@orbcli" >/dev/null 2>&1 || true
  fi
  codex plugin add "codex-orbit@orbcli"
  printf '%s\n' "Installed Orbit plugin into Codex"
}

install_opencode_plugin() {
  local plugin_src skill_src
  case "$SOURCE_TYPE" in
    path)
      plugin_src="$SOURCE/.opencode-plugin/plugin.ts"
      skill_src="$SOURCE/skills/orbit/SKILL.md"
      ;;
    repo)
      plugin_src="$(mktemp)"; OC_PLUGIN_TMP="$plugin_src"
      skill_src="$(mktemp)"; OC_SKILL_TMP="$skill_src"
      curl -fsSL "https://raw.githubusercontent.com/$SOURCE/$ORBIT_REF/.opencode-plugin/plugin.ts" -o "$plugin_src" \
        || fail "failed to download plugin.ts from github:$SOURCE@$ORBIT_REF"
      curl -fsSL "https://raw.githubusercontent.com/$SOURCE/$ORBIT_REF/skills/orbit/SKILL.md" -o "$skill_src" \
        || fail "failed to download SKILL.md from github:$SOURCE@$ORBIT_REF"
      ;;
    url)
      plugin_src="$CLONE_TMP/.opencode-plugin/plugin.ts"
      skill_src="$CLONE_TMP/skills/orbit/SKILL.md"
      ;;
  esac

  [ -f "$plugin_src" ] || fail "plugin.ts not found: $plugin_src"
  [ -f "$skill_src" ] || fail "SKILL.md not found: $skill_src"

  local plugin_dir="$HOME/.config/opencode/plugins"
  local skill_dir="$HOME/.config/opencode/skills/orbit"

  mkdir -p "$plugin_dir" "$skill_dir"

  # OpenCode has no marketplace/CLI — the plugin is a copied file. Mirror the
  # install vs --force policy of the CLI agents:
  #   plain install : skip if already present (never delete), else copy in.
  #   --force        : remove the old file, then copy the current one (reinstall).
  if [ -f "$plugin_dir/orbit.ts" ] && [ "$FORCE" -eq 0 ]; then
    printf '%s\n' "OpenCode plugin already installed at $plugin_dir/orbit.ts — skipping (use --force to reinstall)"
    return 0
  fi
  if [ "$FORCE" -eq 1 ]; then
    rm -f "$plugin_dir/orbit.ts"
  fi

  cp "$plugin_src" "$plugin_dir/orbit.ts"
  cp "$skill_src" "$skill_dir/SKILL.md"

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

completion_hint() {
  [ "$INSTALL_ZSH" -eq 0 ] && [ "$INSTALL_BASH" -eq 0 ] || return 0
  local flag
  case "${SHELL:-}" in
    */zsh)  flag="--zsh" ;;
    */bash) flag="--bash" ;;
    *)      flag="--zsh (zsh) or --bash (bash)" ;;
  esac
  printf '%s\n' "To install shell tab-completion:"
  if [ "$SOURCE_TYPE" = "repo" ]; then
    printf '  %s\n' "curl -sL https://raw.githubusercontent.com/$SOURCE/$ORBIT_REF/install.sh | bash -s -- $flag"
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
  claude plugin uninstall claude-orbit -y >/dev/null 2>&1 || true
  claude plugin marketplace remove orbcli >/dev/null 2>&1 || true
  printf '%s\n' "Removed Orbit plugin from Claude Code"
}

uninstall_codex_plugin() {
  command -v codex >/dev/null 2>&1 || { printf '%s\n' "codex CLI not found — skipping"; return 0; }
  codex plugin remove "codex-orbit@orbcli" >/dev/null 2>&1 || true
  codex plugin marketplace remove orbcli >/dev/null 2>&1 || true
  printf '%s\n' "Removed Orbit plugin from Codex"
}

uninstall_qoder_plugin() {
  command -v qodercli >/dev/null 2>&1 || { printf '%s\n' "qodercli not found — skipping"; return 0; }
  qodercli plugins uninstall "qoder-orbit@orbcli" -s user >/dev/null 2>&1 || true
  qodercli plugins marketplace remove orbcli >/dev/null 2>&1 || true
  printf '%s\n' "Removed Orbit plugin from Qoder"
}

uninstall_opencode_plugin() {
  rm -f "$HOME/.config/opencode/plugins/orbit.ts"
  rm -f "$HOME/.config/opencode/skills/orbit/SKILL.md"
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
