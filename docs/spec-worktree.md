# Worktree Model

> How orbit uses git, collected in one place: the root decision — one pool clone per repo, one worktree per workspace — and everything that follows from it: config ownership, the fetch discipline, the branching strategy, push routing, tracking display, prune's git binding, plus the complete closure of orbit's dependencies on git itself.

## Root Decision: One Pool, Many Worktrees

Orbit's premises narrow the substrate to one choice. From [PRINCIPLES.md](../PRINCIPLES.md): directory and git are the structural source of truth (Principle 2); the core depends on git + bash alone (Principle 5); and workspaces must be real directories that existing toolchains read with zero adaptation — `go.work`, Cargo/pnpm workspaces and the like resolve by real relative paths.

Under those premises the alternatives eliminate themselves (full rationale in PRINCIPLES.md → Rationale for Solution Choices):

- **Manifest-first** — a config file that carries mental overhead and drifts from the actual directories. The goal is first-class workspaces, not first-class configs.
- **Reference-clone-first** (`git clone --reference`) — per-clone refs and config to maintain, object sharing through alternates whose gc coupling is fragile, and N fetches per repo where one would do.
- **Sandboxing as the enforcement basis** — container runtimes and ACLs break the portability principle; under the single-owner model, conventions plus a few machine-checked refusals suffice.

What remains: **one clone per repo (the pool, `.repos/<repo>`) plus a `git worktree` per workspace**. Real relative paths; one object store shared through git's own gitdir mechanism (gc-safe, unlike alternates); one fetch serving every workspace; an `orbit add` that costs a worktree registration instead of a re-clone.

Everything else in this document is a consequence of that choice:

| Consequence of the worktree choice | Problem it creates | Where it is solved |
|---|---|---|
| All workspaces share the pool's refs namespace | same-name branches collide across workspaces; branch attribution must survive workspace deletion | [Branching Strategy](#branching-strategy) |
| `git config` inside a worktree writes the pool's *shared* config | agent/user edits reach state orbit maintains | [Config Ownership](#config-ownership) |
| One pool serves every workspace | fetch economy: fetch once, not N times — but a bare fetch pulls the whole map | [Touchpoint Fetch Discipline](#touchpoint-fetch-discipline) |
| Scoped local names differ from remote names | git's default `push.default=simple` refuses a bare `git push` | [Push Routing and Remote Targets](#push-routing-and-remote-targets) |
| The pool is a lean single-branch clone that must resolve every upstream | `@{upstream}` needs a map the initial clone does not have | [Tracking Display](#tracking-display) |

## Design Priorities

When two git-level designs both work, orbit chooses by three priorities, in order — the git-domain form of the principles in [PRINCIPLES.md](../PRINCIPLES.md):

1. **Minimal surprise.** The moat is zero-cost toolchain integration: `@{u}`, `git status` upstream lines, a bare `git rebase` must work in a worktree with zero adaptation, and fetches must stay light. A design that makes native git fail cryptically sends agents into repo-debugging — editing shared config to "fix" it — which is worse than the original problem. (Principle 1: the workspace is the primary interaction surface, and git is part of that surface, not orbit's to reshape.)
2. **Simple mechanism, no hacks.** One sentence must explain it to a new user. Per-repo behavior forks, and designs that need four layers of protocol knowledge to derive, are not accepted. (Principles 5 and 6: lightweight dependencies; the foundation is settled once and only added to, never redone.)
3. **Efficiency and cost.** Clone-time economy balanced against repo size; recoverable bloat is an acceptable compromise.

**The root fact** the fetch model is built on: `@{upstream}` resolution and the fetch refspec are the same config object (`remote.origin.fetch`) — physically inseparable. Per-branch fetch bookkeeping therefore fights the very mechanism that displays tracking; the full wildcard map is the one primitive that serves both.

Two operational rules derive from priorities 1 and 2 and are enforced in [Git Dependency Closure](#git-dependency-closure): every git dependency is a potential agent-surprise source, so the dependency set only shrinks and every addition passes an explicit review; and a config key orbit depends on is managed state, per [Config Ownership](#config-ownership).

## Actors and Invocation Layers

Two actors — human and agent — reach git through three layers:

- **orbit commands** exist only for operations that cross the workspace ↔ `.repos` boundary (the inclusion rule in [spec-commands](./spec-commands.md));
- **native git inside a worktree** is the default path for everything else — orbit deliberately does not wrap it;
- **native git inside `.repos/`** is nobody's path: the pool's internals are orbit-maintained state, and direct writes there are outside every guard (see [spec-lifecycle](./spec-lifecycle.md) → Out of Scope).

One fact makes this layering load-bearing: **a worktree is not a config boundary.** `git config` run inside a worktree writes the pool repo's shared config — the very state the next touchpoint converges. Which keys that makes off-limits is the next section.

## Config Ownership

A config key orbit depends on is **managed state**, not a one-time write. Managed means one of:

- **Converged** — written at clone, re-asserted at every touchpoint (`orbit sync` / `orbit info` / `orbit context --startup` / `orbit prune`), one predicate per key, no remote comparison:

  | Key | Managed value | Mode key (default `always`) |
  |---|---|---|
  | `remote.origin.fetch` | exactly `+refs/heads/*:refs/remotes/origin/*` (the on-disk form of `git remote set-branches origin "*"`) | `git.fetchAllBranches` |
  | `fetch.prune` | `true` | `git.fetchPrune` |
  | `push.default` | `upstream` | `git.pushUpstreamByDefault` |

  Mode semantics: `always` = orbit keeps the value (default); `once` = written once at clone, then the value is the user's (the standard choice for a team with its own refspec or push conventions); `never` = never written, never corrected. `once`/`never` pools are user territory: untouched, unreported. Every actual convergence is reported on stderr at the moment it happens, one line per key, each carrying its escape-hatch command (contract in [spec-warnings](./spec-warnings.md) → Config convergence lines); under `orbit prune --dry-run` the same convergences preview on stdout unprefixed as `would converge …` lines.

  Why `push.default` carries an escape hatch even though maintaining it is harmless under any refspec layout: the escape exists for the same profile that customizes the fetch layout — teams with their own conventions, including push policies like `push.default=nothing` (mandated explicit pushes). Harmlessness is why it is safe to converge by default, not a reason to remove the hatch; and every managed key sharing one three-mode shape is itself the simplicity priority — one rule, not two.

  **The switches govern config ownership, not ref hygiene.** Ref cleanup follows the layout *shape*, independently of the mode: whenever the full wildcard is in place, the touchpoint's closing `git remote prune origin` converges the refs of remote-deleted branches. A `once` pool that kept the baseline without narrowing it still gets that cleanup — the switch says who owns the config, not whether refs are pruned; a user who reads `once` as "don't touch my pool" should know the refs follow the layout, not the switch.
- **Lifecycle-managed** — `branch.<name>.remote` / `.merge`: wired by `orbit switch`, dropped with the branch by git itself, orphaned sections converged by prune (D3). This pair defines *the* tracked set the touchpoint fetch enumerates, and routes scoped pushes.

**Premise-only, explicitly not managed:** `core.logAllRefUpdates` and the `gc.*` retention knobs (the native deletion safety net and its window — user policy; see [Git Dependency Closure](#git-dependency-closure) feature 6 for why overriding them pool-locally would be a silent config rewrite for near-zero protective value), `remote.origin.url` / `pushurl` (git's own state, read for display), and the user's identity/global layers.

**The rule for agents and users in worktrees:** the managed keys above are off-limits to hand edits. An edit to a converged key is reverted at the next touchpoint (with a stderr note); an edit to a scoped branch's `branch.*` silently corrupts tracking and prune's bookkeeping. The one sanctioned write is the documented fork path, `git remote set-url --push origin <fork-url>` (see Push Routing below). Every other key is untouched by orbit and uninteresting to it.

## Touchpoint Fetch Discipline

Every orbit command that fetches — `orbit sync`, `orbit prune` — follows the same discipline. The list is deliberately short: auto-fetch without an async daemon taxes a synchronous caller for advisory freshness, so read paths never fetch — `orbit info` (a screening command) and the `orbit context --startup` reignite block (the session's main path; cf. VSCode's background autofetch, which never blocks startup either) stay purely local and read last-fetched refs. A future daemon that fetches off the main path is the only shape under which auto-fetch may return:

- **Maintain, then fetch named branches only**: config maintenance ([Config Ownership](#config-ownership)) runs first; then the default branch plus every remote branch a local branch tracks (`branch.*.merge`, deduped — several local branches can share one upstream), one explicit `+refs/heads/<b>:refs/remotes/origin/<b>` refspec per fetch. Never a bare fetch: under the wildcard map it would pull every branch's objects, defeating the single-branch economy — that pull is reserved for the user's own `git fetch` / `git pull`, a one-time step onto full-clone footing.
- **A tracked branch that does not fetch is tolerated**: git's `couldn't find remote ref` fatal is swallowed — the touchpoint must never leak the error this model exists to eliminate — and one closing `git remote prune origin` converges the refs of remote-deleted branches (online it cleans; offline it fails and deletes nothing). The prune runs only while the full wildcard is in place — a shape judgment, so a user-narrowed layout is exempt by construction.
- **The default branch is the one loud failure**: if it does not fetch while the remote answers a probe, the remote may have lost its default branch — a repo-level event, reported as a WARNING on stderr. Offline everything fails quietly, as before.
- **Reads come after the fetch**: within one touchpoint, tracking refs are fetched and converged first, then read (prune's residue scan, context's upstream display).

`orbit switch -c` registers nothing: the upstream config is wired up front, and under the wildcard map the first push materializes `refs/remotes/origin/<branch>` on the spot. `orbit switch <branch>` to an existing remote branch materializes the ref with the same explicit colon fetch, layout-independent — a narrowed user layout works the same.

`orbit prune --dry-run` reports `would converge fetch config: git remote set-branches origin "*"` / `would converge fetch config: git config fetch.prune true` / `would converge push routing: git config push.default upstream` under the pool-maintenance section without mutating (and without fetching).

## Branching Strategy

Sharing one refs namespace across workspaces creates two needs a standalone clone never has: same-name branches must not collide across workspaces (git refuses to check out one branch in two worktrees), and a branch must remain attributable to its workspace after the workspace directory is gone (prune's ghost reclamation). The answer is structural: encode the workspace in the branch name itself — `<prefix>/<workspace>/<name>` — the minimal encoding that keeps attribution after the directory disappears. (A substrate with per-workspace refs namespaces — separate clones, sandboxes — has neither need.)

### The Prefix (`branch.prefix`)

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

### `orbit add` Branch Behavior

```bash
orbit add backend
# → Creates worktree, local branch = ws/<workspace>/<default-branch> (e.g., ws/task-01/main)
# → Created from origin/<default-branch>, upstream set to origin/<default-branch>
# → This is a local starting point from which the agent branches off to work
```

`orbit add` sets upstream tracking so that `git status` and `orbit status` can show accurate ahead/behind information. This lets agents and humans assess whether code is current before working or writing memos.

Orbit maintains no push metadata and takes no stance on push workflow — pushing is native git, gated by the agent's permission mode. Fork isolation via `orbit clone --push <fork-url>` remains available for those who want it (it sets git's `pushurl`).

### `orbit switch` Command

```bash
orbit switch [repo] <name>           # Switch to an existing remote branch
orbit switch -c [repo] <name>        # Create a new tracking branch from HEAD
```

`repo` is optional: inferred from CWD when executed within a worktree; required when executed at the workspace root.

#### `orbit switch <name>` (Switch to Existing Remote Branch)

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

#### `orbit switch -c <name>` (Create New Tracking Branch)

```bash
orbit switch -c feat-x              # Within worktree
orbit switch -c backend feat-x      # At workspace root
# 1. Create ws/<ws>/feat-x from HEAD (no remote check — git switch -c doesn't check either)
# 2. Set upstream config (same as above, purely local)
# 3. No fetch-refspec registration — under the wildcard map the first push
#    materializes refs/remotes/origin/<name> on the spot
# 4. No push — the remote branch is created when the agent first runs git push
```

**Post-creation conflict note**: if the remote already has `<name>` with different commits, a stderr note warns about the push conflict. When transferring a raw-mode branch (same name, no upstream — the agent already knows the remote has it), this warning is suppressed.

### Scoped Mode (orbit switch, Prefix Isolation)

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
- Local branches have `ws/<workspace>/` prefix (isolating multi-workspace same-repo conflicts). The `ws` segment is project config — `orbit config branch.prefix` — deliberately durable, since the same value both names branches here and selects them for deletion in prune (see [The Prefix](#the-prefix-branchprefix))
- Remote branches have no prefix (`push.default=upstream` + config auto-strips it)
- orbit performs no remote writes; push timing is entirely up to the agent

### Raw Mode (Advanced — not recommended for most work)

Raw mode is suitable only when you explicitly want pure git with no orbit branch management. For most work, use scoped mode (`orbit switch -c`) — it wires upstream tracking automatically, avoids the "already used by worktree" trap, isolates branch names across workspaces, and is cleaned up by `orbit prune`.

| Dimension | Raw mode + fetch | Scoped mode |
|---|---|---|
| upstream tracking | plain git: `git push -u origin <name>` (or by hand); the wildcard map resolves `@{u}` from there | wired up front at `switch -c` |
| multi-workspace isolation | no prefix, conflicts | `ws/<workspace>/` prefix, isolated |
| `git checkout main` trap | hits it | avoids it |
| `orbit prune` cleanup | not cleaned, leaks | automatic cleanup |
| branch name | local short, remote same | local long, remote same |

Raw mode workflow:

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

### Converting a Raw-Mode Branch to Scoped Mode

A raw-mode branch (created with `git checkout -b`, no `ws/<workspace>/` prefix) can be converted to scoped mode at any time:

```bash
# Currently on feature/api-refactor (raw mode, any local commits/staged preserved)
orbit switch -c feature/api-refactor
# → Creates ws/<workspace>/feature/api-refactor from current HEAD
# → Wires upstream tracking to origin/feature/api-refactor
# → Working tree and staged changes are fully preserved
git branch -d feature/api-refactor
# → Delete the raw branch (safe — the scoped branch points to the same commit)
```

This is the recommended path when the agent realizes a raw-mode branch should be managed by orbit (e.g. for `orbit prune` cleanup, multi-workspace isolation, or upstream tracking). The conversion is lossless: all local commits and staged changes are preserved, and the old branch can be deleted immediately after the switch.

### Cleanup

Scoped branches are reclaimed by `orbit prune` — the contract (verdicts, guards, pipeline) lives in [spec-lifecycle](./spec-lifecycle.md) → `orbit prune`; the git mechanics (collection scan, ordering, deletion, config convergence) live in [Prune's Git Binding](#prunes-git-binding).

## Push Routing and Remote Targets

### `push.default=upstream`

`orbit clone` sets one push key in `.repos/<repo>` (unless `git.pushUpstreamByDefault` is `never`):

```bash
git -C .repos/<repo> config push.default upstream
```

Effect: all worktrees inherit this configuration; `git push` automatically pushes to the remote branch pointed to by upstream (regardless of differences between local branch name and remote branch name). This allows `ws/<workspace>/<name>` local branches to directly `git push` to `origin/<name>`. It is orbit-maintained state — written at clone and re-asserted at the config-maintenance touchpoints (see [Config Ownership](#config-ownership)); `orbit config git.pushUpstreamByDefault once` (baseline at birth, then yours) or `never` (never written) hands it back to the user — the switch stops future convergence; it does not restore a value already converged.

### Why No `push.autoSetupRemote`

Raw mode gets no push help, by definition — it is plain git with no orbit branch management, so its push experience is the native one: `git push origin <name>` (explicit, needs no upstream config), or `git push -u origin <name>` once to wire tracking for bare pushes. Orbit deliberately does not set `push.autoSetupRemote`: the only thing it would buy is sparing raw mode a one-time `-u`, and per the Config Ownership rule a key orbit depends on must be managed — managing a non-essential key is the worst of both worlds.

### Fork Push Targets

Push target is entirely managed by git remote; orbit does not maintain any additional push metadata. It uses git's native fetch/push URL separation mechanism (`remote.origin.pushurl`):

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

## Tracking Display

The pool is a single-branch clone (`--single-branch` — the initial object pull stays lean), but its fetch config carries the full wildcard map `+refs/heads/*:refs/remotes/origin/*` plus `fetch.prune=true` (see [Config Ownership](#config-ownership)). The map is what `@{upstream}` resolution reads, so any branch with upstream config — scoped or raw — shows real ahead/behind in `git status`, and a push materializes `refs/remotes/origin/<name>` on the spot. There is no registration step and nothing to go stale.

What remains true:

- Upstream **config** is still what points a branch at its remote counterpart: wired by `orbit switch -c`, by `git push -u`, or by hand. A branch with no upstream config has nothing to resolve — that part is plain git, unchanged.
- orbit's own touchpoints fetch only the named branches (default + tracked), so a remote branch nobody tracks materializes on your own `git fetch origin <branch>` — and a bare `git fetch` / `git pull` pulls the whole map (a one-time step onto full-clone footing; `fetch.prune` keeps the refs self-cleaning).

## Prune's Git Binding

[spec-lifecycle](./spec-lifecycle.md) owns prune's framework and semantic constraints — the guards, verdicts, failure and exit semantics, recoverability, residue classes: the workspace invariants. This section consolidates the git mechanics those invariants are currently bound to; a substrate swap rewrites this section, not lifecycle.

**Footprint binding** (the mechanism half of lifecycle's E-table): a workspace's repo views are worktrees — the working dir carries a `.git` pointer file (E3), and the registration is an admin dir under the pool's `.git/worktrees/` (E4); scoped branches are pool refs `refs/heads/<prefix>/<ws>/*` (E5); upstream wiring is `branch.<name>.*` config (E6); objects sit in the shared ODB (E8) — never prune's target. Branch collection scans `refs/heads/<prefix>/<ws>/*` pool-side — independent of whether any worktree directory still exists, because the current branch alone would leak the base branch the agent switched away from.

**Ordering.** D1-before-D2 is git's semantics, not convention: git refuses to delete a branch checked out in a worktree, so deregistration (`git worktree remove`) must precede branch deletion. A stale registration pointing at a vanished path makes every later deletion of that branch refuse (`used by worktree at <gone path>`) — which is why directory removal runs only when git has no stake in the outcome.

**Branch deletion.** `git branch -d`/`-D` drops the branch's `branch.<name>.*` config with it (E6 goes with E5); leftover `branch.*` sections whose branch is already gone are converged away in the same pass (D3). `-d`'s "not fully merged" check measures against the *local* default checkout, which lags `origin/<default>` after a fetch — so a branch already proven upstream by the verdict layers is retried once with `-D`. A git refusal forwards git's first line only: its `hint:` continuations name `git branch -D`, the bypass instruction a refusal must not hand out.

**Verdict commands.** The three verdict layers (lifecycle → Branch Verdicts) bind to: `merge-base --is-ancestor` (history containment), `git merge-tree --write-tree` (content equality; git ≥ 2.38, else fall through to keep), and `git cherry` as a report hint only — patch-id equivalence proves nothing about the final tree.

**Registry self-heal.** `git worktree list --porcelain` reports a registration whose gitdir target is gone as `prunable`. Path gone → stale registration, repaired automatically; path present → damaged worktree, refused and left intact as the only evidence of that state. What a stale-registration removal touches, stated precisely because "just metadata" does real work in that sentence: the admin directory (`gitdir`, `commondir`, `HEAD`, `ORIG_HEAD`, `index`, `logs/HEAD`, per-worktree `refs/`) and nothing else — no object is deleted, no file with content, no ref under `refs/heads` or `refs/remotes`, nothing inside any workspace, no registration whose path still exists. One thing does narrow: `logs/HEAD` is that worktree's HEAD reflog, and for a worktree whose directory is already gone it is the last *named* handle on any detached-HEAD commit made there — objects stay in the shared store until gc, so recovery degrades from `git reflog` to `git fsck --lost-found`, exactly what git's own `git worktree prune` does in this state, and consistent with detached HEAD being out of scope.

**Objects are never the target.** Prune deletes refs, never objects; reclamation belongs to gc (see [Git Dependency Closure](#git-dependency-closure), feature 6).

## Git Dependency Closure

Orbit's dependencies on git form a **closed set**, enumerated here completely, in three categories: **invocations** (commands orbit runs), **features** (git behaviors orbit's correctness leans on), and **config keys** (settings orbit depends on). The fetch-refspec rework exists because the old per-branch machinery had three layers each fixing the previous layer's side effects — the signature of a wrongly chosen primitive. This section pins down what remains, so the surface can be audited at a glance instead of reconstructed after the next incident.

### Invocations

- **Read-only:** `rev-parse`, `rev-list --count`, `for-each-ref`, `status`, `symbolic-ref`, `merge-base --is-ancestor`, `merge-tree --write-tree` (git ≥ 2.38, with the `cherry` fallback for older), `ls-remote` (`--exit-code` / `--symref` / `--heads`), `remote get-url`, `branch --show-current`, `check-ref-format`, `worktree list --porcelain`, `config --get`, `--version`. Git's output wording is parsed only under `LC_ALL=C`.
- **State-changing:** `clone --single-branch` (the initial object pull stays lean), `fetch` (explicit refspecs only — the colon form, or a named ref to `FETCH_HEAD` for `orbit add` — never bare), `remote prune origin` (only when the wildcard shape is in place), `remote set-head --auto`, `symbolic-ref` (writes `refs/remotes/origin/HEAD` under `sync --branch`; reads are listed above), `remote set-url --push`, `worktree add` (including `--orphan`, git ≥ 2.42, empty-repo bootstrap only) / `worktree remove [--force]`, `checkout`, `merge --ff-only` (sync), `reset --hard` (`--force` escape hatch), `branch -d/-D` (prune), and `config` writes for the managed keys below — plus `git config --file` reused as orbit's own config engine.
- **Never invoked:** `push`, `pull`, `commit`, `rebase`, `stash`, `tag`, `gc`, `init` — those remain the agent's and user's domain. (Sync fetches and fast-forwards; it never pulls.)

### Features

1. **Worktree machinery semantics.** The "already used by worktree" refusal (scoped-mode naming leans on it as a guard; the skill teaches it as the fallback cue) and `worktree remove` refusing to delete a checked-out branch (prune's remove-before-branch-delete ordering rests on it).
2. **Wildcard refspec + `fetch.prune` semantics.** Named branches materialize via explicit colon fetches without disturbing the rest of the map; a push materializes `refs/remotes/origin/<name>` on the spot; `fetch.prune` only prunes refs covered by the fetch refspecs — which is what makes the shape-gated `git remote prune origin` safe on user-narrowed layouts.
3. **`branch.<name>.*` lifecycle.** Deleting a branch drops its `branch.<name>.*` config along with it (prune's cleanup counts on this).
4. **Clone-time config shapes.** `--single-branch` writes a narrowed fetch refspec (which orbit then replaces — ordering matters), and an empty-remote clone carries *no* `remote.origin.fetch` entries at all (which is why the baseline is written with `git config --replace-all`, not `git remote set-branches`).
5. **`origin/HEAD` as default-branch perception.** Local symbolic-ref fast path, `ls-remote --symref` fallback persisted via `git remote set-head --auto`, re-pointed by `sync --branch`.
6. **Object-retention recoverability premise.** Prune deletes refs, never objects; deletion lines carry `(was <sha>)` because that SHA is the recovery handle — `git branch <name> <sha>` recreates the ref while the objects survive gc (`gc.pruneExpire`, two weeks by default). Note what deletion takes with it: a branch's own reflog dies with the branch, and a worktree's `logs/HEAD` dies with the worktree (verified behavior), so post-prune the 90-day reflog window does not apply — reflogs are the *pre-deletion* safety net for in-flight mistakes, which is native-git territory. Orbit neither reads nor enforces `core.logAllRefUpdates` / `gc.*`: a user who disables reflogs globally has made that call for every repo they own, and overriding it pool-locally would be a silent config rewrite — forbidden — for near-zero protective value. See [spec-lifecycle](./spec-lifecycle.md) → Recoverability.
7. **`check-ref-format` as the naming authority.** Workspace and branch names are validated against git's own ref rules; orbit invents no naming rules of its own.
8. **Version gates.** Hard floor git 2.20; soft gates 2.38 (`merge-tree --write-tree`, `cherry` fallback) and 2.42 (`worktree add --orphan`, hard error on the empty-repo path only). `GIT_TERMINAL_PROMPT=0` accompanies remote operations so auth prompts fail fast instead of hanging.

### Config Keys

The managed set and its rule live in [Config Ownership](#config-ownership) — converged keys with their three-mode escape hatches, lifecycle-managed `branch.*` wiring, and the premise-only list. Nothing in that table is additive with this closure: the table *is* the config slice of the set.

**The rule: the closure only shrinks.** This is the Design Priorities made operational — priorities 1 (minimal surprise) and 2 (simple mechanism) mean every new dependency is a potential agent-surprise source and a mechanism-complexity debt. A change that needs a git invocation, feature, or config key outside this list must say so in the PR, pass the razor review (what breaks if we don't take it? is there an orbit-level way instead?), and extend this section in the same commit — an explicit set extension, not an accident discovered later. And per the ownership rule: if the new dependency is a config key, it joins the managed set in the same change.

## Visibility vs Hiding Balance

Users can see, correct, and delete (triggering rebuild), but can also completely ignore:
- Workspace directory structure → visible, defines the agent's context boundary
- Repo subdirectories → visible, humans need to open editors and run tests
- `.orbit` metadata → hidden file, not seeing it doesn't affect work, but can be manually corrected
- Branch names → decided by the agent, visible to humans on PR pages
- Worktree internal connection details → implementation detail, completely unexposed
