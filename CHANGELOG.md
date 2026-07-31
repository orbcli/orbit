# Changelog

All notable changes to this project will be documented in this file.

Entries follow the CNCF convention — Urgent Upgrade Notes first, then Changes by Kind — and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

Hardens the destructive surface: `prune` and `sync --force`/`--branch` become machine-enforced root-level operations. Also ships the context-system redesign and retires stop hooks.

### Urgent Upgrade Notes

- **BREAKING:** `ORBIT_BRANCH_PREFIX` no longer read — use `orbit config branch.prefix` before creating/pruning branches.
- **BREAKING:** `prune --force` now overrides the data guards too, not just branch protection.
- **BREAKING:** `prune` and `sync --force`/`--branch` run from the project root only.
- **BREAKING:** `prune` left the skill's action surface — agents report the need, humans run it.
- Prune's stderr messages changed — contract in [`docs/spec-warnings.md`](docs/spec-warnings.md) → Refusals and skips.

### Changes by Kind

#### Security

- `orbit prune`: root-only, active-session detection via process ancestry, uncommitted-changes skip, bypass-free refusals — guards in [`docs/spec-lifecycle.md`](docs/spec-lifecycle.md) → Prune Safety Guards.
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
- Prune's unmerged-branch skip now recognizes squash/rebase merges (content equivalence via `git merge-tree`, `git cherry` fallback) and prints the exact `git branch -D` cleanup command for the human operator.
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
