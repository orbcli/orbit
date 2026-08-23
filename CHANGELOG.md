# Changelog

All notable changes to this project will be documented in this file.

Entries follow the CNCF convention — Urgent Upgrade Notes first, then Changes by Kind — and this project adheres to [Semantic Versioning](https://semver.org/).

## Unreleased

## 0.2.0 - 2026-08-23

Locks down the destructive surface, redesigns the context system, and makes every install refresh to latest — a dogfooding-driven hardening cycle across 26 PRs (#16–#42).

### Urgent Upgrade Notes

- **BREAKING:** `prune` and `sync --force`/`--branch` run from the project root only, enforced via process ancestry (no flag, including `--force`, bypasses it; guards contract in [`docs/spec-lifecycle.md`](docs/spec-lifecycle.md) → Prune Safety Guards). `prune` also left the agent skill's action surface — agents report the need, humans run it. ([#26](https://github.com/orbcli/orbit/pull/26), [#27](https://github.com/orbcli/orbit/pull/27))
- **BREAKING:** `prune --force` now overrides the data guards too, not just branch protection (uncommitted changes, unmerged jots, damaged worktrees) — it announces what it discards before doing it. ([#27](https://github.com/orbcli/orbit/pull/27))
- **BREAKING:** `prune --verify` removed — merged-PR evidence is now applied automatically from the workspace's recorded `pr.url` entries whenever `gh` is available (no external call at all when nothing was recorded); drop the flag from scripts. ([#27](https://github.com/orbcli/orbit/pull/27))
- **BREAKING:** `ORBIT_BRANCH_PREFIX` is no longer read — use `orbit config branch.prefix` (validated, immovable while branches carry it). ([#26](https://github.com/orbcli/orbit/pull/26))
- **BREAKING:** `install.sh` now refreshes on every run — "install is latest": the marketplace snapshot is updated, and the plugin and the orbit runtime itself are reinstalled from it. `--force` is a full plugin+marketplace reset that first probes source reachability — an offline reset degrades to a plain refresh instead of destroying the last working install. ([#39](https://github.com/orbcli/orbit/pull/39), [#40](https://github.com/orbcli/orbit/pull/40))
- **BREAKING:** OpenCode plugin/skill removal is directory-level (`--force`/`--uninstall` wipe `~/.config/opencode/skills/orbit/` entirely) — anything you placed inside is deleted. ([#39](https://github.com/orbcli/orbit/pull/39))
- **BREAKING:** pool fetch config is now Orbit-maintained: a wildcard refspec plus `fetch.prune`, converged at the fetch touchpoints (orbit's own fetching commands — `sync` / `prune`); opt out per key via `orbit config git.fetchAllBranches` / `git.fetchPrune`. Side effect: a bare `git fetch`/`git pull` in any worktree now fetches every branch. ([#29](https://github.com/orbcli/orbit/pull/29))
- **BREAKING:** `push.default=upstream` joins the maintained config set, so scoped branches push with a bare `git push`; `sync --branch` additionally moves `origin/HEAD`. ([#29](https://github.com/orbcli/orbit/pull/29))
- **BREAKING:** output contracts changed. The `removed stale fetch refspec` / `added fetch refspec` / `would remove fetch refspec` / `would add fetch refspec` lines are gone with the per-branch registration machinery, and prune's `pool maintenance:` section no longer carries refspec content — config convergence reports fixed per-key steering lines instead (`orbit: <repo>: fetch config converged: …` / `push routing converged: …`). Prune's stderr diagnostics and stdout report shape (worktree counts, residue groups, closing block) changed too. Update anything that greps orbit's output — contracts in [`docs/spec-warnings.md`](docs/spec-warnings.md) and [`docs/spec-lifecycle.md`](docs/spec-lifecycle.md).
- `push.autoSetupRemote` is no longer written — a raw-mode bare `git push` now gets git's native "no upstream" hint instead of an auto-created upstream ([`docs/spec-worktree.md`](docs/spec-worktree.md) → Push Routing).

### Changes by Kind

#### Security

- `prune` was rebuilt around all-or-nothing validation, a fixed pipeline with a `.prune-trash` recovery window, and per-branch verdicts. ([#27](https://github.com/orbcli/orbit/pull/27))
- `prune` also reclaims residue — ghost-workspace branches and untraceable raw branches, reported with recovery handles, never auto-deleted. ([#27](https://github.com/orbcli/orbit/pull/27))
- `prune` self-heals arbitrary prior damage: damaged worktrees detected and skipped, stale registrations repaired, failed deletions never reported as success. ([#27](https://github.com/orbcli/orbit/pull/27))
- Repo names validated as pool basenames in `sync`/`add`/`info`/`memo`/`clone --name` (path-traversal fix; charset aligned with GitHub).
- Auto-approve hooks strip quotes/backslashes per token — `'--force'`/`\--force` no longer bypass the check; `sync --branch` prompts too. (Extends [#25](https://github.com/orbcli/orbit/pull/25).)

#### Feature

- `orbit context` redesigned: `--startup` = session-start block, bare = cruise block; key `status` → `state`. ([#17](https://github.com/orbcli/orbit/pull/17))
- Session hooks are thin wrappers; new `session-resume.sh` injects the cruise block. ([#17](https://github.com/orbcli/orbit/pull/17), [#19](https://github.com/orbcli/orbit/pull/19))
- Scoped branch mode is now the default; raw→scoped conversion via `orbit switch -c <same-name>`. ([#18](https://github.com/orbcli/orbit/pull/18))
- Human-facing output rework: header-first, repo-grouped prune reports. ([#20](https://github.com/orbcli/orbit/pull/20))
- `orbit done` per-repo one-line warnings (jots / thin memo / over-budget card); `jot.bufferSize` config replaces the hardcoded threshold; one-shot explore/curate stderr on `add`/`memo`. ([#17](https://github.com/orbcli/orbit/pull/17), [#20](https://github.com/orbcli/orbit/pull/20))
- `docs/spec-branching.md` restructured into **`docs/spec-worktree.md`**, gaining the Git Dependency Closure — Orbit's git dependency surface as a closed, shrink-only set. ([#29](https://github.com/orbcli/orbit/pull/29))
- `install.sh` gains a network-resilience layer: every network operation retries on transient failures and never fails silently; the plugin source resolves through a chain (`ORBIT_SOURCES` / `ORBIT_SOURCE`) that rotates per attempt. ([#31](https://github.com/orbcli/orbit/pull/31))

#### Bug or Regression

- Bare `git fetch` can no longer break on a branch deleted upstream: touchpoints fetch named branches only and converge dead refs via native `git remote prune origin`; the per-branch refspec registry is gone. ([#21](https://github.com/orbcli/orbit/pull/21))
- `orbit switch <remote-branch>` always fetches first — no stale checkouts. ([#22](https://github.com/orbcli/orbit/pull/22))
- Read paths are purely local again (zero network): `orbit info` and the session-start block no longer fetch — #29's touchpoint fetch made every `info` and every session start pay N serial remote round-trips. Staleness (`remoteAhead`) now reads last-fetched refs; the fetching touchpoints are `sync`/`prune`. ([#35](https://github.com/orbcli/orbit/pull/35))
- Prune's orphan-config sweep no longer reaps an empty repo's default-branch config, and guards branches checked out in live worktrees (the pool's own checkout exempt). ([#33](https://github.com/orbcli/orbit/pull/33), [#36](https://github.com/orbcli/orbit/pull/36))
- Workspace-name validation actually rejects ref-illegal names (a stray `]` in the bracket expression let them all through); brief parser and status steering hardened. ([#23](https://github.com/orbcli/orbit/pull/23))
- Bare `orbit goal` docs converged to reality: it is a write path (editor on TTY, stdin otherwise); the read is `orbit context goal`. ([#34](https://github.com/orbcli/orbit/pull/34))
- Jot queue stores entries in `[jot "<repo>"]` subsections — names plain git-config keys can't hold (`my_repo`, `2048`) now jot and pop correctly.
- `orbit clone` rejects a URL whose basename violates the pool-name contract (e.g. `.github`), pointing at `--name`.
- Workspace/repo inference compares physical paths — commands work through symlinked cwds.
- Session guard warns when process ancestry is unreadable, instead of failing silently open.
- Plugin install works on SSH-less machines — `try.sh` defaults to HTTPS. ([#24](https://github.com/orbcli/orbit/pull/24))
- Plugin installs previously kept shipping stale content: every agent CLI exits 0 when re-adding an existing marketplace without refreshing its snapshot, and the old path stopped at the add. Install now always updates after the add, and the plugin reinstall copies from the refreshed snapshot. ([#39](https://github.com/orbcli/orbit/pull/39))
- Session-injection hooks anchor to the host-injected project dir before workspace detection — a host running hooks from outside the project silently disabled `<orbit-context>` injection for the entire session. ([#37](https://github.com/orbcli/orbit/pull/37))
- Qoder IDE sessions receive the injected workspace context again: the IDE parses hook stdout strictly as JSON, so qoder SessionStart hooks now re-encode the shared scripts' output via `hooks/qoder/` wrappers. ([#40](https://github.com/orbcli/orbit/pull/40))
- `try.sh` demo no longer dies at its first commit on machines without a global git identity (fresh VMs, containers): the demo pool clones carry a repo-local `Pilot <pilot@localhost>` identity. ([#42](https://github.com/orbcli/orbit/pull/42))
- OpenCode auto-approve matches `--force` token-for-token. ([#25](https://github.com/orbcli/orbit/pull/25))
- Auto-approve tier contract restated by where the judgment lives: framework-verified subcommands stay bundled; `done`/`new` are framework-neutral; `prune`/`clone`/`config` and `sync --force`/`--branch` keep prompting. No hook behavior change — docs now match the hooks. ([#34](https://github.com/orbcli/orbit/pull/34))
- Cruise-block hint gating fixed: the resume hint now keys on an enumeration-recall test instead of content-in-context. ([#32](https://github.com/orbcli/orbit/pull/32))
- 65 silently vacuous bats assertions fixed (stock macOS bash 3.2 `set -e` bypasses failing `[[ ]]`) — converted to grep-based helpers, with a lint guard keeping the suite honest. ([#38](https://github.com/orbcli/orbit/pull/38))

#### Documentation

- USAGE gains a "Config-management tools" section: snapshot-restore tools (provider switchers, dotfile syncers) silently roll back plugin registration; recovery = re-run the installer, prevention = keep Orbit's registration entries in the tool's stored config, with per-host snippets. ([#41](https://github.com/orbcli/orbit/pull/41))
- Memo card scope pinned: repo facts only (roles + entry points), no deep structure. ([#28](https://github.com/orbcli/orbit/pull/28))
- README and USAGE now state that auto-approve needs `jq` on PATH (not preinstalled on macOS/Linux) — without it the hook stays inert and commands fall back to the native permission prompt; the dependency goes away in a future release (hooks will parse payloads natively).
- Marketplace and package descriptions refreshed.

#### Removal

- `install.sh --replace-marketplace` — never shipped (it entered after v0.1.0 and was removed before its first release): a colliding `marketplace add` re-points on most CLIs, and the refused direction is covered by `--force`. ([#16](https://github.com/orbcli/orbit/pull/16))
- `[seed]` jot sentinel and the gap model — memo state computed inline. ([#17](https://github.com/orbcli/orbit/pull/17))
- Stop hooks and `[nudge]`/`[overlong]` markers — covered by stderr + cruise block + done gate. ([#17](https://github.com/orbcli/orbit/pull/17))
- Fetch-refspec reconciliation machinery (register/remove directions, gating, exemptions) — replaced by the maintained wildcard map + `fetch.prune` and native `git remote prune origin`.
- `push.autoSetupRemote` writes and the `orbit doctor` git ≥ 2.37 check — `orbit switch` no longer writes any push config (touchpoint convergence owns it).

## 0.1.0 - 2026-07-06

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
