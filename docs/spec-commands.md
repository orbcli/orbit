# Command System

> Detailed behavior definitions for the command system, architecture boundaries, execution location matrix, and inference rules.

## Constraint Premises

- The agent's context boundary = workspace directory boundary; never launch agents at the project root
- Maintain the "directory-as-configuration" philosophy; no manifest files
- Orbit is a Layer 2 tool, not bound to any specific agent
- Workspaces don't nest: new workspaces are always created under the project root, even when `new` is run from within a workspace
- Default is raw mode (agent manages branches itself); scoped mode (prefix isolation) is opt-in
- Project root resolution: traverse upward from CWD looking for `.repos/`, up to `/` (same as git looking for `.git/`)

## Architecture Boundaries and Command Existence Criteria

**orbit is the sole API between workspace and .repos/.** Agents within a workspace never directly touch the `.repos/` directory.

```
┌─────────────────────────────────────┐
│  Workspace (visible to agents)       │
│  - Native git operations used directly│
│  - .orbit files written by orbit done │
├─────────── orbit API ───────────────┤
│  .repos/ (invisible to agents)       │
│  - Accessed only via orbit commands  │
└─────────────────────────────────────┘
```

A command exists in orbit if and only if:
- The operation crosses the workspace → .repos boundary → orbit provides it
- Native git can handle it within the workspace → no orbit wrapper
- Skills must not expose .repos paths or guide agents to directly read/write .repos contents
- Every orbit command must pass the "can native git replace this?" test

## Command List

```bash
# Source pool management (requires .repos/ access)
orbit clone <url> [--push <fork-url>] [--name <identity>] [--branch <branch>]  # Add to pool + write index base fields (implicit init)
orbit repos [--json]                         # List all repos in pool: name + url + brief
orbit info <repo> [--json]                  # Output per-repo markdown (Level 1)
orbit memo                               # Refresh global index for all repos (url + brief + head)
orbit memo <repo>                        # Write per-repo markdown from stdin (first line is brief, also refreshes index)
orbit memo <repo> --refresh              # Refresh only a single repo's index entry (no .md write)
orbit memo <repo> --scaffold             # Generate skeleton template to stdout (no file write, no index update)
orbit sync [repo...]                     # fetch + fast-forward pool repo's tracking branch
orbit sync [repo...] --force             # fetch + reset --hard (force sync when locally diverged)
orbit sync [repo...] --branch <branch>   # Switch pool repo's tracking branch

# Workspace lifecycle
orbit new ["<goal>"] [--name <name>] [--exec "<cmd>"] [--no-goal]  # Create workspace (implicit init; goal source: positional arg, else editor when interactive/ORBIT_EDITOR set, else stdin — empty aborts; --no-goal for an intentionally goal-less workspace. --exec runs the given command after creation; without it, agent.recommend config (if set) is printed as a launch hint, not executed)
orbit add <repo> [--ref <tag/branch>] [-s|--silent]  # Create worktree from pool into workspace (-s suppresses the memo echo)
orbit switch [repo] <name>                      # Switch to existing remote branch (creates prefixed local tracking)
orbit switch -c [repo] <name>                   # Create new tracking branch from HEAD (purely local, no push)
orbit jot [<repo>] ["<text>"]                   # Push a discovery to the jot queue
orbit jot [<repo>] --pop [--json]               # Pop all entries (consume + delete)
orbit done [--pr <url>...] [--json]          # Mark workspace as done
orbit prune [workspace] [--older <dur>] [--verify] [--dry-run] [--force]  # Reclaim workspace

# Status queries
orbit status [--json]                        # Current workspace status
orbit status <workspace> [--json]            # Specify which workspace to view when at root
orbit goal                               # Modify goal (interactively opens editor, pre-fills current value; also supports stdin pipe)
orbit goal "new goal"                    # Set goal directly
orbit goal --clear                       # Delete goal (free exploration mode)
orbit context [<key>] [--startup|--prime|--reignite] [--json] # Context blocks or single key query (workspace/path/goal/state); bare = cruise block (durables + conditional per-repo status); --startup = session-start block (cold start → pool roster; populated → memos + per-repo status)

# Project configuration
orbit config                             # List all project configuration
orbit config <key>                       # Read configuration value
orbit config <key> <value>               # Set configuration value
orbit config <key> --unset               # Delete configuration entry

# Diagnostics and completion
orbit doctor                             # Environment health check
orbit version                            # Print the orbit runtime version
orbit completion <zsh|bash>              # Output shell completion script

# Not implemented (native git can handle these)
# git remote add/remove/set-url
# git push
# git checkout -b (in default mode, agent creates plain branches on its own)
```

## Command Atomicity and Agent Orchestration

orbit commands are designed as atomic operations — each command does one thing without chaining side effects. Complex workflows are orchestrated by agent skills (`skills/CONSTRAINTS.md`):

```
goal → repos → info → add → work → jot → memo → done
```

This explains several design choices:
- `orbit clone` only writes index base fields (url + head) and does not auto-generate memos — the agent writes them via `orbit memo` after understanding the code, rather than mechanical summarization
- `orbit add` sets upstream tracking (`origin/<default-branch>`) for status/ahead-behind visibility — pushing itself is native git, and orbit takes no stance on push workflow
- `orbit done` does not trigger cleanup — reclamation is controlled by humans via `orbit prune`

Keeping commands simple relies on the skill layer taking orchestration responsibility. If orchestration logic were embedded in commands (e.g., clone auto-generating memos, add auto-creating branches), commands would bloat and be hard to adapt to different agents' behavior patterns.

## Implicit Initialization

There is no standalone `orbit init` command. Commands that require `.repos/` (`clone`, `new`) automatically initialize when they detect it doesn't exist.

## Command Execution Location Matrix

| Command | project root | within workspace | workspace subdirectory (worktree) |
|---------|-------------|-----------------|-----------------------------------|
| `orbit new` | ✓ | ✓ (creates new workspace under root) | ✓ (same as left) |
| `orbit clone` | ✓ | ✓ | ✓ |
| `orbit repos` | ✓ | ✓ | ✓ |
| `orbit info` | ✓ | ✓ | ✓ |
| `orbit memo` | ✓ | ✓ | ✓ |
| `orbit add` | ✗ error | ✓ | ✓ |
| `orbit jot` | ✗ error | ✓ (repo must be specified) | ✓ (repo inferred from CWD) |
| `orbit switch` | ✗ error | ✓ (repo must be specified) | ✓ (repo inferred from CWD) |
| `orbit done` | ✗ error | ✓ | ✓ (convenient for manual use) |
| `orbit prune` | ✓ | ✓ (but checks self; errors if it would be pruned) | same as workspace |
| `orbit status` | ✓ (requires `status <ws>` to specify) | ✓ (current workspace) | ✓ (current workspace) |
| `orbit goal` | ✗ (not within workspace, error) | ✓ | ✓ |
| `orbit context` | ✗ error | ✓ | ✓ |
| `orbit sync` | ✓ (syncs all repos) | ✓ (syncs repos in workspace) | ✓ (syncs current repo) |
| `orbit doctor` | ✓ | ✓ | ✓ |
| `orbit version` | ✓ | ✓ | ✓ |
| `orbit completion` | ✓ | ✓ | ✓ |

## Workspace and Repo Inference

Commands requiring workspace context (`orbit add`, `orbit done`, `orbit goal`, `orbit jot`, `orbit switch`, `orbit context`) infer the current workspace from the first-level directory of CWD relative to the project root. They error at the project root (cannot infer). `orbit jot` and `orbit switch` additionally infer the repo (see below).

`orbit add <repo>` implicitly determines the workspace from execution location (agents always work within a workspace; no need to specify repeatedly).

`orbit switch` additionally requires repo context (a workspace may contain multiple repos):
- Executed within a worktree subdirectory → repo inferred from CWD (which worktree the current directory belongs to)
- Executed at workspace root → `repo` parameter must be explicitly provided; otherwise error: "multiple repos in workspace, specify which one"

## orbit clone Option Semantics

- `--name <identity>`: Override the default repo identity (default takes URL basename); for scenarios where URL basename is unsuitable as a directory name
- `--branch <branch>`: Specify the default branch at clone time (passed to `git clone --branch`); for scenarios where only a specific branch is needed
- `--push <fork-url>`: Set a separate push remote (`git remote set-url --push origin <fork-url>`); for fork scenarios — the fork does not create a new identity in the pool, but reuses the same repo with a different push URL to differentiate the push target

## orbit add --ref Semantics

`--ref <tag/branch>` starts the worktree from the specified ref, rather than the default remote branch:

1. `git fetch origin <ref>` — fetch the specified ref to FETCH_HEAD
2. Create worktree, branch naming remains `ws/<workspace>/<default-branch>` (same as default mode)
3. Upstream set to `origin/<default-branch>` (same as default mode)
4. If local branch already exists: reuse the branch, `reset --hard FETCH_HEAD` to align to target ref
5. If fetch fails: error `"cannot fetch ref: <ref>"`

Typical use case: agent needs to verify API compatibility against a specific version of a dependency library.

## orbit add Memo Echo and `-s|--silent`

By default `orbit add` echoes the repo's memo to **stderr** after creating the worktree (stdout keeps only the parseable `added <repo> → ...` line). This is a safety net: an agent that jumped straight to `add` without any context still gets repo context, and seeing the memo dump signals it added blind. A well-behaved agent that already holds enough context — from `orbit info`, the memo surfaced in the startup block, or a prior session — passes `-s` (curl-style) to suppress the echo. The thin/missing-memo nudge below is part of the same stderr block, so `-s` suppresses it too — only pass `-s` when you already know the repo's memo state.

**No/low-memo nudge**: when the added repo's memo is thin (missing, or fewer than `memo.minLines` non-blank lines, default 4), `orbit add` additionally prints a one-shot stderr naming the `explore.paths` scope — explore the repo and write a real card before `done`. The same state resurfaces automatically via per-repo status (bare `orbit context` and the `--startup`/reignite block) and via the `orbit done` gate, so the reminder survives context loss without any durable placeholder.

**Delegation**: `orbit add` is *guarded creation* — it fails cleanly on collision (worktree exists / branch checked out elsewhere), not a read-modify-write. It is therefore safe to delegate to a worker sub-agent that follows a cross-repo thread on its own (see PRINCIPLES.md Principle 7).

## orbit jot

Lightweight discovery queue for recording knowledge during work, aggregated into memo at natural breakpoints.

```bash
orbit jot [<repo>] ["<text>"]    # push
orbit jot [<repo>] --pop [--json]  # pop all entries (consume + delete)
```

**Storage**: workspace `.orbit` file, `[jot]` section (git-config multi-value):

```ini
[jot]
	backend = entry point is cmd/main.go
	backend = uses Echo router
```

Jot entries are real discoveries only — orbit writes no system placeholders into the queue. Every entry counts as real capture.

**Push mode** (default):
- `orbit jot <repo> "text"` — append one entry
- Repo can be omitted when CWD is inside a worktree (inferred, same as `orbit switch`)
- Text can be omitted → opens editor (same rules as `orbit goal`)
- Stdin non-TTY + no text argument → reads from stdin
- After push: count entries for this repo against `jot.bufferSize` (default `memo.minLines` = 4). At or below half → silent; above half up to the buffer → stderr `orbit: <repo> has N jots (building)` (informational); past the buffer → stderr `orbit: <repo> has N jots (overflow): jot <repo> --pop, then merge into memo`

**Pop mode** (`--pop`):
- Outputs all entries for the repo (one per line), then deletes them from `.orbit`
- `--json`: outputs `{"repo":"<name>","entries":[...],"count":N}` instead of plain text
- No entries → empty output (or `{"repo":"<name>","entries":[],"count":0}` with `--json`), no error
- Entries are consumed: pop is the only way to clear them

**Repo inference**: same rules as `orbit switch` — within a worktree, repo is inferred from CWD; at workspace root, repo parameter is required.

**Delegation**: `jot` push is append-only and concurrency-safe, so a worker sub-agent captures discoveries directly; the owner agent consumes them with `--pop` and aggregates into memo serially at wrap-up (see PRINCIPLES.md Principle 7 and spec-knowledge.md "Capture vs. aggregate under delegation").

## orbit context

`orbit context` is the model-facing context aggregation command: its stdout is a readable markdown block for agents and humans, not machine data (the machine channel is `--json`). It has three purpose-scoped entries:

- **`--startup` (session-start block)**: used by the `SessionStart` hook and by the skill's startup detection; one call doubles as workspace detection (fails fast outside a workspace). Routes internally on worktree presence: empty → **prime**, populated → **reignite**. `--prime` / `--reignite` select the block explicitly (human/debug use; the skill exposes only `--startup` and the bare form).
  - **prime** (cold start, empty workspace): outputs `path` / `goal` (if set) / `state` (with a DONE banner when the workspace is `done`), then the **pool roster** — the "add menu": `available in pool (orbit add <repo> ...):` followed by `  <name>  <one-line brief>` per pool repo. Briefs resolve via the shared fallback (index → memo → README; [spec-metadata](spec-metadata.md) "Fallback Rules"), so a freshly cloned repo shows its README brief rather than `-`. The steering that `orbit repos` sends to stderr is inlined as trailing stdout sections — pool repos without a memo are listed under `no memo (write the card via orbit memo <repo>; …):`, and repos whose memo exists but whose index entry drifted under `index out of sync (repair via orbit memo <repo> --refresh):` — because hook injection carries only stdout. Level-0 briefs only (no memo dumps) — full memo on demand via `orbit info <repo>` (progressive loading). Empty pool prints `pool is empty — clone a repo into the pool first: orbit clone <url>`.
  - **reignite** (worktrees present): outputs the same durables, then per worktree repo: `--- <name> (branch: <branch>) ---` + two-layer staleness (memoBehind + remoteAhead — fetches like `orbit info`, advisory only; sync stays on-demand) + conditional `status:` line (jot count and level / commits behind upstream / `memo thin` / `memo over budget` — only repos with something pending) + small jot queues inlined (up to `jot.bufferSize` entries; larger queues collapse to a count + pop hint) + the full memo card. No roster, no source.
- **Bare `orbit context` (cruise block)**: the in-session counterpart of the startup block, for compact/resume recovery — cheap durables (`path` / `goal` if set / `state`, with DONE banner) plus **conditional per-repo status** (only repos with pending jots, commits behind upstream, an untracked raw-mode branch, or a non-ok memo state), one line each: `repo <name>: 3 jots (building) | 2 behind upstream | memo thin`. Never fetches (uses local refs; behind is measured against the worktree branch's `@{upstream}` — a raw-mode branch without upstream shows `no upstream (fetch origin <branch> to track)` instead of a count, so the agent knows to materialize the ref). Does **not** dump memos — pull a repo's memo on demand with `orbit info <repo>`.
- **Single key query**: `orbit context <key>` outputs a single value and exits. Supported keys: `workspace` (name), `path` (absolute path), `goal`, `state` (active/done).
- Must be executed within a workspace (inferred from CWD); errors at project root or outside a project — hooks treat failure as a silent no-op.
- A key cannot be combined with `--startup`/`--prime`/`--reignite`; the three mode flags are mutually exclusive.
- `--json`: structured output for debug/scripting (format in the "JSON Output Format" section below). The bare form's JSON mirrors the cruise block (no memos); `--startup --json` follows the same worktree routing — empty workspace emits the prime JSON shape, populated workspace emits the reignite JSON shape.

## orbit info Auto-fetch

`orbit info <repo>` automatically fetches that repo's tracking branch on execution (`git fetch origin <default-branch>`), enabling two-layer staleness detection:

- **Layer 1 (pool ← upstream)**: After fetch, compares pool repo's local branch with `origin/<branch>`; if behind, outputs to stderr: `orbit: <repo>: N new commits on origin/<branch>`
- **Layer 2 (memo ← pool HEAD)**: Existing `orbit_staleness_check`, compares HEAD at memo write time with pool repo's current HEAD

Both layer warnings output to stderr, not affecting stdout. Fetch failures are silently skipped (network unavailability does not block viewing).

`orbit repos` does not fetch (stays purely local and fast), only shows Layer 2.

## orbit sync

Synchronizes pool repo's tracking branch to the latest upstream state.

```bash
orbit sync [repo...] [--force] [--branch <branch>]
```

**CWD Inference** (when no repo argument):
- project root → sync all pool repos
- within workspace → sync repos that have been added to this workspace
- within worktree → sync current repo
- Explicit `repo...` arguments override CWD inference

**Three strategies:**

| Mode | Behavior | Scenario |
|------|----------|----------|
| Default | `fetch` + `merge --ff-only` | Regular sync |
| `--force` | `fetch` + `reset --hard` | Locally diverged or ff failed |
| `--branch <new>` | Switch fetch refspec + fetch + checkout | Change tracking branch |

**`--branch` detailed flow:**
1. `git config --unset-all remote.origin.fetch`
2. `git config --add remote.origin.fetch "+refs/heads/<new>:refs/remotes/origin/<new>"`
3. `git fetch origin <new>`
4. `git checkout <new>` (if doesn't exist locally: `git checkout -b <new> origin/<new>`)
5. `git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/<new>`
6. If memo already exists: stderr outputs "memo may not apply to new branch"

`--branch` + `--force` can be combined.

**Post-sync behavior:**
- Does not update the `.orbit` index `head` field (`head` reflects HEAD at memo write time, not at sync time)
- `orbit_staleness_check` compares memo HEAD vs pool current HEAD; distance naturally changes after sync
- sync does not cascade to memo refresh — memo validity is determined by actual work needs, not by commit distance (see [`docs/spec-knowledge.md`](./spec-knowledge.md) Sync and Memo Cascade Relationship; agent behavior rules in `skills/CONSTRAINTS.md` Sync Decision Rules)
- Existing worktrees are unaffected (each on its own independent branch) — sync only fast-forwards the pool repo, never a checked-out worktree. When sync runs from inside a workspace and a worktree tracks the branch just advanced, it emits a stderr hint that the worktree is now behind. Updating the worktree is left to native git — orbit takes no stance on how.

**Error handling:**
- ff-only fails → stderr warning + suggests `--force`, continues processing next repo
- fetch fails → stderr warning, continues processing next repo
- `--branch` target branch doesn't exist → error

## orbit doctor

Environment health check; does not require being inside an orbit project.

- Checks:
  - git version >= 2.20 (critical)
  - bash version >= 3.2 (critical)
  - jq availability (optional, improves JSON handling)
  - gh availability (optional, enables PR-aware prune)
- If inside an orbit project: additionally reports `.repos/` structural integrity, repo count, workspace count
- Exit code: 0 = all critical checks pass, 1 = critical failure exists
- Output format: `[OK]` / `[FAIL]` / `[WARN]` prefixed lines, human-readable
- Also prints the orbit runtime version in the header

## orbit version

Prints the orbit runtime version (e.g. `0.1.0`) to stdout and exits 0. Does not require being inside an orbit project. `--version` and `-v` are aliases. This is the runtime version, distinct from the plugin manifest version — the runtime is installable on its own (`install.sh` / curl bootstrap), so it carries its own version.

## Edge Case Handling

- `orbit clone` with existing repo of same name → error
- `orbit add foo` when `foo` is not in `.repos/` → error, suggests `orbit clone` first
- `orbit add` same repo already in workspace → error (`worktree already exists`)
- `orbit new --name xxx` when directory already exists → error
- Project root resolution upper limit → `/` (same as git looking for `.git/`)

## JSON Output Format

All commands supporting `--json` output a single JSON object (or array), encoded as UTF-8, terminated with a single newline, with no additional formatting (no indentation, no pretty-print). Field names use camelCase (following git config naming conventions).

### `orbit repos --json`

```json
[
  {
    "name": "backend",
    "url": "git@github.com:org/backend.git",
    "brief": "Go REST API, sqlc-generated DB layer",
    "head": "abc1234",
    "incomplete": false,
    "memoBehind": 0
  }
]
```

Field descriptions:
- `name`: string, repo identity in the pool (i.e., directory name under `.repos/`)
- `url`: string, remote URL (read from index preferentially, fallback to `git remote get-url origin`)
- `brief`: string, one-line description (source priority: index → memo first line → README first line → `"-"`)
- `head`: string, HEAD commit hash recorded in the index (if index has no record, uses current `git rev-parse HEAD`)
- `incomplete`: boolean, `true` indicates metadata is incomplete (`.md` file missing, or any of url/brief/head is empty in the index)
- `memoBehind`: number, commits the memo is behind pool repo's current HEAD (0 = up to date)

Empty pool outputs empty array `[]`.

### `orbit status --json`

```json
{
  "workspace": "feat-auth",
  "goal": "Implement OAuth2 login flow",
  "status": "active",
  "worktrees": [
    {
      "name": "backend",
      "branch": "feat/oauth2",
      "ahead": 3,
      "behind": 0,
      "dirty": true
    }
  ]
}
```

Field descriptions:
- `workspace`: string, workspace name
- `goal`: string, workspace goal (empty string when not set)
- `status`: string, workspace status (`"active"` | `"done"`)
- `worktrees`: array, status of all worktrees in the workspace
  - `name`: string, repo name
  - `branch`: string, current branch (`"detached"` when in detached HEAD state)
  - `ahead`: number, commits ahead of upstream (0 when no upstream)
  - `behind`: number, commits behind upstream (0 when no upstream)
  - `dirty`: boolean, whether the working tree has uncommitted changes

### `orbit info --json`

```json
{
  "repo": "backend",
  "content": "Go REST API, sqlc-generated DB layer\n\n## When to add (roles)\n- Owns the HTTP API — add for endpoint work\n\n## How to use\n- api/ — OpenAPI contract, edit first\n...",
  "remoteAhead": 3,
  "memoBehind": 5
}
```

Field descriptions:
- `repo`: string, repo name
- `content`: string, full memo content (if no memo, tries README; if neither exists, `"(no memo available)"`). Newlines encoded as `\n`
- `remoteAhead`: number, commits the pool repo is behind upstream (calculated after fetch; 0 if fetch failed)
- `memoBehind`: number, commits the memo is behind pool repo's current HEAD (0 = up to date)

### `orbit done --json`

```json
{
  "workspace": "feat-auth",
  "status": "done",
  "doneAt": 1700000000,
  "prs": [
    "https://github.com/org/backend/pull/42"
  ]
}
```

Field descriptions:
- `workspace`: string, workspace name
- `status`: string, always `"done"`
- `doneAt`: number, Unix timestamp (seconds) when marked as done
- `prs`: array of string, PR URLs passed via `--pr` (empty array `[]` when none provided)

### `orbit context --json`

Bare form (cruise block — only worktrees with something pending are listed):

```json
{
  "workspace": "feat-auth",
  "path": "/path/to/project/feat-auth",
  "goal": "Implement OAuth2 login flow",
  "state": "active",
  "mode": "cruise",
  "worktrees": [
    { "name": "backend", "jots": 3, "jotLevel": "building", "behind": "", "memoState": "thin" }
  ]
}
```

Field descriptions:
- `workspace`: string, workspace name
- `path`: string, absolute path of the workspace directory
- `goal`: string, workspace goal (empty string when not set)
- `state`: string, workspace lifecycle state (`"active"` | `"done"`)
- `mode`: string, `"cruise"` — present in JSON only; the markdown cruise block omits it (machine-facing marker, not context for the agent or human reader)
- `worktrees`: array, per-worktree status for worktrees with pending work only (empty when all are fine) — the slim cruise-block view, a subset of the `--reignite` worktrees schema
  - `name`: string, repo name
  - `jots`: number, unpopped jot entries
  - `jotLevel`: string, `"building"` | `"overflow"` | `""` (silent band)
  - `behind`: string, commits behind the worktree branch's upstream (`""` when none, `"untracked"` when no upstream — raw-mode branch pushed without `git fetch origin <branch>`)
  - `memoState`: string, `"ok"` | `"thin"` | `"over"`

`--prime` adds `"mode": "prime"` and a `repos` array (the pool roster — distinct from the bare form's `worktrees`):

```json
{
  "...": "... durables as above ...",
  "mode": "prime",
  "repos": [
    { "name": "backend", "brief": "Go REST API, sqlc-generated DB layer" }
  ]
}
```

- `repos`: array, the pool roster (repos available to `orbit add`) — the cold-start "add menu"; empty pool outputs `[]`. This is the project-root `.repos/` directory listing, not workspace worktrees.
  - `name`: string, repo identity in the pool
  - `brief`: string, one-line brief resolved via the shared fallback (index → memo → README); empty string when no brief is available anywhere

`--reignite` adds `"mode": "reignite"` and a full worktrees array:

```json
{
  "...": "... durables as above ...",
  "mode": "reignite",
  "worktrees": [
    {
      "name": "backend",
      "branch": "feat/oauth2",
      "memoBehind": 3,
      "remoteAhead": 5,
      "jots": 2,
      "jotLevel": "building",
      "behind": "",
      "memoState": "ok",
      "jotEntries": ["entry point: cmd/server/main.go"],
      "memo": "Go REST API, sqlc-generated DB layer\n\n## When to add (roles)\n..."
    }
  ]
}
```

- `worktrees`: array, one entry per worktree repo (unfiltered, unlike the bare form)
  - `memoBehind` / `remoteAhead`: numbers, two-layer staleness distances (reignite fetches, like `orbit info`)
  - `jotEntries`: array of string, unpopped jot entries (full list; the markdown block inlines only up to `jot.bufferSize`)
  - `memo`: string, full memo content (`""` when no memo)
