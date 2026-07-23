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

If you use bash, change to `--bash`. To overwrite an existing installation, add `--force`. To switch where a plugin's marketplace points (for example from a local checkout to the public git repo), add `--replace-marketplace` — e.g. `ORBIT_SOURCE=orbcli/orbit ./install.sh --codex --replace-marketplace`. Plain `--force` only refreshes content from the already-configured source; it does not change where the source points.

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
NAME      ADDED  MEMO  BRIEF
backend   *      ok    Go REST API, sqlc-generated DB layer
frontend         ok    React SPA, consumes backend API
my-svc           none  -
```

`ADDED` marks repos already in the current workspace; `MEMO` is the card state
(`ok` / `stale N` / `none`). Add `--urls` for the remote URL column.

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

`sync` fast-forwards the **pool** repo (`.repos/<repo>`) only — it never moves a worktree you've already checked out. When run from inside a workspace whose worktree tracks the branch just advanced, sync emits a stderr note that the worktree is now behind; bring it up to date with native git if you want. Don't re-run `orbit sync` expecting the worktree to move.

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

Copy and run the recommended command to launch the agent. The agent triggers orbit skill startup detection through the initial prompt, reads context, and starts working. With the Claude Code or Qoder plugin installed, the `orbit start` phrase is optional — the session hook detects the workspace either way; keep it for skill-only setups, where it is the trigger.

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

**Tracking-display limitation:** the pool is a single-branch clone, so a raw-mode branch you push this way won't show remote tracking in `git status` / `@{upstream}` — the branch and push are fine, only the ahead/behind display is blank. Run `git fetch origin <branch>` once to materialize the ref, or use scoped mode below, which wires tracking up front.

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

## When to add (roles)
- Owns the HTTP API and business logic — add for any endpoint or service change.

## How to use
- `cmd/server/main.go` — server startup + route mounting; start here to trace a request.
- `internal/service/` — business logic; the entry point for behavior changes.
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

### Memo config keys (project-level, on `.repos/.orbit`)

Three optional keys tune the memo card; set them with `orbit config <key> <value>` (unset → default):

```bash
orbit config memo.minLines 4        # soft floor: below this a memo counts as thin/missing (default 4)
orbit config memo.maxLines 16       # hard ceiling: curate instead of appending past it; also caps the
                                    #   README fallback in `orbit info` (default 16)
orbit config explore.paths ".:1"    # cold-start exploration scope for the first `orbit add` of a repo:
                                    #   a comma-delimited list of <path>:<depth> entries (default ".:1")
```

`memo.minLines`/`memo.maxLines` are surfaced as `card budget: <min>–<max> lines` at the curation checkpoints (jot overflow and `orbit done`). `explore.paths` is a one-time cold-start knob only — once the first exploration writes the card, the jot → incremental-memo pipeline maintains it. Orbit attaches no meaning to what lives at those paths (a pre-generated code-doc works just as well).

## 9. Recording Discoveries (Jot)

During work, record repo knowledge for later memo aggregation:

```bash
cd task-01/backend/
orbit jot "entry point is cmd/main.go"          # Record a discovery (repo inferred from CWD)
orbit jot backend "role: owns the public /auth API"   # Explicit repo name
orbit jot backend --pop                          # Pop all entries (outputs + clears)
```

Jot is a lightweight queue — push discoveries as you find them, pop and merge into memo at natural breakpoints. Per repo, when entries pass half of `jot.bufferSize` (default 4) a `building` note counts them; past the buffer an `overflow` warning suggests aggregation.

When `orbit add` pulls in a repo whose memo is thin or missing, it prints a one-shot stderr naming the `explore.paths` scope — explore and write a memo before `done`. The same state resurfaces automatically via per-repo status (bare `orbit context`, the session-start block) and at `orbit done`.

## 10. Completion and Cleanup

Mark workspace as done:

```bash
orbit done                                                  # Mark done (no PR also OK)
orbit done --pr https://github.com/org/backend/pull/42      # Mark done and record PR
orbit done --pr https://github.com/org/frontend/pull/43     # Can append multiple PRs
```

Running `orbit done --pr <url>` again on an already-done workspace appends the PR (`done-at` updates to current time).

`orbit done` prints non-blocking per-repo stderr warnings before completing: leftover jots (`pop + merge`), a thin memo with no capture (`explore + write`), or an over-budget card (`curate once`). It still marks the workspace done — the warnings just flag knowledge that would be lost on the next `prune`.

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

## 12. Codex Sandbox Escalation

Codex runs with a filesystem sandbox that restricts writes to the workspace
root and a few system directories. Orbit manages its pool repos under
`.repos/` outside the workspace root, so commands that write into the pool
(`orbit add`, `orbit memo`, `orbit sync`, `orbit done`, `git` operations in
worktrees, etc.) are blocked by the sandbox and require escalation.

### Recommended: obey sandbox, escalate only when needed

The sandbox is a security boundary. Keep `.repos/` outside the writable roots
so the agent never sees it as an accessible path. When an orbit command or git
operation fails with a sandbox permission error, retry with
`sandbox_permissions: "require_escalated"` and include a `prefix_rule` so the
user can persist the approval:

| Prefix rule | Covers |
|---|---|
| `["orbit"]` | All orbit subcommands |
| `["git", "checkout"]` | Branch creation in worktrees |
| `["git", "switch"]` | Branch switch/create in worktrees (incl. `orbit switch` fallback) |
| `["git", "commit"]` | Commits in worktrees |
| `["git", "add"]` | Staging changes in worktrees |
| `["git", "push"]` | Pushing worktree branches |

Suggest persisting these rules on first use. Subsequent sessions reuse the
stored approvals without additional prompts. Note the scope: a `git` prefix
rule like `["git", "commit"]` approves that subcommand in **any** path, not
only orbit worktrees. That is intended here — worktree writes land in the pool
outside the workspace — but the user should approve it knowing the breadth.

### Workaround: auto-loading guidance via AGENTS.md

This is a convenience workaround, not the primary path. The recommended flow
above (escalate on demand, persist the prefix rules once) already makes
subsequent sessions frictionless. Reach for this only if you dislike being
reminded of the escalation steps each session.

Copy the block below into an `AGENTS.md` at the **orbit project root** (the
directory that holds `.repos/`). Codex auto-loads it on startup, so the agent
knows the escalation steps from its first message — no per-session reminder.

```markdown
# Orbit workspace

## Sandbox escalation for orbit commands

Orbit commands (add, memo, sync, done, etc.) and git operations inside orbit
worktrees write git metadata under `.repos/` — the pool repo infrastructure
outside the workspace sandbox. These writes are blocked by the sandbox.

**Do NOT add `.repos/` to `writable_roots`.** The agent must not see `.repos/`
as a writable path in its system prompt — that would expose the directory and
risk the agent working directly in the pool instead of through orbit worktrees.

When an orbit command or git operation in an orbit worktree fails with a sandbox
permission error, retry with `sandbox_permissions: "require_escalated"` and
include a `prefix_rule` so the user can persist the approval:

- `["orbit"]` — all orbit subcommands
- `["git", "checkout"]` — branch creation in worktrees
- `["git", "switch"]` — branch switch/create in worktrees (incl. `orbit switch` fallback)
- `["git", "commit"]` — commits in worktrees
- `["git", "add"]` — staging changes in worktrees
- `["git", "push"]` — pushing worktree branches

Suggest persisting these rules on first use so subsequent sessions are frictionless.
```

### Not recommended: `--add-dir` / `writable_roots`

You *can* skip per-command escalation by adding `.repos/` to the sandbox
writable roots, but this is not recommended:

- **One-off**: `codex --add-dir /path/to/pool/.repos start`
- **Persistent**: add to `~/.codex/config.toml`:

  ```toml
  [projects."/path/to/workspace"]
  trust_level = "trusted"
  writable_roots = ["/path/to/pool/.repos"]
  ```

**Why not**: `writable_roots` are injected into the agent's system prompt. The
agent then knows `.repos/` exists and is writable, which risks it working
directly in the pool instead of through orbit worktrees — undermining orbit's
isolation guarantees. Use only if you understand and accept this tradeoff.

## 13. JSON Output

Some commands support `--json` for script/agent parsing:

```bash
orbit status --json           # Workspace status
orbit repos --json            # Repos list (includes memoBehind field)
orbit info backend --json     # Repo details
orbit done --json             # Mark done and output JSON
orbit context --json          # Cruise block (per-repo status, no memos)
orbit context path            # Single key query (workspace/path/goal/state)
orbit jot backend --pop --json  # Pop jot entries as JSON
```

`orbit repos --json` includes a `"memoBehind": N` field per record, indicating how many commits behind the current HEAD the memo was written at (0 = up to date).

## 14. Workspace Context

`orbit context` is the model-facing context command — its stdout is a readable markdown block:

```bash
orbit context --startup       # Session-start block: cold start → pool roster; populated → memos + per-repo status
orbit context                 # Cruise block: durables + conditional per-repo status (no memos)
orbit context path            # Single key: workspace directory absolute path
orbit context workspace       # Single key: workspace name
orbit context goal            # Single key: workspace goal
orbit context state           # Single key: active / done
```

`--startup` is what the session hooks inject (agent plugins wrap it in `<orbit-context>` tags); it doubles as workspace detection — it fails fast outside a workspace. The bare form is the **cruise block** — the in-session recovery view for compaction/resume: cheap durables plus one status line per repo that has pending jots, is behind upstream, or has a thin/over-budget memo. Full memos are pulled on demand via `orbit info <repo>`.

**Workspace scope best practice**: keep workspaces task-scoped (small — on the order of 1~6 worktrees). The startup block injects every worktree's memo, which stays cheap only at that scale. A workspace holding dozens of repos is a scope signal, not something to cap with truncation: split it (create a new task-scoped workspace and `orbit prune` the old one).

Must be executed within a workspace (workspace inferred from CWD).

## 15. Environment Diagnostics

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

## 16. Shell Completion

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

## 17. Auto-approving safe commands

An orbit session runs read-only and idempotent subcommands (`context` / `repos` / `info` / `status`, plus workspace-writes like `add` / `memo` / `jot`) constantly, so per-command confirmation prompts add up. Those safe tiers can run without a prompt; destructive or externally-visible commands (`done` `prune` `clone` `config` `new`) always keep prompting.

**Plugin users — nothing to do:** both plugins ship a `PreToolUse` hook that auto-approves exactly the safe subcommands and fails safe. **Skill-only / other agents:** add a static allowlist to your agent settings.

The exact command tiers, the ready-to-paste allowlist snippet, and the rationale for each tier all live in [`skills/CONSTRAINTS.md`](skills/CONSTRAINTS.md#permission-and-auto-execution-policy).

## 18. Command Reference

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
orbit context [<key>] [--startup|--prime|--reignite] [--json]  # key: workspace, path, goal, state; bare = cruise block; --startup = session-start block

# Configuration
orbit config [<key> [<value> | --unset]]

# Diagnostics
orbit doctor
orbit version

# Completion
orbit completion <zsh|bash>
```
