#!/usr/bin/env bash
# Orbit SessionStart hook.
# For SessionStart, stdout is injected directly into the model's context.
# - orbit installed + inside a workspace -> inject workspace context
# - orbit installed + not in a workspace -> no output (no-op)
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

if ws=$(orbit context path 2>/dev/null) && [ -n "$ws" ]; then
  printf 'Detected an orbit workspace (%s) — treat this as an "orbit start" / "orbit启动" session.\nYou MUST invoke the orbit skill (via the Skill tool) as your first action, before replying — then apply Orbit conventions for the whole session.\n\n' "$ws"

  # Cold start vs resume. A workspace with no repos needs priming — orientation
  # so the agent can choose and add repos. A populated one means the agent is
  # picking up prior work, so re-dumping the repo roster is noise; nudge it to
  # continue, detail on demand. `orbit status` already knows the worktree roster:
  # populated JSON contains `"worktrees":[{`, empty is `"worktrees":[]`. Prime is
  # the safe default, so we only skip it on a positive populated match.
  if orbit status --json 2>/dev/null | grep -qF '"worktrees":[{'; then
    goal=$(orbit context goal 2>/dev/null || true)
    printf 'Resuming — repos already in this workspace. Continue the prior task; do not re-survey the repos.\n'
    [ -n "$goal" ] && printf 'goal: %s\n' "$goal"
    printf 'Detail on demand: orbit status (branches / dirty state) · orbit context (full repo memos) · orbit info <repo> (one repo) · orbit context --prime (residual jots from last session).\n'
    # Surface memo debt that a compaction may have wiped from working memory: repos
    # still with no real memo (only a [seed] placeholder). Explicit so the agent
    # re-engages before done rather than silently leaving the pool with no context.
    gaps=$(orbit context gaps 2>/dev/null | paste -sd ', ' - 2>/dev/null || true)
    [ -n "$gaps" ] && printf 'Memo debt — no real memo yet for: %s. Explore + jot + write a memo for these before done.\n' "$gaps"
  else
    orbit context --prime 2>/dev/null || true
  fi
fi
exit 0
