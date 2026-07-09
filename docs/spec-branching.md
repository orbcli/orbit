# Branching Strategy

> Detailed behavior definitions for remote and push target management, orbit add branch behavior, orbit switch semantics, Raw vs Scoped modes, branch cleanup logic, and visibility balance.

## Remote and Push Target Management

Push target is entirely managed by git remote; orbit does not maintain any additional push metadata.

### Push Target Configuration Methods

Uses git's native fetch/push URL separation mechanism (`remote.origin.pushurl`):

```bash
# Method 1: Specify fork at clone time (recommended)
orbit clone git@github.com:org/backend.git --push git@github.com:me/backend.git
# → orbit executes git remote set-url --push origin <fork-url>
# → worktrees automatically inherit, transparent to agents

# Method 2: Existing repo, agent uses native git commands within worktree
cd task-01/backend/
git remote set-url --push origin git@github.com:me/backend.git
# → worktree shares .repos/backend's git directory
# → Changes take effect immediately for all worktrees of the same repo across workspaces
```

Effect: `git push origin` pushes to the fork, `git fetch origin` pulls from upstream. The agent doesn't need to remember additional remote names.

```bash
git remote -v
# origin  git@github.com:org/backend.git (fetch)
# origin  git@github.com:me/backend.git (push)
```

### Agent Perspective

Agents see the pool overview via `orbit repos` (name + url + brief).
When agents need more information, they use `orbit info backend` to view per-repo markdown (see [spec-metadata](./spec-metadata.md)).

Agents operate within the workspace using native git commands:
```bash
git remote -v                          # View fetch/push URLs (confirm push target)
git push origin <branch>               # Push (automatically uses pushurl, no need to care if it's a fork or direct push)
git fetch origin                       # Fetch from upstream
```

## Repo-Level Push Configuration

`orbit clone` sets `push.default=upstream` in `.repos/<repo>`:

```bash
git -C .repos/<repo> config push.default upstream
```

Effect: All worktrees inherit this configuration; `git push` automatically pushes to the remote branch pointed to by upstream (regardless of differences between local branch name and remote branch name). This allows `ws/<workspace>/<name>` local branches to directly `git push` to `origin/<name>`.

For existing repos (not set at clone time), `orbit switch` / `orbit switch -c` checks and applies this setting before execution.

## `orbit add` Branch Behavior

```bash
orbit add backend
# → Creates worktree, local branch = ws/<workspace>/<default-branch> (e.g., ws/task-01/main)
# → Created from origin/<default-branch>, upstream set to origin/<default-branch>
# → This is a local starting point from which the agent branches off to work
```

`orbit add` sets upstream tracking so that `git status` and `orbit status` can show accurate ahead/behind information. This lets agents and humans assess whether code is current before working or writing memos.

Orbit maintains no push metadata and takes no stance on push workflow — pushing is native git, gated by the agent's permission mode. Fork isolation via `orbit clone --push <fork-url>` remains available for those who want it (it sets git's `pushurl`).

## `orbit switch` Command

```bash
orbit switch [repo] <name>           # Switch to an existing remote branch
orbit switch -c [repo] <name>        # Create a new tracking branch from HEAD
```

`repo` is optional: inferred from CWD when executed within a worktree; required when executed at the workspace root.

### `orbit switch <name>` (Switch to Existing Remote Branch)

```bash
orbit switch feat-x              # Within worktree, repo inferred from CWD
orbit switch backend feat-x      # At workspace root, specify repo
# 1. Local ws/<workspace>/feat-x already exists:
#    a. Already checked out in another worktree → error: "branch checked out in another worktree"
#    b. Not checked out in another worktree → checkout directly
# 2. Does not exist locally, origin/feat-x exists → fetch + create ws/<ws>/feat-x + set upstream
# 3. origin/feat-x does not exist → error: "branch not found on remote, use -c to create"
```

How upstream is set (purely local, no remote writes):
```bash
git config branch.ws/<ws>/feat-x.remote origin
git config branch.ws/<ws>/feat-x.merge refs/heads/feat-x
```

### `orbit switch -c <name>` (Create New Tracking Branch)

```bash
orbit switch -c feat-x              # Within worktree
orbit switch -c backend feat-x      # At workspace root
# 1. git ls-remote --heads origin feat-x checks if the branch already exists on remote
#    → Already exists → error: "already exists on remote, use switch without -c"
# 2. Create ws/<ws>/feat-x from HEAD
# 3. Set upstream config (same as above, purely local)
# 4. No push — the remote branch is created when the agent first runs git push
```

## Raw Mode (Default, Pure Git)

Suitable for scenarios where the agent self-manages branches; `orbit switch` is not needed:

```
1. orbit add backend
   → worktree on ws/task-01/main (upstream: origin/main)

2. git checkout -b feature/api-refactor
   → plain local branch (no prefix, no upstream)

3. Work, commit

4. git push origin feature/api-refactor
   → Push to fork, branch name used directly

5. Submit PR on the web
```

Characteristics:
- No orbit branch management (`orbit add` onward is all native git)
- The ws/ base branch tracks upstream for status visibility; feature branches do not
- Branch names have no prefix (no conflict risk when pushing to fork)
- Push target determined by origin's pushurl

## Scoped Mode (orbit switch, Prefix Isolation)

Suitable for private repos with direct push access, or when cross-workspace branch isolation is needed:

```
1. orbit add backend
   → worktree on ws/task-01/main (upstream: origin/main)

2. orbit switch -c feat-api-refactor
   → Creates ws/task-01/feat-api-refactor from HEAD
   → Sets upstream → origin/feat-api-refactor (purely local config)

3. Work, commit

4. git push
   → push.default=upstream takes effect
   → Local ws/task-01/feat-api-refactor pushes to origin/feat-api-refactor
   → Remote branch name is clean, no prefix

5. git push (subsequent pushes also just use git push)
```

Switching to an existing remote branch scenario:
```
1. orbit add backend
   → worktree on ws/task-01/main (upstream: origin/main)

2. orbit switch hotfix-123
   → fetch origin/hotfix-123
   → Create ws/task-01/hotfix-123 tracking it

3. Work, commit, git push
```

Characteristics:
- Local branches have `ws/<workspace>/` prefix (isolating multi-workspace same-repo conflicts)
- Remote branches have no prefix (`push.default=upstream` + config auto-strips it)
- orbit performs no remote writes; push timing is entirely up to the agent

## Cleanup Logic

Complete steps when `orbit prune` deletes a workspace (see [spec-lifecycle](./spec-lifecycle.md) "Three-layer protection for branch cleanup"):
1. Record each worktree's current branch name + scan all local branches with `ws/<workspace>/*` prefix
2. `git worktree remove <path>` — remove the worktree
3. Execute `git branch -d/-D` for all branches collected in step 1 (determined by three-layer protection)
4. `git config --remove-section branch.<name>` — clean up upstream config entries (only scoped mode branches have these entries)

Why step 1 scans prefixed branches: The base branch created by `orbit add` (e.g., `ws/task-01/main`) is no longer the current branch after the agent switches away; relying only on the current branch would leak it.

## Visibility vs Hiding Balance

Users can see, correct, and delete (triggering rebuild), but can also completely ignore:
- Workspace directory structure → visible, defines the agent's context boundary
- Repo subdirectories → visible, humans need to open editors and run tests
- `.orbit` metadata → hidden file, not seeing it doesn't affect work, but can be manually corrected
- Branch names → decided by the agent, visible to humans on PR pages
- Worktree internal connection details → implementation detail, completely unexposed
