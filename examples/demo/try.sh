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
INSTALL_URL="https://raw.githubusercontent.com/orbcli/orbit/main/install.sh"

say()  { printf '\033[36m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# --- args -----------------------------------------------------------------
# Optionally fold the agent-plugin install into this run so the user skips a
# separate step. Qoder is an IDE — for a CLI try-out use its CLI, qodercli.
AGENT=""            # "" | claude | qodercli
AGENT_INSTALL=""    # install.sh flag for the chosen agent
for arg in "$@"; do
  case "$arg" in
    --claude)           AGENT=claude;   AGENT_INSTALL=--claude ;;
    --qoder|--qodercli) AGENT=qodercli; AGENT_INSTALL=--qoder ;;
    -h|--help)
      printf '%s\n' \
        "Usage: try.sh [--claude | --qodercli]" \
        "  (no flag)    seed the demo; print launch options for you to pick" \
        "  --claude     also install the Claude Code plugin, then launch-ready" \
        "  --qodercli   also install the Qoder CLI plugin, then launch-ready"
      exit 0 ;;
    *) warn "ignoring unknown arg: $arg" ;;
  esac
done

# --- preflight ------------------------------------------------------------
command -v git >/dev/null 2>&1 || die "git is required but not found on PATH."
command -v orbit >/dev/null 2>&1 || die \
  "orbit not found on PATH. Install it first:
    curl -sL https://raw.githubusercontent.com/orbcli/orbit/main/install.sh | bash"

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

# --- optionally fold in the agent-plugin install --------------------------
if [ -n "$AGENT_INSTALL" ]; then
  say "⚙  Installing the Orbit plugin for $AGENT ..."
  if curl -sL "$INSTALL_URL" | bash -s -- "$AGENT_INSTALL" >/dev/null 2>&1; then
    say "   plugin installed."
  else
    warn "   plugin install failed — falling back to manual launch instructions."
    AGENT=""
  fi
fi

# --- assemble the agent-launch section (depends on --claude/--qodercli) ----
if [ "$AGENT" = claude ]; then
  AGENT_SECTION="── Let your agent fly it (Claude Code plugin installed) ───────────────
    # The session hook detects this workspace — no magic phrase needed.

    cd $TRY_DIR/mission && claude start
"
elif [ "$AGENT" = qodercli ]; then
  AGENT_SECTION="── Let your agent fly it (Qoder CLI plugin installed) ─────────────────
    # The session hook detects this workspace — no magic phrase needed.

    cd $TRY_DIR/mission && qodercli start
"
else
  AGENT_SECTION="── Let your agent fly it (needs a plugin: Claude Code or Qoder CLI) ────
    # One-time: install the Orbit plugin so the agent knows Orbit — it adds the
    # skill + the session hook that detects this workspace. Pick your agent
    # (or re-run this script with --claude / --qodercli to fold it in):
    #   curl -sL $INSTALL_URL | bash -s -- --claude      # Claude Code
    #   curl -sL $INSTALL_URL | bash -s -- --qodercli    # Qoder CLI
    cd $TRY_DIR/mission
    claude start          # Claude Code
    # or: qodercli start  # Qoder CLI"
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
    cd $TRY_DIR/mission
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
    rm -rf $TRY_DIR

GUIDE
