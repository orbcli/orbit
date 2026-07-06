# Orbit Usage

Orbit uses a `project root + .repos/ + workspace` directory model to manage multi-repo workspaces.

## 1. Basic Structure

```text
project-root/
  .repos/
    .orbit              ← Global index
    .backend.md         ← Per-repo memo
    backend/            ← Primary repo
    frontend/
  task-01/
    .orbit              ← Workspace metadata (goal, created, status)
    backend/            ← Worktree
    frontend/
  task-02/
    .orbit
    backend/
```

Where:
- `.repos/` stores the primary copy and metadata for each repo
- `task-01/`, `task-02/` are workspaces, isolated by task
- `<workspace>/<repo>` is the actual development directory, corresponding to a Git worktree

## 2. Prerequisites

You can run directly:

```bash
./orbit.sh <command>
```

The following assumes `orbit` as the command name. For global installation:

```bash
./install.sh --zsh
```

If you use bash, change to `--bash`. To overwrite an existing installation, add `--force`.

## 3. Adding Repos to the Pool

No separate `init` command is needed — the first `clone` or `new` automatically initializes the project root.

```bash
orbit clone <url>
orbit clone <url> --push <fork-url>
orbit clone <url> --name <identity>
orbit clone <url> --branch <branch>
```

Common examples:

```bash
orbit clone git@github.com:org/backend.git
orbit clone git@github.com:org/backend.git --push git@github.com:me/backend.git
orbit clone git@github.com:kubernetes/kubernetes.git
```

`--push` sets the fork push URL (`git push` pushes to fork, `git fetch` pulls from upstream).
`--name` overrides the default repo identity (defaults to URL basename), used when basename is unsuitable as a directory name.
`--branch` specifies the default branch at clone time (passed to `git clone --branch`), used when only a specific branch is needed.

View repos already in the pool:

```bash
orbit repos
```

Output format:
```
NAME             URL                                     BRIEF
backend          git@github.com:org/backend.git          Go REST API, sqlc-generated DB layer
frontend         git@github.com:org/frontend.git         React SPA, consumes backend API
```

View detailed memo of a specific repo:

```bash
orbit info backend
```

`orbit info` automatically fetches upstream and detects two layers of staleness:
- **Pool behind upstream**: stderr shows `N new commits on origin/main`, run `orbit sync` to synchronize
- **Memo behind pool HEAD**: stderr shows `memo is N commits behind HEAD`, consider updating memo

### Syncing Pool Repos

```bash
orbit sync backend               # fast-forward to upstream latest
orbit sync backend --force        # force align (when local has diverged)
orbit sync backend --branch release-1.30   # switch tracking branch
orbit sync                        # sync all pool repos (at project root)
```

Scope is inferred from CWD: project root → all repos; workspace → repos in that workspace; worktree → that single repo. You can also specify repo names explicitly.

## 4. Creating a Workspace

```bash
orbit new "Modify API definition and update frontend calls"
orbit new "Debug release-1.29 performance issue" --name perf-debug
orbit new "Refactor auth module" --exec "claude"
echo "Modify API definition" | orbit new                 # Read goal from stdin (pipe-friendly)
orbit new                                     # Open editor to input goal (similar to git commit)
```

Behavior:
- Creates a workspace directory (defaults to `task-01`, `task-02`...)
- Writes `.orbit` file recording goal and creation time
- If `agent.recommend` is configured, recommends a launch command; otherwise just prompts `cd <workspace>`

### Agent Launch

After `orbit new` creates a workspace:

- `--exec "cmd"`: **immediately starts** the agent in the new workspace
- No `--exec` but `agent.recommend` is configured: **recommends** launch command in next steps (does not auto-execute)
- Neither: just prompts `cd <workspace>`

It's recommended to configure `agent.recommend` after project initialization, so each `orbit new` recommends the correct launch command:

```bash
orbit config agent.recommend 'claude "orbit start"'
```

After configuration, `orbit new "goal"` outputs:

```
created workspace: task-01
  goal: goal

  cd task-01 && claude "orbit start"

Godspeed.
```

Copy and run the recommended command to launch the agent. The agent triggers orbit skill startup detection through the initial prompt, reads context, and starts working.

Common configuration examples:

```bash
# Claude Code
orbit config agent.recommend 'claude "orbit start"'

# Qoder
orbit config agent.recommend 'qoder "orbit start"'

# Custom launch
orbit config agent.recommend 'claude --model sonnet "orbit start"'
```

## 5. Adding Repos to a Workspace

Execute within a workspace:

```bash
cd task-01/
orbit add backend
orbit add frontend
```

Specify a particular tag or branch as starting point:

```bash
orbit add backend --ref v2.1.0
orbit add backend --ref release-1.29
```

Notes:
- Workspace is auto-inferred from CWD (no need to pass explicitly)
- Defaults to creating worktree using the repo's default remote branch
- `--ref <tag/branch>` specifies the checkout starting point (tag or remote branch)
- The created local branch is `ws/<workspace>/<default-branch>` (e.g., `ws/task-01/main`)
- This is the local starting point; the agent branches off from here

## 6. Branch Operations

### Raw Mode (default)

After `orbit add`, use all native git commands; orbit does not participate in branch management:

```bash
cd task-01/backend/
git checkout -b feature/api-refactor
# work, commit
git push origin feature/api-refactor
```

### Scoped Mode (when branch isolation is needed)

Create a new tracking branch from current HEAD:

```bash
orbit switch -c feat-api-refactor
# → Creates ws/task-01/feat-api-refactor
# → Sets upstream → origin/feat-api-refactor (local only, no push)
# → Remote branch is only created on first git push
```

Switch to an existing remote branch:

```bash
orbit switch hotfix-123
# → fetch origin/hotfix-123
# → Creates ws/task-01/hotfix-123 tracking it
```

When executing from workspace root, specify the repo:

```bash
cd task-01/
orbit switch backend feat-api-refactor
orbit switch -c frontend new-feature
```

In scoped mode, `git push` automatically pushes to the correct remote branch (without prefix):

```bash
git push
# → ws/task-01/feat-api-refactor pushes to origin/feat-api-refactor
```

## 7. Viewing Status

```bash
orbit status              # Current workspace (inferred from CWD)
orbit status task-01      # Specify when at project root
```

View/set workspace goal:

```bash
orbit goal                # Read
orbit goal "new goal"     # Set/update
echo "new goal" | orbit goal   # Set from stdin (pipe-friendly)
orbit goal --clear        # Delete goal
```

## 8. Managing Repo Memos

Write a per-repo memo (common agent operation):

```bash
cat <<'EOF' | orbit memo backend
# backend

Go REST API, sqlc-generated DB layer.

## Key Entry Points
- `cmd/server/main.go` — Server startup
- `internal/service/` — Business logic

## Tech Stack
Go 1.22, sqlc, PostgreSQL
EOF
```

Auto-generate a scaffold memo template (for quick initialization):

```bash
orbit memo backend --scaffold
```

`--scaffold` outputs a static scaffold template to stdout (doesn't write to file or update index), listing the recommended section structure with TODO placeholders. Agents use this as a starting point to write the real memo after exploring the repo.

Refresh the index (infrequent maintenance):

```bash
orbit memo                    # Refresh all repo indexes
orbit memo backend --refresh  # Refresh single repo index
```

## 9. Recording Discoveries (Jot)

During work, record repo knowledge for later memo aggregation:

```bash
cd task-01/backend/
orbit jot "entry point is cmd/main.go"          # Record a discovery (repo inferred from CWD)
orbit jot backend "uses Echo router"             # Explicit repo name
orbit jot backend --pop                          # Pop all entries (outputs + clears)
```

Jot is a lightweight queue — push discoveries as you find them, pop and merge into memo at natural breakpoints. When entries exceed 10, a warning suggests aggregation.

When `orbit add` pulls in a repo whose memo is thin or missing, it auto-seeds one `[seed] ...` jot entry (once per repo) as a durable, compaction-proof reminder to explore and write a memo before `done`. A `[seed]` entry is a system instruction, not a discovery — act on it, but drop it at aggregation (never merge it into the memo). It surfaces on `--pop` like any other entry, and keeps the repo flagged by `orbit context gaps` until you add a real jot or write a memo.

## 10. Completion and Cleanup

Mark workspace as done:

```bash
orbit done                                                  # Mark done (no PR also OK)
orbit done --pr https://github.com/org/backend/pull/42      # Mark done and record PR
orbit done --pr https://github.com/org/frontend/pull/43     # Can append multiple PRs
```

Running `orbit done --pr <url>` again on an already-done workspace appends the PR (`done-at` updates to current time).

`orbit done` prints non-blocking stderr warnings before completing: one if any repo still has jot entries to aggregate, and one listing repos that still lack a real memo (the `orbit context gaps` set). It still marks the workspace done — the warnings just flag knowledge that would be lost on the next `prune`.

Reclaim completed workspaces:

```bash
orbit prune                       # Clean all status=done
orbit prune --older 30d           # Only clean those done more than 30 days ago
orbit prune task-01               # Clean a specific workspace
orbit prune --dry-run             # Preview
orbit prune --verify              # Check if PR has been merged
orbit prune --force               # Skip branch protection checks
```

> **Note**: `prune` will delete candidate workspace directories. Branches are only cleaned when protection conditions are met (branches are preserved without `--force` if unmerged). It's recommended to use `--dry-run` first to preview what will be cleaned.

## 11. Environment Variables

```bash
ORBIT_ROOT=<project-root>         # Explicitly specify project root
ORBIT_BRANCH_PREFIX=<prefix>      # Override tracking branch prefix, default ws
```

## 12. JSON Output

Some commands support `--json` for script/agent parsing:

```bash
orbit status --json           # Workspace status
orbit repos --json            # Repos list (includes memoBehind field)
orbit info backend --json     # Repo details
orbit done --json             # Mark done and output JSON
orbit context --json          # Workspace context (complete)
orbit context path            # Single key query (workspace/path/goal/status/gaps)
orbit context gaps --json     # Repos with no real memo, as a JSON array
orbit jot backend --pop --json  # Pop jot entries as JSON
```

`orbit repos --json` includes a `"memoBehind": N` field per record, indicating how many commits behind the current HEAD the memo was written at (0 = up to date).

## 13. Workspace Context

Get the complete context of the current workspace in one call (goal, status, all repo branches and memos):

```bash
orbit context                 # Full context
orbit context --json          # Structured JSON
orbit context path            # Single key: workspace directory absolute path
orbit context workspace       # Single key: workspace name
orbit context goal            # Single key: workspace goal
orbit context status          # Single key: active / done
orbit context gaps            # Single key: repos with no real memo (thin + no non-[seed] jot); supports --json
```

Full mode outputs workspace summary and each repo's full memo text; `--json` outputs structured data; single-key queries output single-line values for scripts and agents to quickly determine their position.

Must be executed within a workspace (workspace inferred from CWD).

## 14. Environment Diagnostics

Check whether the current environment meets orbit's runtime requirements:

```bash
orbit doctor
```

Checks:
- git version (≥ 2.20; bootstrapping the first commit of an empty repo needs ≥ 2.42, since `orbit add` uses `git worktree add --orphan`)
- bash version (≥ 3.2)
- Optional tools (jq, gh)
- Project structure (`.repos/` existence, repo count, workspace count)

`orbit doctor` can be executed from anywhere; being inside an orbit project is not required. It also prints the orbit runtime version, which you can query on its own with `orbit version` (aliases: `--version`, `-v`).

## 15. Shell Completion

`orbit` has built-in completion script generation:

```bash
orbit completion zsh    # Output zsh completion script
orbit completion bash   # Output bash completion script
```

`install.sh --zsh` / `--bash` automatically calls the above commands, writing completion to the shell's search path. Open a new shell to use `orbit <Tab>`.

For manual installation (without depending on install.sh):

```bash
# zsh (place in a directory within fpath)
orbit completion zsh > /path/to/fpath/_orbit
# bash (place in bash-completion search path)
orbit completion bash > /path/to/bash-completion/completions/orbit
```

## 16. Auto-approving safe commands

An orbit session runs read-only and idempotent subcommands (`context` / `repos` / `info` / `status`, plus workspace-writes like `add` / `memo` / `jot`) constantly, so per-command confirmation prompts add up. Those safe tiers can run without a prompt; destructive or externally-visible commands (`done` `prune` `clone` `config` `new`) always keep prompting.

**Plugin users — nothing to do:** both plugins ship a `PreToolUse` hook that auto-approves exactly the safe subcommands and fails safe. **Skill-only / other agents:** add a static allowlist to your agent settings.

The exact command tiers, the ready-to-paste allowlist snippet, and the rationale for each tier all live in [`skills/CONSTRAINTS.md`](skills/CONSTRAINTS.md#permission-and-auto-execution-policy).

## 17. Command Reference

```text
# Repo management
orbit clone <url> [--push <fork-url>] [--name <identity>] [--branch <branch>]
orbit repos
orbit info <repo>
orbit memo [<repo>] [--refresh|--scaffold]
orbit sync [repo...] [--force] [--branch <branch>]

# Workspace lifecycle
orbit new "<goal>" [--name <name>] [--no-goal] [--exec "<cmd>"]
orbit add <repo> [--ref <tag/branch>] [-s|--silent]
orbit switch [repo] <name>
orbit switch -c [repo] <name>
orbit jot [<repo>] ["<text>"]
orbit jot [<repo>] --pop [--json]
orbit done [--pr <url>...] [--json]
orbit prune [workspace] [--older <dur>] [--verify] [--dry-run] [--force]

# Status and context
orbit status [workspace]
orbit goal ["text" / --clear]
orbit context [<key>] [--prime] [--json]  # key: workspace, path, goal, status, gaps; --prime = startup preflight

# Configuration
orbit config [<key> [<value> | --unset]]

# Diagnostics
orbit doctor
orbit version

# Completion
orbit completion <zsh|bash>
```
