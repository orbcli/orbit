#!/usr/bin/env bats
# hooks/<agent>/hooks.json wiring — every registered command must resolve to
# a script that ships in the payload. A typo or a missing wrapper file only
# surfaces at session start as a bash-127 hook error — the exact
# silent-failure shape the qoder wrapper work set out to fix — so pin the
# wiring here: parse each hooks.json, map the host's plugin-root placeholder
# onto the repo root, and assert every target exists.

REPO_ROOT="$BATS_TEST_DIRNAME/.."

# $1 = hooks.json path, $2 = the plugin-root placeholder that host injects
assert_wiring() {
  local hooks_json="$1" placeholder="$2"
  run python3 -c '
import json, os, sys
path, placeholder, root = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    doc = json.load(f)
commands = [
    h["command"]
    for groups in doc["hooks"].values()
    for group in groups
    for h in group["hooks"]
]
assert commands, "no commands registered in " + path
for cmd in commands:
    target = cmd.replace(placeholder, root)
    # commands are `bash "<script>"` — the script path sits between quotes
    parts = target.split("\"")
    script = parts[1] if len(parts) > 1 else target.split()[-1]
    assert os.path.isfile(script), "missing script: " + script
' "$hooks_json" "$placeholder" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "hooks.json wiring: claude commands resolve to shipped scripts" {
  assert_wiring "$REPO_ROOT/hooks/claude/hooks.json" '${CLAUDE_PLUGIN_ROOT}'
}

@test "hooks.json wiring: codex commands resolve to shipped scripts" {
  assert_wiring "$REPO_ROOT/hooks/codex/hooks.json" '${PLUGIN_ROOT}'
}

@test "hooks.json wiring: qoder commands resolve to shipped scripts" {
  assert_wiring "$REPO_ROOT/hooks/qoder/hooks.json" '${QODER_PLUGIN_ROOT}'
}
