#!/usr/bin/env bash
#
# Orbit — Try it now.
#
# One command → a ready Orbit workspace with two small repos wired together by a
# shared telemetry-frame contract. You then make a real cross-repo change and
# push it — no GitHub account, no network, no server. The "upstreams" are plain
# local bare repos this script builds, so `git push` just works.
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/orbcli/orbit/main/examples/demo/try.sh | bash
#   # or, from a checkout:  ./examples/demo/try.sh
#
# Override where it lands:  ORBIT_TRY_DIR=~/somewhere ./try.sh
#
set -euo pipefail

TRY_DIR="${ORBIT_TRY_DIR:-$HOME/orbit-try}"
UPSTREAM="$TRY_DIR/upstream"
BIN_DIR="$TRY_DIR/bin"          # runtime lands here so `rm -rf $TRY_DIR` wipes it too
INSTALL_URL="https://raw.githubusercontent.com/orbcli/orbit/main/install.sh"

say()  { printf '\033[36m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# Resolve install.sh source, mirroring how install.sh itself finds orbit.sh:
# prefer a co-located checkout copy (../../install.sh) so local edits take effect
# and orbit.sh resolves locally too; fall back to the published URL when piped
# (curl | bash), where $0 gives no usable path.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || SCRIPT_DIR=""
LOCAL_INSTALL=""
REPO_ROOT=""
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/../../install.sh" ]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  LOCAL_INSTALL="$REPO_ROOT/install.sh"
fi

# Run install.sh with the runtime steered into the demo dir. Uses the local
# checkout when available (so ORBIT_BIN_DIR is honored regardless of what version
# is published), else the remote. Extra args (e.g. --claude) pass through.
run_install() {
  if [ -n "$LOCAL_INSTALL" ]; then
    ORBIT_BIN_DIR="$BIN_DIR" bash "$LOCAL_INSTALL" "$@"
  else
    curl -sL "$INSTALL_URL" | ORBIT_BIN_DIR="$BIN_DIR" bash -s -- "$@"
  fi
}

# --- args -----------------------------------------------------------------
# Optionally fold the agent-plugin install into this run so the user skips a
# separate step. Qoder is an IDE — for a CLI try-out use its CLI, qodercli.
AGENT=""            # "" | claude | codex | opencode | qodercli
AGENT_INSTALL=""    # install.sh flag for the chosen agent
for arg in "$@"; do
  case "$arg" in
    --claude)           AGENT=claude;   AGENT_INSTALL=--claude ;;
    --codex)            AGENT=codex;    AGENT_INSTALL=--codex ;;
    --opencode)         AGENT=opencode; AGENT_INSTALL=--opencode ;;
    --qoder|--qodercli) AGENT=qodercli; AGENT_INSTALL=--qoder ;;
    -h|--help)
      printf '%s\n' \
        "Usage: try.sh [--claude | --codex | --opencode | --qodercli]" \
        "  (no flag)    seed the demo; print launch options for you to pick" \
        "  --claude     also install the Claude Code plugin, then launch-ready" \
        "  --codex      also install the Codex plugin, then launch-ready" \
        "  --opencode   also install the OpenCode plugin, then launch-ready" \
        "  --qodercli   also install the Qoder CLI plugin, then launch-ready"
      exit 0 ;;
    *) warn "ignoring unknown arg: $arg" ;;
  esac
done

# --- preflight ------------------------------------------------------------
command -v git >/dev/null 2>&1 || die "git is required but not found on PATH."

# If the user already has a global orbit in ~/.local/bin, a piped `curl | bash`
# non-login shell may not have that dir on PATH. Surface it before probing so we
# reuse an existing install instead of dropping a second copy into the demo dir.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH"; export PATH ;;
esac

# Isolation guard: never seed inside an existing Orbit project (would pollute a
# real .repos/ pool). Walk up from TRY_DIR's parent looking for .repos/.
guard="$(dirname "$TRY_DIR")"
while [ "$guard" != "/" ]; do
  [ -d "$guard/.repos" ] && die \
    "Refusing to run: $guard is already an Orbit project (found .repos/).
Pick a location outside any project:  ORBIT_TRY_DIR=~/orbit-try-demo $0"
  guard="$(dirname "$guard")"
done

if [ -e "$TRY_DIR" ]; then
  if [ -n "$(ls -A "$TRY_DIR" 2>/dev/null)" ]; then
    die "$TRY_DIR already exists and is not empty. Remove it or set ORBIT_TRY_DIR."
  fi
else
  mkdir -p "$TRY_DIR"
fi

# --- ensure the orbit runtime ---------------------------------------------
# "Try it now" promises zero setup. If orbit isn't already on PATH, install it
# INTO the throwaway dir ($TRY_DIR/bin) instead of polluting ~/.local/bin — then
# a single `rm -rf $TRY_DIR` at the end wipes the runtime along with everything
# else. If an agent was requested, fold its plugin into the same install
# (ORBIT_BIN_DIR steers only the runtime; the plugin still lands in the agent's
# own plugin dir, so its removal is called out separately in the hint below).
ORBIT_LOCAL=""          # set when we installed into $BIN_DIR (drives the PATH/cleanup hints)
if ! command -v orbit >/dev/null 2>&1; then
  mkdir -p "$BIN_DIR"
  if [ -n "$AGENT_INSTALL" ]; then
    say "⚙  orbit not found — installing the runtime + Orbit plugin for $AGENT into $BIN_DIR ..."
    if run_install "$AGENT_INSTALL"; then
      AGENT_INSTALL=""                      # runtime + plugin both in; skip the later pass
    else
      warn "   plugin step failed — continuing with the runtime; use the by-hand launch below."
      AGENT=""; AGENT_INSTALL=""
    fi
  else
    say "⚙  orbit not found — installing the runtime into $BIN_DIR ..."
    run_install \
      || die "orbit install failed. Install it manually, then re-run this script."
  fi
  PATH="$BIN_DIR:$PATH"; export PATH
  ORBIT_LOCAL=1
  command -v orbit >/dev/null 2>&1 \
    || die "orbit still not on PATH after install (expected $BIN_DIR/orbit)."
fi

# --- seed content (embedded so the script is self-contained) --------------
seed_navigator() {
  local d="$1"
  mkdir -p "$d"
  cat > "$d/go.mod" <<'EOF'
module github.com/orbcli/navigator

go 1.22
EOF
  cat > "$d/main.go" <<'EOF'
package main

import (
	"log"
	"net/http"
)

// navigator is the probe's onboard flight computer. It downlinks telemetry
// frames that mission-control decodes on the ground.
func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/telemetry", handleTelemetry)

	log.Println("navigator downlink live on :8080")
	log.Fatal(http.ListenAndServe(":8080", mux))
}

func handleTelemetry(w http.ResponseWriter, r *http.Request) {
	frame := Telemetry{Heading: 42.0, Altitude: 350.0, Velocity: 7.8}.Encode()
	w.Header().Set("Content-Type", "text/plain")
	_, _ = w.Write([]byte(frame))
}
EOF
  cat > "$d/telemetry.go" <<'EOF'
package main

import (
	"fmt"
	"strings"
)

// Telemetry is the probe's downlink payload.
//
// The wire format is a POSITIONAL, comma-separated frame shared with the ground
// station's decoder (mission-control/decode.js). The field order below IS the
// cross-repo contract — both ends must agree on it.
//
// Frame fields, in order: heading, altitude, velocity
type Telemetry struct {
	Heading  float64
	Altitude float64
	Velocity float64
	// TODO: downlink fuel reserve so mission-control can watch the tank burn
}

// Encode serializes a frame for downlink. Append new fields at the END —
// mission-control/decode.js parses by position, so inserting mid-frame
// silently garbles every field after it.
func (t Telemetry) Encode() string {
	fields := []string{
		fmt.Sprintf("%.1f", t.Heading),
		fmt.Sprintf("%.1f", t.Altitude),
		fmt.Sprintf("%.1f", t.Velocity),
	}
	return strings.Join(fields, ",")
}
EOF
  cat > "$d/README.md" <<'EOF'
# navigator

Flight computer service.
EOF
}

seed_mission_control() {
  local d="$1"
  mkdir -p "$d"
  cat > "$d/decode.js" <<'EOF'
// Decoder for navigator's telemetry downlink.
//
// The frame is a POSITIONAL, comma-separated contract shared with the probe's
// encoder (navigator/telemetry.go). Field order here MUST match the encoder —
// read fields by index, and only append new ones at the END.
//
// Frame fields, in order: heading, altitude, velocity
function decodeFrame(frame) {
  const parts = frame.split(",");
  return {
    heading: parseFloat(parts[0]),
    altitude: parseFloat(parts[1]),
    velocity: parseFloat(parts[2]),
    // TODO: read fuel reserve once navigator downlinks it
  };
}
EOF
  cat > "$d/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>mission-control</title>
  <style>
    body { font-family: monospace; background: #0b0f1a; color: #e6edf3; padding: 2rem; }
    .panel { font-size: 1.2rem; line-height: 1.8; }
    .label { color: #8b949e; }
  </style>
</head>
<body>
  <h1>Mission Control — Ground Station</h1>
  <div class="panel" id="telemetry">
    <div><span class="label">heading</span>: <span id="heading">—</span></div>
    <div><span class="label">altitude</span>: <span id="altitude">—</span></div>
    <div><span class="label">velocity</span>: <span id="velocity">—</span></div>
    <!-- TODO: show fuel reserve once decoded -->
  </div>

  <script src="decode.js"></script>
  <script>
    async function refresh() {
      try {
        const res = await fetch("http://localhost:8080/api/telemetry");
        const t = decodeFrame(await res.text());
        document.getElementById("heading").textContent = t.heading;
        document.getElementById("altitude").textContent = t.altitude;
        document.getElementById("velocity").textContent = t.velocity;
      } catch (e) {
        // downlink lost
      }
    }
    setInterval(refresh, 2000);
    refresh();
  </script>
</body>
</html>
EOF
  cat > "$d/README.md" <<'EOF'
# mission-control

Ground station dashboard.
EOF
}

# --- build local bare "upstreams" ----------------------------------------
build_bare() {
  local name="$1" msg="$2"
  local work="$UPSTREAM/$name"
  git init -q "$work"
  git -C "$work" -c core.hooksPath=/dev/null add .
  git -C "$work" -c core.hooksPath=/dev/null \
      -c user.email=pilot@orbit.dev -c user.name=Pilot commit -qm "$msg"
  git clone -q --bare "$work" "$UPSTREAM/$name.git"
  rm -rf "$work"
}

say "⚙  Building local upstreams in $UPSTREAM ..."
mkdir -p "$UPSTREAM"
seed_navigator       "$UPSTREAM/navigator"
seed_mission_control "$UPSTREAM/mission-control"
build_bare navigator       "initial trajectory"
build_bare mission-control "ground station online"

# --- drive orbit: clone into the pool + open a workspace ------------------
cd "$TRY_DIR"
say "⚙  Adding both repos to the Orbit pool ..."
orbit clone "$UPSTREAM/navigator.git"       >/dev/null
orbit clone "$UPSTREAM/mission-control.git" >/dev/null

GOAL="Downlink a fuel-reserve field in the telemetry frame so mission-control can watch the tank burn — keep the encoder (navigator) and decoder (mission-control) in lockstep"
say "⚙  Creating a workspace for the mission ..."
orbit new "$GOAL" --name mission >/dev/null

# --- install the agent plugin (only if orbit was already present; a fresh
#     install folded the plugin into the bootstrap above and cleared this flag) --
if [ -n "$AGENT_INSTALL" ]; then
  say "⚙  Installing the Orbit plugin for $AGENT ..."
  if run_install "$AGENT_INSTALL" >/dev/null 2>&1; then
    say "   plugin installed."
  else
    warn "   plugin install failed — falling back to manual launch instructions."
    AGENT=""
  fi
fi

# When the runtime lives in the demo dir, the user's shell doesn't have it on
# PATH — so precede each launch block with the export on its own line.
if [ -n "$ORBIT_LOCAL" ]; then
  ORBIT_PATH="export PATH=\"$BIN_DIR:\$PATH\"
    "
else
  ORBIT_PATH=""
fi

# --- assemble the agent-launch section (depends on --claude/--qodercli) ----
if [ "$AGENT" = claude ]; then
  AGENT_SECTION="── Let your agent fly it (Claude Code plugin installed) ───────────────
    # The session hook detects this workspace — no magic phrase needed.

    ${ORBIT_PATH}cd $TRY_DIR/mission && claude start
"
elif [ "$AGENT" = codex ]; then
  AGENT_SECTION="── Let your agent fly it (Codex plugin installed) ─────────────────────
    # The session hook detects this workspace — no magic phrase needed.
    # On first run, review and trust the bundled hooks in /hooks.

    ${ORBIT_PATH}cd $TRY_DIR/mission && codex start
"
elif [ "$AGENT" = opencode ]; then
  AGENT_SECTION="── Let your agent fly it (OpenCode plugin installed) ──────────────────
    # The system.transform hook detects this workspace — no magic phrase needed.

    ${ORBIT_PATH}cd $TRY_DIR/mission && opencode run start
"
elif [ "$AGENT" = qodercli ]; then
  AGENT_SECTION="── Let your agent fly it (Qoder CLI plugin installed) ─────────────────
    # The session hook detects this workspace — no magic phrase needed.

    ${ORBIT_PATH}cd $TRY_DIR/mission && qodercli start
"
else
  # Skill source dir — a plain SKILL.md tree, no plugin machinery. Point at the
  # local checkout when we have one; otherwise name the repo path to fetch.
  if [ -n "$REPO_ROOT" ]; then
    SKILL_DIR="$REPO_ROOT/skills/orbit"
  else
    SKILL_DIR="orbit repo: skills/orbit"
  fi
  AGENT_SECTION="── Let your agent fly it (skill only — no plugin required) ────────────
    # No plugin needed: install just the Orbit skill, then launch with the
    # \"orbit start\" phrase — without a session hook, the phrase is what loads
    # Orbit. Copy the skill dir into your agent's skills folder:
    #   $SKILL_DIR
    # Prefer a plugin + auto-detecting hook? Install one:
    #   curl -sL $INSTALL_URL | bash -s -- --claude      # Claude Code
    #   curl -sL $INSTALL_URL | bash -s -- --codex       # Codex
    #   curl -sL $INSTALL_URL | bash -s -- --opencode    # OpenCode
    #   curl -sL $INSTALL_URL | bash -s -- --qodercli    # Qoder CLI
    ${ORBIT_PATH}cd $TRY_DIR/mission
    <agent> \"orbit start\"        # your CLI/IDE Agent: claude, qodercli, …"
fi

# --- plugin uninstall: the agent plugin lives in the agent, not $TRY_DIR, so
#     `rm -rf $TRY_DIR` can't reach it — name its removal explicitly ---
if [ "$AGENT" = claude ]; then
  PLUGIN_UNINSTALL="    claude plugin uninstall orbit                     # Orbit plugin (lives in Claude Code)"
elif [ "$AGENT" = codex ]; then
  PLUGIN_UNINSTALL="    codex plugin remove orbit@orbcli                  # Orbit plugin (lives in Codex)"
elif [ "$AGENT" = opencode ]; then
  PLUGIN_UNINSTALL="    rm ~/.config/opencode/plugins/orbit.ts ~/.config/opencode/skills/orbit/SKILL.md   # Orbit plugin (lives in OpenCode)"
elif [ "$AGENT" = qodercli ]; then
  PLUGIN_UNINSTALL="    qodercli plugins uninstall orbit@orbcli -s user   # Orbit plugin (lives in Qoder)"
else
  PLUGIN_UNINSTALL=""
fi

# --- hand off -------------------------------------------------------------
cat <<GUIDE

$(printf '\033[32m✓ Ready.\033[0m Two repos in the pool, one workspace waiting: %s/mission\n' "$TRY_DIR")

The mission: add a "fuel" reading to the telemetry downlink. The frame is a
POSITIONAL, comma-separated contract shared by two repos — append the new field
at the END in BOTH, or the ground station decodes garbage. That contract is
invisible from either repo alone. This is the thing Orbit is for.

$AGENT_SECTION
    # The agent commits locally, then pauses for your OK before pushing.

── …or do it by hand ─────────────────────────────────────────────────
    ${ORBIT_PATH}cd $TRY_DIR/mission
    orbit add navigator
    orbit add mission-control

    # 1. navigator/telemetry.go  — add a Fuel field to the struct AND append
    #    it in Encode():  fmt.Sprintf("%.1f", t.Fuel)
    # 2. mission-control/decode.js — read parts[3] as fuel
    # then, in each repo:
    #    git checkout -b add-fuel-reserve
    #    git commit -am "Downlink/decode fuel reserve"
    #    git push origin add-fuel-reserve     # pushes to your local upstream

    orbit done

── When you're done exploring ────────────────────────────────────────
    rm -rf $TRY_DIR${ORBIT_LOCAL:+          # repos, workspace, and the orbit runtime}
${PLUGIN_UNINSTALL:+$PLUGIN_UNINSTALL
    # or nuke everything at once:}
    #   ./install.sh --uninstall --all
GUIDE
