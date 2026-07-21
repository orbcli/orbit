# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **`orbit context` redesigned around purposes.** `--startup` is the session-start block (cold start → pool roster; populated workspace → each repo's memo + two-layer staleness + conditional per-repo status, with jot queues inlined). Bare `orbit context` is now the **cruise block** (cheap durables + conditional per-repo status: jots / behind upstream / memo state — the in-session counterpart of the startup block) and no longer dumps memos — pull them on demand via `orbit info <repo>`. Keys are `workspace` / `path` / `goal` / `state` (`status` renamed to `state` to avoid clashing with `orbit status`). `--prime` / `--reignite` remain as explicit routing targets for humans and debugging. Command headers (`=== PRIME ===`, `⚙ systems primed`) removed; agent plugins wrap injected blocks in `<orbit-context>` tags.
- **Session hooks are thin wrappers now.** `session-start.sh` injects `orbit context --startup`; new `session-resume.sh` injects the cruise block on resume/compact (Codex also on `clear`). All cold/resume detection logic moved into `orbit.sh` (testable). OpenCode plugin: first transform injects `--startup` (resume routing is blocked on anomalyco/opencode#5409), cache refreshes inject the light cruise block, and `session.compacted` re-injects it after compaction. The hook behavior contract (injection tiers, `<orbit-context>` tags, event routing matrix, auto-approve semantics) now lives in [`docs/spec-hooks.md`](docs/spec-hooks.md).
- **`orbit done` warns per repo** in one merged line each — leftover jots (`pop + merge`), thin memo with no capture (`explore + write`), over-budget card (`curate once`) — keeping the card-budget reminder.
- **Jot aggregation threshold is now per-repo `jot.bufferSize`** (default `memo.minLines` = 4, replacing the hardcoded 10): silent at or below half, `building` note up to the buffer, `overflow` warning past it.
- **`orbit add` on a thin/missing memo** prints a one-shot stderr naming the `explore.paths` scope (both cases), instead of seeding the jot queue.
- **`orbit memo` over-budget** prints a one-shot curate stderr; no queue seeding or throttle markers.

### Removed

- **`[seed]` jot sentinel and the gap model** (`orbit context gaps` key, `orbit_list_gaps`, seed/real jot distinction). Thin/over-budget memo state is computed inline on every read and surfaced via add-time stderr, the cruise block, and the done gate — no durable placeholders.
- **Stop hooks** (`hooks/stop.sh`, `hooks/codex/stop.sh`, and the Stop matchers in all `hooks.json`, incl. OpenCode `session.idle`): their nudges are covered by add-time stderr + cruise block + the done gate. `[nudge]` / `[overlong]` throttle markers removed with them.

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
