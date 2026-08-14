# Changelog

All notable changes to this project will be documented in this file.

Entries follow the CNCF convention — Urgent Upgrade Notes first, then Changes by Kind — and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

Hardens the destructive surface: `prune` and `sync --force`/`--branch` become machine-enforced root-level operations. Also ships the context-system redesign and retires stop hooks.

### Urgent Upgrade Notes

- **BREAKING:** `ORBIT_BRANCH_PREFIX` no longer read — use `orbit config branch.prefix` before creating/pruning branches.
- **BREAKING:** `prune --force` now overrides the data guards too, not just branch protection.
- **BREAKING:** `prune` and `sync --force`/`--branch` run from the project root only — enforced on the **process tree**, not just the cwd: the whole invocation is refused when any ancestor process stands inside a workspace, whichever workspace is targeted. "Inside a workspace" is structural (any non-reserved directory directly under the root, `.repos` and dotdirs excluded), so a plain junk directory at the root is refused too. No flag releases it (`--force`, `--dry-run` included); run from a shell started outside every workspace.
- **BREAKING:** `prune` left the skill's action surface — agents report the need, humans run it.
- **BREAKING:** `prune --verify` removed. PR evidence is now used automatically whenever the workspace recorded `pr.url` entries and `gh` is available — no flag, and no `gh` call at all when nothing was recorded. The old flag gated a per-workspace "all PRs merged" check that force-deleted every branch in the workspace; verdicts are now per-branch, and a merged PR only clears the branch it covers — [`docs/spec-lifecycle.md`](docs/spec-lifecycle.md) → Prune Safety Guards → Branch Verdicts.
- Prune's messages changed — stderr diagnostics and the stdout report shape alike (worktree counts, residue groups, closing block) — contract in [`docs/spec-warnings.md`](docs/spec-warnings.md) → Refusals and skips.
- **BREAKING:** pool fetch config is now orbit-maintained state. Pools converge to the full wildcard map `+refs/heads/*:refs/remotes/origin/*` plus `fetch.prune=true` — written at clone, re-asserted at every `sync`/`info`/session-start/`prune` touchpoint, **removing any other `remote.origin.fetch` mapping** (per-branch entries from older orbit versions, hand edits, emptied configs all converge; each convergence is reported on stderr as it happens). To keep a custom refspec layout, set `orbit config git.fetchAllBranches once` (write the baseline at birth, never correct it) or `never` (fully self-managed); `git.fetchPrune` takes the same three modes. Visible consequences: `@{u}` / `git status` upstream lines work for every branch with upstream config — scoped or raw, no registration step — and a push materializes the tracking ref on the spot; tracking refs self-clean as branches are deleted upstream (the cleaning runs at the fetching touchpoints — since narrowed to `sync` / `prune`); and a bare `git fetch` or `git pull` in any worktree now pulls every branch's objects (a one-time step onto full-clone footing on huge repos — orbit's own commands still fetch named branches only, so agent/headless paths never trigger it).
- **BREAKING:** the `removed stale fetch refspec` / `added fetch refspec` / `would remove` / `would add` output lines are gone, and prune's `pool maintenance:` section no longer carries refspec content — the per-branch registration/reconciliation machinery was deleted outright. In their place, config convergence reports fixed per-key steering lines (`orbit: <repo>: fetch config converged: …` / `orbit: <repo>: push routing converged: …`) — contract in [`docs/spec-warnings.md`](docs/spec-warnings.md) → Config convergence lines.
- **BREAKING:** `push.default=upstream` joins the maintained set — re-asserted at the same touchpoints (scoped local names differ from remote names, so git's default `simple` would refuse a bare `git push`); escape with `orbit config git.pushUpstreamByDefault once` or `never`. And `push.autoSetupRemote` is gone: its only beneficiary was raw-mode bare push, and raw mode's contract is plain git — a fresh raw branch now gets git's native "no upstream" error naming `git push -u`, while the documented explicit `git push origin <branch>` needs no config at all. Scoped mode is unaffected (its upstream is wired by `switch` up front), and the git ≥ 2.37 soft gate drops with the key.
- The prune recovery narrative is stated precisely everywhere (spec-lifecycle Recoverability, USAGE, spec-warnings): recovery is the report's `(was <sha>)` plus object survival until gc (`gc.pruneExpire`, two weeks by default) — a deleted branch's own reflog is deleted with it, so the 90-day reflog window never applied post-prune. `core.logAllRefUpdates` / `gc.*` are declared premise-only in the dependency closure — user policy orbit deliberately does not manage.

### Changes by Kind

#### Security

- `orbit prune`: root-only, target-independent initiation guard via process ancestry, uncommitted-changes skip, bypass-free refusals — guards in [`docs/spec-lifecycle.md`](docs/spec-lifecycle.md) → Prune Safety Guards.
- `prune` now reclaims **residue**: ghost-workspace scoped branches (grouped by the reclaimed workspace, same merged/unmerged protection; `orbit prune <ws> --force` force-deletes a ghost's branches) and untraceable raw branches (reported with status + shell-quoted native delete commands, never auto-deleted). Kept branches end in a closing suggestion block. Git's own `Deleted branch …` chatter no longer leaks into the report — the deletion lines carry the commit instead (`(was <sha>)`), the recovery handle: good while the objects survive gc — [`docs/spec-lifecycle.md`](docs/spec-lifecycle.md) → Residue Cleanup and Maintenance Self-Heal.
- Prune's guard set is now stated over **arbitrary prior state**, not just interrupted runs: every file in a workspace — including the `.orbit` marker and the gitdir pointers the guards read — is agent-writable, so each reachable state must be self-healing, self-evident and repairable, or explicitly out of scope. New in that sweep: a **damaged worktree** (registered by the pool, gitdir pointer deleted or corrupted) is detected and the workspace skipped, instead of reading as ordinary content and being destroyed with the directory unannounced — `--force` still clears it, after saying that what it removes cannot be read and cannot be recovered; a failed `rm -rf` keeps the workspace and never prints `pruned:`; stale worktree registrations and orphan `branch.*` config are repaired automatically; `--force` announces that discarding un-persisted work cannot be undone. What prune deliberately does **not** protect is listed too (ignored files, non-repo content, stashes, detached HEAD, concurrency, direct writes into `.repos/`).
- Refusals replay the intended command (`cd <root> && orbit <cmd> <args>`, your argv verbatim) only when the ancestry walk ran and came back clean; a blind walk (no `/proc`, no `lsof`, no usable `ps`) states the fact alone — a guard that cannot see must not hand out a ready-to-run destructive command. Workspace detection needs no `.orbit` marker either: metadata is disposable, and a guard a lost file can disable is no guard.
- Prune also skips top-level non-pool git repos (a `.git` directory is an independent clone, whatever its name) and unmerged jots (`--force` overrides, `--dry-run` reports).
- `sync --force`/`--branch` root-only; `--branch` writes no fetch config (the wildcard map covers any new default branch) and moves `origin/HEAD` — [`docs/spec-commands.md`](docs/spec-commands.md) → sync.
- Repo names validated as pool basenames in `sync`/`add`/`info`/`memo`/`clone --name` (path-traversal fix). Charset aligned with GitHub (`[A-Za-z0-9._-]`); leading `.`/`-` rejected — contract in [`docs/spec-commands.md`](docs/spec-commands.md) → Repo Name Contract.
- Branch prefix moved from env var to `orbit config branch.prefix`; validated, immovable while branches carry it.
- `orbit config` refuses `repos.*` writes.
- Auto-approve hooks strip quotes/backslashes per token — `'--force'`/`\-\-force` no longer bypass; `sync --branch` prompts too. (Extends [#25](https://github.com/orbcli/orbit/pull/25).)

#### Feature

- `install.sh --replace-marketplace` — switch plugin marketplace source. ([#16](https://github.com/orbcli/orbit/pull/16))
- `orbit context` redesigned: `--startup` = session-start block, bare = cruise block; key `status` → `state`. ([#17](https://github.com/orbcli/orbit/pull/17))
- Session hooks are thin wrappers; new `session-resume.sh` injects the cruise block. ([#17](https://github.com/orbcli/orbit/pull/17), [#19](https://github.com/orbcli/orbit/pull/19))
- Scoped branch mode is now the default; raw→scoped conversion via `orbit switch -c <same-name>`. ([#18](https://github.com/orbcli/orbit/pull/18))
- Human-facing output rework: header-first, repo-grouped prune reports. ([#20](https://github.com/orbcli/orbit/pull/20))
- `orbit done` per-repo one-line warnings (jots / thin memo / over-budget card). ([#17](https://github.com/orbcli/orbit/pull/17))
- `jot.bufferSize` config replaces the hardcoded aggregation threshold. ([#17](https://github.com/orbcli/orbit/pull/17), [#20](https://github.com/orbcli/orbit/pull/20))
- One-shot explore/curate stderr on `add` (thin memo) and `memo` (over-budget). ([#17](https://github.com/orbcli/orbit/pull/17))
- `docs/spec-branching.md` is restructured and renamed to **`docs/spec-worktree.md`** — the worktree model doc: the root decision (one pool, many worktrees, argued from the principles), the design priorities, actors/invocation layers, config ownership, and the touchpoint fetch discipline (moved out of spec-lifecycle, where they never belonged) join the branching strategy, push routing, and tracking display. It also gains **Git Dependency Closure**: orbit's complete git dependency surface enumerated as a closed set in three categories — invocations, feature/behavior premises, config keys — with the rule that the set only shrinks (any new dependency requires an explicit set extension in the same PR) and that a config key orbit depends on is managed state (converged or lifecycle-managed — or explicitly declared premise-only).

#### Bug or Regression

- Bare `git fetch` can no longer be broken by orbit's own state: a tracked branch deleted upstream no longer produces `couldn't find remote ref` anywhere — orbit's touchpoints fetch named branches only (git's fatal is swallowed) and converge the dead ref with one native `git remote prune origin`. The earlier per-branch refspec registry that caused the class is gone entirely. ([#21](https://github.com/orbcli/orbit/pull/21))
- `orbit switch <remote-branch>` always fetches first — no stale checkouts. ([#22](https://github.com/orbcli/orbit/pull/22))
- Workspace-name validation actually rejects ref-illegal names (space, `~ ^ : ? * [ \`) — the bracket expression had a stray `]` that let every such name through (e.g. `orbit new --name 'dev*'`).
- Brief parser and status steering hardened. ([#23](https://github.com/orbcli/orbit/pull/23))
- Plugin install works on SSH-less machines — `try.sh` defaults to HTTPS. ([#24](https://github.com/orbcli/orbit/pull/24))
- OpenCode auto-approve matches `--force` token-exactly. ([#25](https://github.com/orbcli/orbit/pull/25))
- Auto-approve tier contract restated by where the judgment lives: framework-verified subcommands (read-only / destructive read / idempotent workspace-write) stay bundled; `done`/`new` are **framework-neutral** — workflow timing is the user's call, so they are neither bundled nor marked must-confirm (users who want them prompt-less allowlist them in their own agent settings; snippets in `skills/CONSTRAINTS.md`); `prune`/`clone`/`config` and `sync --force`/`--branch` keep prompting. No hook behavior change — the tier table, USAGE §17, spec-hooks and SKILL now match what the hooks already did, replacing the stale "done/new are destructive, human-initiated" classification.
- Bare `orbit goal` doc promises converged to reality: it is a write path (editor on a TTY, stdin set otherwise) and never had a read path — the read is `orbit context goal`. USAGE, SKILL (workflow + examples) and CONSTRAINTS no longer promise the bare read. The execution-location matrix in spec-commands also gained the missing `orbit config` row (runs anywhere in the project).
- Jot queue stores entries in `[jot "<repo>"]` subsections — names plain git-config keys can't hold (`my_repo`, `2048`) now jot and pop correctly.
- `orbit clone` rejects a URL whose basename violates the pool-name contract (e.g. `.github`), pointing at `--name`.
- Workspace/repo inference compares physical paths — commands work through symlinked cwds.
- Session guard warns when process ancestry is unreadable, instead of failing silently open.
- `orbit info` and the `orbit context --startup` reignite block no longer fetch — read paths are purely local again (zero network): #29's touchpoint fetch made every `info` and every session start with worktrees pay N serial remote round-trips (the default branch plus each tracked branch, one fetch each), multiplying with pool residue. Ruling: without an async daemon, auto-fetch on a main path taxes a synchronous caller for advisory freshness, and low friction outranks it — auto-fetch may return only off the main path. Layer-1 staleness (`remoteAhead`) now reads last-fetched refs, refreshed by the remaining fetching touchpoints (`orbit sync` / `orbit prune`) or the user's own fetch/pull; fetch-config maintenance (a local write) stays.
- Bare `orbit prune` no longer reaps an empty repo's default-branch config: pool maintenance's orphan-config sweep treats the pool HEAD's target branch as always alive (possibly unborn) — its `branch.<name>.*` section is first-push routing, not residue. The protection tracks HEAD and self-releases once the branch gains a ref or the pool switches defaults; non-empty repos are unchanged (the ref check already keeps such sections). ([#36](https://github.com/orbcli/orbit/pull/36))
- Session-injection hooks anchor their working directory to the host-injected project dir before workspace detection: hook CWD is not a cross-host contract, so a host running hooks from outside the project silently disabled `<orbit-context>` injection for the entire session ("not in a workspace" is a designed silent no-op, so nothing ever surfaced). The shared `session-start.sh` / `session-resume.sh` now `cd` to `CLAUDE_PROJECT_DIR` (Claude Code's documented contract, also injected by Qoder) with `QODER_PROJECT_DIR` as fallback — guarded so empty/unset/invalid values and env-less hosts (codex sets hook CWD correctly by contract) pass through unchanged — and the OpenCode plugin anchors its shell to the SDK's `PluginInput.directory` instead of inheriting the opencode process cwd. ([#37](https://github.com/orbcli/orbit/pull/37))

#### Removal

- `[seed]` jot sentinel and the gap model — memo state computed inline. ([#17](https://github.com/orbcli/orbit/pull/17))
- Stop hooks and `[nudge]`/`[overlong]` markers — covered by stderr + cruise block + done gate. ([#17](https://github.com/orbcli/orbit/pull/17))
- Fetch-refspec reconciliation (register/remove directions, gating, default-branch exemption) — the wildcard map + `fetch.prune` are maintained instead, and tracked refs converge through native `git remote prune origin`; `orbit switch -c` no longer registers anything.
- `push.autoSetupRemote` clone/switch writes and the `orbit doctor` git ≥ 2.37 check — see the breaking note above; `orbit switch` no longer writes any push config (touchpoint convergence owns it).

## [0.1.0] - 2026-07-06

### Added

- Core commands: `clone`, `repos`, `info`, `memo`, `sync`
- Workspace lifecycle: `new`, `add`, `switch`, `done`, `prune`
- Workspace reactivation: setting a goal on a done workspace clears its completion record and PR history; `orbit add` on a done workspace warns it is prune-eligible
- Status and context: `status`, `goal`, `context`
- Configuration and diagnostics: `config`, `doctor`, `completion`, `version`
- Knowledge system: `memo` (read/write), `jot` (quick notes)
- Claude Code and Qoder skill definitions
- `install.sh` with `--claude` / `--qoder` (alias `--qodercli`) / `--zsh` / `--bash` support
- bats test suite (177 tests across 20 files)
