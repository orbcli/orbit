#!/usr/bin/env bash
# Orbit SessionStart hook (startup matcher).
# Thin wrapper: all workspace-context logic lives in `orbit context --startup`;
# this script only injects the command's markdown output, wrapped in
# <orbit-context> tags so the agent can tell hook-injected context from
# self-invoked output.
# For SessionStart, stdout is injected directly into the model's context.
# - orbit installed + inside a workspace -> inject workspace startup block
# - orbit installed + not in a workspace -> no output (no-op; --startup fails fast)
# - orbit not installed                  -> prompt to install the runtime

if ! command -v orbit >/dev/null 2>&1; then
  cat <<'EOF'
The Orbit skill is installed but the `orbit` command is not on your PATH.
Orbit needs its runtime to work. Ask the user to install it, then start a new session:

  curl -sL https://raw.githubusercontent.com/orbcli/orbit/main/install.sh | bash

Only if the user explicitly says they do not want Orbit, remove this plugin
via your agent's plugin manager (e.g. `claude plugin uninstall orbit` or
`qodercli plugins uninstall orbit`).
EOF
  exit 0
fi

if out=$(orbit context --startup 2>/dev/null) && [ -n "$out" ]; then
  printf '<orbit-context>\n%s\n</orbit-context>\n' "$out"
fi
exit 0
