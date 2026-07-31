# Lifecycle Management

> Detailed behavior definitions for responsibility division, orbit new design, orbit done semantics, orbit prune reclamation flow, branch protection determination, and environment variables.

## Responsibility Division

- **orbit**: structural management (new, add, prune), worktree operations, uniqueness guarantees, source pool management (clone/repos/info/memo)
- **agent** (via skill): goal -> repos -> info -> select repo -> add -> work (jot discoveries) -> aggregate jot into memo -> done
- **human**: provides task description, optional name override, triggers prune

The **agent** role splits into two when work is delegated (see PRINCIPLES.md Principle 7):
- **owner agent** — holds lifecycle (`new`/`done`/`goal`), knowledge aggregation (`memo` write-back, a read-modify-write step), and pool / cross-workspace ops (`clone`/`sync`/`config`). Exactly one owner per workspace.
- **worker sub-agent** — dispatched for exploration/implementation. Owns the whole exploration path (`repos`/`info`/`add`/`switch`, edit/commit in worktrees, `jot` capture) but reports owner-only needs back rather than running them.

This division is key to keeping commands simple: orbit provides atomic operations, and the agent orchestrates them into a coherent discovery-first workflow via skills. Specific orchestration rules are in `skills/CONSTRAINTS.md`.

## `orbit new` Design

### Command Forms

```bash
orbit new "fix API"                         # -> task-01/, prints cd + startup hint
orbit new "fix API" --name api-v2           # -> api-v2/
orbit new "fix API" --exec "claude"         # -> creates then launches agent directly inside the directory
echo "fix API definition" | orbit new       # -> reads goal from stdin (convenient for manual piping)
orbit new --no-goal                         # -> no-goal creation (free exploration mode)
```

### Core Behavior

1. Read goal: positional argument `"<goal>"` takes priority; if missing, the source depends on the environment — when `ORBIT_EDITOR` is set or stdin is an interactive terminal, an editor is opened; when stdin is piped (non-interactive), the goal is read from stdin. An empty result (blank editor buffer or empty pipe) **aborts** with an error rather than falling back — use `--no-goal` to intentionally create a workspace without a goal (free exploration mode)
2. Locate project root: traverses upward from CWD looking for `.repos/`; found -> uses that location as root; not found -> implicitly initializes at CWD (creates `.repos/` + `.repos/.orbit` + `.repos/README.md` pool marker) then uses CWD as root
3. Creates workspace directory + writes `.orbit` file (records goal and created)
4. Prints next steps (follows scaffolding tool conventions, does not auto cd)
5. If `--exec` is present -> executes the specified command directly inside the new directory

### Naming Strategy

- Default `task-{auto-increment}` (scans existing task-* directories, takes max+1)
- `--name` for manual override
- `--auto-name` (mid-term, **not yet implemented**) opt-in calls agent (single inference without directory context)

#### `--auto-name` (Mid-term Capability — planned, not yet implemented)

Calls a lightweight agent based on goal text to generate a semantic directory name (e.g., "fix API definition" -> `api-definition-refactor`). Single inference, no workspace context needed, falls back to default `task-{N}` strategy on failure. This flag is not accepted by the current CLI.

### `orbit new` Execution Location

`orbit new` can be executed from any location; the workspace directory is always created under project root:

| Current Location | Behavior |
|-----------------|----------|
| Project root (has `.repos/`) | Normal workspace creation |
| Subdirectory of project root (including inside workspace, inside worktree) | Locates root, creates workspace under root |
| Unrelated directory (no `.repos/` discoverable) | Implicitly initializes at current directory, then creates |

## Marking Complete (`orbit done`)

`orbit done` writes to the workspace's `.orbit` file (format described in [spec-metadata](./spec-metadata.md) "Workspace Metadata" section).

Pre-completion warnings (stderr, non-blocking — `done` still succeeds): before marking complete, `orbit done` emits per-repo reminders so knowledge is not lost on the subsequent `prune`. Each repo with remaining work gets one merged line, combining any of the conditions that apply to it (e.g. `orbit: backend: 3 jots remain (pop + merge), memo over budget (curate once)`):
- **Jot entries remain** — any un-popped jots, however few: `N jots remain (pop + merge)`. When jots are present the `memo thin` branch is skipped (the queue implies the card will be reassessed at aggregation time, not now).
- **Thin memo with no capture** — the memo is thin (missing, or fewer than `memo.minLines` non-blank lines, default 4) and the repo has no leftover jots: `memo thin (explore + write)`. This is the CLI backstop for the memo-surfacing model when hooks are absent.
- **Over-budget card** — the card exceeds `memo.maxLines + memo.minLines`: `memo over budget (curate once)` (best-effort, never blocks; may combine with the `jots remain` branch above).

When jots remain or a card is over budget, it also prints the `card budget is <min>~<max> lines` reminder. When any per-repo warning fired, it prints one closing line — `orbit: only memo survives done` — because session working memory and the jot queue do not survive done; the memo is the only durable artifact.

Idempotent semantics: executing `orbit done` again on an already `status=done` workspace overwrites `done-at`/`done-date` with the current time; `--pr` appends to the existing PR list (no deduplication, allowing multiple additions). This supports scenarios where multiple repos submit PRs in batches.

## Reactivation (setting a goal on a done workspace)

Setting a goal with `orbit goal "<text>"` on a workspace whose `status=done` reactivates it: `status`, `done-at`, `done-date`, and the `pr.url` list are cleared, returning the workspace to the default active state. Rationale: setting a goal signals a new work cycle, and a reused workspace must leave `orbit prune` eligibility (only `status=done` workspaces are reclaimed) so active work is not deleted; the previous cycle's completion record (done timestamps + PR history) belongs to the old goal and would otherwise pollute the new one. A reactivation notice is printed to stderr.

`orbit goal --clear` does **not** reactivate — clearing a goal is not the start of new work.

Only `orbit goal` reactivates. Resuming work another way does not clear `done`: `orbit add` on a done workspace keeps the status and instead warns that the workspace is prune-eligible, pointing the user to `orbit goal` to reactivate first.

## `orbit prune` Reclamation Flow

```bash
orbit prune                       # clean up all workspaces with status=done (from the project root)
orbit prune --older 30d           # clean up done-at older than 30 days with status=done
orbit prune --older 30d --force   # same as above, skips branch protection AND the data guards below
orbit prune task-01               # clean up a specific workspace (requires status=done)
orbit prune task-01 --force       # specific + skips branch protection AND the data guards below
orbit prune --dry-run             # preview, no execution
orbit prune --verify              # checks PR status to confirm merged before cleanup
```

The time source for `--older` is the `done-at` field in the workspace `.orbit` file (only workspaces with `status=done` are cleaned up, so `done-at` always exists). Falls back to `created` if missing, then falls back to directory mtime.

## Prune Safety Guards

`orbit prune` is a root-level destructive operation and guards against destroying live work:

- **Root-level only**: it refuses to run when the CWD is inside any workspace — cross-scope destructive ops belong to the scope above (workspace = agent scope boundary). The comparison is on physical paths, so a cwd reached through a symlink cannot slip past it.
- **Active-session protection**: it never prunes a workspace the current session is rooted in. The check walks the process ancestry (per-ancestor cwd via `lsof` on macOS, `/proc/<pid>/cwd` on Linux; parent pids from `/proc/<pid>/stat` when available, else `ps`) instead of trusting the invoking shell's CWD — a shell can `cd` out, but a session's launch directory stays on its process tree. Target paths are normalized to physical form (`pwd -P`) so symlinked roots (e.g. `/var` → `/private/var`) still match the resolved cwds reported by the OS. On the enumeration path the candidate is skipped; on the named-target path prune errors out. The ancestry walk is best-effort and **announces its own blind spot**: if not a single ancestor cwd could be read (no `/proc`, no `lsof`, or a `ps` without `-o` support), prune says the guard is inactive rather than proceeding as if it had checked (`orbit doctor` reports the facility too).
- **Uncommitted-changes protection**: a candidate with a dirty worktree (uncommitted or untracked changes) is skipped unless `--force` is given; `--dry-run` reports it as `would skip`. An unreadable `git status` counts as dirty — "cannot tell" is not "clean".
- **Foreign-repo protection**: a candidate holding a top-level git repo with no pool counterpart is skipped unless `--force` is given. A pool worktree always has a `.git` *file* (gitdir pointer), so a `.git` *directory* is an independent clone even under a pool repo's name — typically a `git clone` run inside the workspace. Its objects live in its own `.git`, so the workspace removal would destroy history that exists nowhere else — the worktree guards do not cover it.
- **Unmerged-jot protection**: a candidate whose workspace `.orbit` still holds jot entries is skipped unless `--force` is given, with the per-repo counts named. `done` warns about residual jots once; this is the last checkpoint before the queue is destroyed with the directory.

Guard scope is the workspace's **top level**: the data guards enumerate every direct child that is a git repo (pool-backed or foreign) plus the workspace `.orbit` — not just the pool-backed worktrees. A repo nested deeper inside a plain subdirectory is outside the guards' view and is removed with the directory.

The three data guards report **together**: all applicable reasons are joined into one skip line (`; `-separated) rather than surfacing one per run, because `--force` releases them as a single decision and the operator needs the whole set to make it once.

`--force` releases the three **data** guards (uncommitted changes, foreign repo, unmerged jots) and the branch protections. It does **not** release the root-level or active-session guards: those protect the ground the running session stands on, not data the user can choose to discard.

Branch cleanup reports what it leaves: a local branch shaped like this workspace's (`*/<workspace>/*`) but outside the configured `branch.prefix` is named rather than silently left behind — it is not orbit's to delete (a raw-mode branch, or one created while the prefix held another value). Git holds the branch names, so they remain the recoverable record even if the config that named them is lost.

The exact messages an agent sees (message text is part of the contract):

```text
orbit: prune must be run from the project root
orbit: cannot prune workspace with an active session: <ws>      # named target
orbit: skipping <ws>: workspace has an active session            # enumeration
orbit: skipping <ws>: uncommitted changes in: <repos>; git repos not from the pool: <repos>; unmerged jots in: <repo> (<n>)
orbit: <repo>: left branch outside branch.prefix: <branches>
orbit: cannot read process ancestry on this host: the active-session guard is inactive
```

Under `--dry-run` each skip is reported on stdout as `would skip: <ws> (<reasons>)`. None of these name `--force`: a refusal must not double as instructions for getting around it.

Rationale: the pre-guard cwd check ("skip the workspace you are currently in") was self-defeating — its skip message told an agent exactly how to route around it (`cd` out and prune by name), and `git worktree remove --force` destroyed uncommitted changes with no check at all.

## Three-Layer Branch Cleanup Protection

When prune deletes a workspace, it also needs to clean up local branches. The collection scope includes two parts:
- The branch currently checked out by each worktree (may be a plain branch or tracking branch)
- All local branches matching the `ws/<workspace>/*` prefix (covers base branches and other branches that have been switched away from)

```bash
for repo_dir in <workspace>/*/; do
  branch=$(git -C "$repo_dir" branch --show-current)
  repo_name=$(basename "$repo_dir")
  main_repo=".repos/$repo_name"
  # Collect current branch
  branches_to_clean+=("$branch")
  # Collect prefixed branches from same workspace
  git -C "$main_repo" for-each-ref --format='%(refname:short)' "refs/heads/ws/<workspace>/" \
    | while read b; do branches_to_clean+=("$b"); done
  # Deduplicate then choose deletion strategy by protection level
done
```

Three-layer determination:

| Condition | Action | Rationale |
|-----------|--------|-----------|
| Has PR URL and `gh pr view` confirms merged | `git branch -D` (force) | Externally confirmed merged, safe |
| No PR URL, but after `git fetch` branch is merged into origin/\<default-branch\> | `git branch -d` (safe) | Git native protection, confirmed reachable |
| Neither of the above satisfied | Skip, warn user — when the branch's *content* is already upstream (squash/rebase merge rewrites SHAs, defeating the ancestor check), the warning names it and prints the exact `git -C <pool> branch -D <branch>` cleanup command | Cannot confirm, no risk taken; content equivalence is detected cost-ordered — `git merge-tree` (≥ 2.38, definitive) then `git cherry` (1:1 patch equivalence) — and prune runs at the project root, where the operator is human |

### `gh` CLI Dependency Notes

- `--verify` and the first-layer determination depend on `gh` CLI (best effort)
- If `gh` is not present -> stderr warning, skips PR status check, degrades to second layer (git merged check)
- Without `--verify`, `gh` is not called by default (zero external dependency path)

### Fetch Refspec Reconciliation

The pool is a single-branch clone, so `orbit switch` to an existing remote branch registers a per-branch fetch refspec (`+refs/heads/<branch>:refs/remotes/origin/<branch>`) to materialize the remote-tracking ref. Every configured exact refspec must point at a branch the remote actually has — one stale entry makes every bare `git fetch` fail with `couldn't find remote ref`, in every worktree of that pool.

Every orbit command that already fetches opportunistically — `orbit sync`, `orbit info`, the `orbit context --startup` reignite block — plus `orbit prune` reconciles refspecs with the remote first:

- **Remove** a refspec when the remote no longer has the branch (typical: auto-deleted on PR merge; also legacy refspecs registered for branches that were never pushed). The stale `refs/remotes/origin/<branch>` ref is deleted along with it.
- **Register** a refspec when a local branch tracks a remote branch that exists but has no refspec (scoped/raw branch pushed since last run). The bare fetch that follows materializes the tracking ref immediately.
- **Leave foreign refspecs untouched.** Only orbit-managed exact refspecs are reconciled — an entry orbit never wrote (e.g. a user-configured wildcard `+refs/heads/*:refs/remotes/origin/*` converting the pool to full fetch) is never removed or complemented, in either phase.

`orbit switch -c` deliberately does NOT pre-register a refspec for the new branch — the branch doesn't exist on the remote yet, so the refspec would break every bare `git fetch` until the first push. The upstream config is still wired up front (push/pull work immediately); the tracking ref materializes at the first fetching command after the push (session start / `orbit info` / `orbit sync`), or instantly via a manual `git fetch origin <branch>`. Conversely, `orbit switch <branch>` to a branch that turns out not to exist on the remote rolls back the refspec it just registered before failing, so the invariant above is never violated between reconcile touchpoints.

`orbit prune --dry-run` reports `would remove stale fetch refspec: <branch>` / `would add fetch refspec: <branch>` without mutating. Reconciliation is skipped entirely when the remote is unreachable, so unverifiable refspecs are never removed by mistake.

## Multi-Repo Workspace Completion Semantics

- All repos' PRs confirmed merged -> workspace is fully reclaimable
- Partially complete -> `orbit prune` reports status, does not auto-clean
- No PR info but marked done -> relies on git's own merged check

## Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `ORBIT_ROOT` | Overrides project root auto-discovery, explicitly specifies the project root path | None (traverses upward from CWD looking for `.repos/`) |
| `ORBIT_EDITOR` | Editor used to compose free-form text (goal, jot, memo) when no argument/stdin is given; also forces editor mode in non-TTY contexts | Falls back to `VISUAL`, then `EDITOR`, then `vi` |

`ORBIT_ROOT` use cases:
- CI/CD environments where CWD is not under project root
- Scripts that need to explicitly specify the operation target

## Branch Prefix (`branch.prefix`)

The scoped-mode branch prefix is **project config**, not an environment variable:

```bash
orbit config branch.prefix team     # scoped branches become team/<workspace>/<name>
```

Default `ws`. It is read from `.repos/.orbit`.

Why config and not an env var: the prefix is written into every branch name orbit creates (`orbit add`, `orbit switch -c`) **and** it is the selector `orbit prune` matches on to decide which branches are orbit's to delete. Those two moments are often days and sessions apart, so the value has to be stable and durable. A per-invocation env var could differ between them, with two failure modes:

- prefix changed after creation → prune looks under the new prefix, never finds the old branches, and they leak;
- prefix pointed at a namespace orbit never created (e.g. `release` while real `release/<x>/*` branches exist) → prune treats *foreign* branches as its own and deletes them under `--force`.

Two write-side guards follow from that:

- The value is validated on write (one path segment, legal in a git refname, no leading `-`), because a bad value now persists.
- Changing it is **refused while any branch still carries the current prefix** (`branch.prefix is part of existing branch names under '<current>/': <repo> (n)`). Reclaim or rename those branches first — the prefix is part of their names, and moving it would orphan them.

Use cases:
- Teams using different prefixes to avoid conflicts with existing branch naming
- Multi-layer workspace management schemes distinguishing different levels

> Note: The slash is automatically added by orbit (format: `<prefix>/<workspace>/<name>`); do not include a trailing slash when setting.
