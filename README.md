# Orbit

[![CI](https://github.com/orbcli/orbit/actions/workflows/ci.yml/badge.svg)](https://github.com/orbcli/orbit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/github/license/orbcli/orbit)](LICENSE)
[![GitHub Release](https://img.shields.io/github/v/release/orbcli/orbit)](https://github.com/orbcli/orbit/releases)

> Source code as agent knowledge — multi-repo Git workspaces where agents read, code, and ship
>
> → No RAG. No index — real source, not retrieval.

<p align="center">
  <img src="docs/media/orbit-demo-hero.gif" alt="Orbit demo — one cross-repo mission, both worktrees engaged, knowledge captured into memos" width="800">
  <br>
  <em><a href="docs/media/orbit-demo-full.gif">▶ Watch the full run</a></em>
</p>

Orbit manages multi-repo Git workspaces where AI coding agents read, modify, and commit directly in real source code — full worktrees with git history, not index fragments. Integrates with Claude Code, Codex, OpenCode, and Qoder.

I built Orbit because I was tired of copy-pasting context between repo sessions — one agent should have your entire repo pool available, loading what it needs on demand instead of being locked to one repo per session.

**Who it's for:** developers whose agent work spans multiple repos — main project, dependency source, toolchain and wiki alongside it. Solo or team, polyrepo or cross-repo debugging.

## Why Orbit

**Cross-repo context consistency.** One agent, one workspace, multi-repo delivery — every repo the agent pulls in shares the same context. The agent greps, reads, and modifies across repos without switching tools: when it changes backend, it sees the result immediately in frontend. Full git history (blame, log, branch topology) across every repo, no copy-pasting, no stale snapshots.

| Approach | Accuracy | History | Write-back | Cross-repo |
|------|---------|---------|-----------|------------|
| Agent memory | Low — stale | ✗ None | — | ✗ Per-session |
| Web search | Medium — fragments | ✗ None | — | ✗ None |
| Add directory | High — per-dir | ✓ Per-repo | ✓ Yes | ✗ Virtual scope |
| RAG | Medium — loses structure | ✗ Lost in chunks | ✗ Read-only | ✗ Per-query |
| **Orbit** | **High — grep, trace** | **✓ Full git** | **✓ Commit, push** | **✓ Workspace-scoped** |

**Parallel isolation.** Each workspace is an independent multi-repo worktree combination. Multiple agents work in parallel, each in its own workspace — no branch conflicts, no state leaking between tasks. Reusing a single workspace across tasks means branch contamination and agent interference; isolation is what makes multi-task, multi-agent practical.

**Real directory tree, zero toolchain adaptation.** A workspace is a real directory tree — not symlinks, not editor virtual views. Drop a `go.work` and `go build`/`gopls` resolve across repos with zero setup. Same for Cargo/pnpm/Gradle. Your toolchain doesn't know Orbit exists, and that's the point.

**Goal to workspace in one command.** `orbit new "goal"` creates a task-scoped workspace. Once the agent starts, it uses orbit commands to assemble repos progressively:

```
Level 0  orbit repos        → Name + one-line brief (~50 tokens/repo)
Level 1  orbit info <repo>  → Roles + entry points (~200 tokens)
Level 2  orbit add <repo>   → Full source directory
```

After working, the agent captures discoveries with `orbit jot` and folds them into repo memos — the same content later sessions read at Level 1, closing the feedback loop.

**Knowledge repo as a workspace member.** A dedicated knowledge repo — design notes, PRDs, decisions — sits alongside code repos as a first-class member. The agent reads from it and writes back via branch + PR, so knowledge accumulates in one place instead of getting lost in chat or session memory. Solo devs sweep whenever; teams aggregate daily. Same mechanism, no server. See [`docs/recipes.md`](docs/recipes.md#knowledge--notes-repo-as-a-workspace-member) for the pattern.

## Try it now (60 seconds, no setup)

Spins up a two-repo mission — a probe's flight computer and its ground station, wired by a shared contract — entirely on your machine. No GitHub account, no network, no server.

```bash
# Claude Code
curl -sL https://raw.githubusercontent.com/orbcli/orbit/main/examples/demo/try.sh \
  | bash -s -- --claude

# Codex
curl -sL https://raw.githubusercontent.com/orbcli/orbit/main/examples/demo/try.sh \
  | bash -s -- --codex

# OpenCode
curl -sL https://raw.githubusercontent.com/orbcli/orbit/main/examples/demo/try.sh \
  | bash -s -- --opencode

# Qoder CLI
curl -sL https://raw.githubusercontent.com/orbcli/orbit/main/examples/demo/try.sh \
  | bash -s -- --qodercli

# Runtime only (other agents)
curl -sL https://raw.githubusercontent.com/orbcli/orbit/main/examples/demo/try.sh | bash
```

The demo drops you into a ready workspace: add a `fuel` field to the telemetry downlink — a change that must land in *both* repos in lockstep. With `--claude`, `--codex`, or `--qodercli`, the plugin install is folded in — just `claude start`, `codex`, or `qodercli start`. Clean up with `rm -rf ~/orbit-try`.

## Quick Start

### 1. Install

```bash
# From a local checkout
./install.sh --claude          # Claude Code plugin
./install.sh --codex           # Codex plugin
./install.sh --opencode        # OpenCode plugin
./install.sh --qoder           # Qoder plugin (--qodercli is an alias)
./install.sh --claude --zsh    # add shell completion: --zsh or --bash

# Or without cloning
curl -sL https://raw.githubusercontent.com/orbcli/orbit/main/install.sh | bash
curl -sL https://raw.githubusercontent.com/orbcli/orbit/main/install.sh \
  | bash -s -- --claude --zsh
```

`install.sh` installs the runtime to `~/.local/bin` and puts it on your PATH. Add `--force` to reinstall an existing plugin. To uninstall: `./install.sh --uninstall --all` (or pick targets: `--uninstall --claude --codex`, `--uninstall --cli` for just the runtime, etc.).

Codex plugin hooks require a one-time trust review (`/hooks` in the CLI) before they run.

**OpenCode via npm** (alternative): add `"orbit"` to the `plugin` array in `opencode.json` — OpenCode auto-installs it at startup. The plugin self-registers its bundled skill path, so no manual skill setup is needed.

### 2. Configure agent launch command (one-time)

```bash
orbit config agent.recommend 'claude "orbit start"'
```

### 3. Create a workspace and start working

```bash
# Add repos to the source pool (one-time)
orbit clone git@github.com:org/backend.git
orbit clone git@github.com:org/frontend.git

# Create workspace, launch agent
orbit new "Modify API definition and update frontend calls"
cd task-01 && claude "orbit start"

# Or skip manual launch:
orbit new "Upgrade informer to v0.28 new API" --exec 'claude "orbit start"'
```

For the complete command flow, see [`USAGE.md`](USAGE.md); for common scenarios, see [`docs/recipes.md`](docs/recipes.md).

## Core Concepts

```text
project-root/
  .repos/                ← Cloned repos, shared across all workspaces
    .orbit               ← Global index + repo briefs + project config
    .backend.md          ← Repo memo (agent read/write)
    backend/
    frontend/
  task-01/               ← Workspace: isolated environment for one task
    .orbit               ← Goal, creation time, status
    backend/             ← Worktree (actual development directory)
    frontend/
```

## What Orbit is Not

- **Not an orchestrator** — gives each agent an isolated workspace; parallelism comes from isolation, not scheduling.
- **Not a cloud service** — Zero infra, no server, no database, no container, no daemon. Everything lives as real source and plain markdown in your `.repos/`.
- **Not a workflow manager** — orbit doesn't prescribe git workflow (commit, branch, push are native git) or manage workspace files (`go.work`, `Cargo.toml`, `AGENTS.md`, `CLAUDE.md` workspaces). They work because the directory layout is real; placing them is your or your agent's call.

See [`PRINCIPLES.md`](PRINCIPLES.md#non-goals) for the full non-goals.

## Context detection

Orbit works best when the agent knows it's inside a workspace from its first turn:

| Integration | Auto-detect | Workaround |
|:---|:---|:---|
| Claude Code plugin | **Yes** — bundled `SessionStart` hook injects workspace state | — |
| Codex plugin | **Yes** — bundled `SessionStart` hook injects workspace state | — |
| OpenCode plugin | **Yes** — bundled `system.transform` hook injects workspace state | — |
| Qoder plugin | **Yes** — bundled `SessionStart` hook injects workspace state | — |
| Skill only / other agents | No | `/orbit` or `orbit start` at session start |

## Launch sequence

A cold start loads progressively:

1. **Prime** (`orbit context --prime`) — goal, status, prior notes, repo pool roster. No source loaded yet.
2. **Ignition** (`orbit info` → `orbit add <repo>`) — agent assesses repos via memo, pulls what it needs as full worktrees.
3. **Orbit** — grep, edit, commit, push. New repos pulled on demand.

Resuming a workspace with repos already present skips priming.

## Auto-approving safe commands

Plugin users: nothing to configure — all four plugins (Claude, Codex, OpenCode, Qoder) auto-approve safe orbit subcommands. Skill-only users can allowlist by hand. See [`skills/CONSTRAINTS.md`](skills/CONSTRAINTS.md#permission-and-auto-execution-policy) for command tiers and the allowlist snippet.

## Command Reference

```bash
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
orbit context [<key>] [--prime] [--json]

# Configuration
orbit config [<key> [<value> | --unset]]

# Diagnostics
orbit doctor
orbit version

# Completion
orbit completion <zsh|bash>
```

## Documentation

| Document | Content |
|------|------|
| [`USAGE.md`](USAGE.md) | Complete usage guide |
| [`docs/recipes.md`](docs/recipes.md) | Common scenarios cookbook |
| [`docs/comparison.md`](docs/comparison.md) | Tool comparison (workspace management + context/knowledge tools) |
| [`PRINCIPLES.md`](PRINCIPLES.md) | Design principles and key decisions |
| [`ROADMAP.md`](ROADMAP.md) | Roadmap and completion status |
| [`docs/spec-*.md`](docs/) | Design specs (directory structure, branching strategy, command system, metadata, knowledge system, lifecycle) |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Contribution workflow and development conventions |
