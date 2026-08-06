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

### Changes by Kind

#### Security

- `orbit prune`: root-only, target-independent initiation guard via process ancestry, uncommitted-changes skip, bypass-free refusals — guards in [`docs/spec-lifecycle.md`](docs/spec-lifecycle.md) → Prune Safety Guards.
- `prune` now reclaims **residue**: ghost-workspace scoped branches (grouped by the reclaimed workspace, same merged/unmerged protection; `orbit prune <ws> --force` force-deletes a ghost's branches) and untraceable raw branches (reported with status + shell-quoted native delete commands, never auto-deleted). Kept branches end in a closing suggestion block. Git's own `Deleted branch …` chatter no longer leaks into the report — the deletion lines carry the commit instead (`(was <sha>)`), which is the reflog handle and the only recovery path — [`docs/spec-lifecycle.md`](docs/spec-lifecycle.md) → Residue Cleanup and Maintenance Self-Heal.
- Prune's guard set is now stated over **arbitrary prior state**, not just interrupted runs: every file in a workspace — including the `.orbit` marker and the gitdir pointers the guards read — is agent-writable, so each reachable state must be self-healing, self-evident and repairable, or explicitly out of scope. New in that sweep: a **damaged worktree** (registered by the pool, gitdir pointer deleted or corrupted) is detected and the workspace skipped, instead of reading as ordinary content and being destroyed with the directory unannounced — `--force` still clears it, after saying that what it removes cannot be read and cannot be recovered; a failed `rm -rf` keeps the workspace and never prints `pruned:`; stale worktree registrations and orphan `branch.*` config are repaired automatically; `--force` announces that discarding un-persisted work cannot be undone. What prune deliberately does **not** protect is listed too (ignored files, non-repo content, stashes, detached HEAD, concurrency, direct writes into `.repos/`).
- Refusals replay the intended command (`cd <root> && orbit <cmd> <args>`, your argv verbatim) only when the ancestry walk ran and came back clean; a blind walk (no `/proc`, no `lsof`, no usable `ps`) states the fact alone — a guard that cannot see must not hand out a ready-to-run destructive command. Workspace detection needs no `.orbit` marker either: metadata is disposable, and a guard a lost file can disable is no guard.
- Prune also skips top-level non-pool git repos (a `.git` directory is an independent clone, whatever its name) and unmerged jots (`--force` overrides, `--dry-run` reports).
- `sync --force`/`--branch` root-only; `--branch` keeps unrelated fetch refspecs and rolls back on failure — [`docs/spec-commands.md`](docs/spec-commands.md) → sync.
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

#### Bug or Regression

- Fetch refspecs reconciled with remote — bare `git fetch` heals after a branch is deleted upstream. ([#21](https://github.com/orbcli/orbit/pull/21))
- `orbit switch <remote-branch>` always fetches first — no stale checkouts. ([#22](https://github.com/orbcli/orbit/pull/22))
- Workspace-name validation actually rejects ref-illegal names (space, `~ ^ : ? * [ \`) — the bracket expression had a stray `]` that let every such name through (e.g. `orbit new --name 'dev*'`).
- Brief parser, status steering and refspec lifecycle hardened. ([#23](https://github.com/orbcli/orbit/pull/23))
- Plugin install works on SSH-less machines — `try.sh` defaults to HTTPS. ([#24](https://github.com/orbcli/orbit/pull/24))
- OpenCode auto-approve matches `--force` token-exactly. ([#25](https://github.com/orbcli/orbit/pull/25))
- Jot queue stores entries in `[jot "<repo>"]` subsections — names plain git-config keys can't hold (`my_repo`, `2048`) now jot and pop correctly.
- `orbit clone` rejects a URL whose basename violates the pool-name contract (e.g. `.github`), pointing at `--name`.
- Workspace/repo inference compares physical paths — commands work through symlinked cwds.
- Session guard warns when process ancestry is unreadable, instead of failing silently open.

#### Removal

- `[seed]` jot sentinel and the gap model — memo state computed inline. ([#17](https://github.com/orbcli/orbit/pull/17))
- Stop hooks and `[nudge]`/`[overlong]` markers — covered by stderr + cruise block + done gate. ([#17](https://github.com/orbcli/orbit/pull/17))

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
