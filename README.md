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

Orbit manages multi-repo Git workspaces, letting AI coding agents read, modify, and commit directly in real source code — full worktrees, not index fragments. Each agent works in an isolated workspace, enabling natural parallelism. Ships with Claude Code and Qoder integrations.

**Who is this for?** Developers — solo or on a team — whose work spans multiple repos: your main project, its dependency source (Kubernetes, React, gRPC…), and the toolchain you maintain alongside it (agent skills, CI/CD, linters, PRD/config). Especially if you're on polyrepo and don't want to migrate to a monorepo just to give agents cross-repo context.

Your agent needs to work across repos — but today each session starts fresh, hallucinating API details it could just grep from real source. Orbit gives it real worktrees for all your repos.

## Why Orbit

**Source-driven, read-write unified** — Pull in dependency source code (Kubernetes, React, gRPC, etc.) and let agents grep API signatures, read implementations, and trace call chains — verifying against real code rather than stale training data. The same directory serves as both knowledge source and working directory: verify an API, then modify code, commit, and push — no tool switching.

| Approach | Information Source | Accuracy | Can Modify Code | Context Cost |
|------|---------|--------|-----------|-----------|
| Agent memory | Training data | Low — may be stale | — | None |
| Web search | Docs / StackOverflow | Medium — fragments, hard to trace | — | Medium |
| RAG | Embedding + vector retrieval | Medium — loses code structure | ✗ Read-only | Medium |
| **Orbit** | **Complete source worktree** | **High — grep, read, trace call chains** | **✓ Modify in place, commit, push** | **On-demand** |

**Agent self-service** — `orbit new "goal"` starts a task. The agent browses repo briefs, decides which repos it needs, and runs `orbit add` — no human pre-configuration required. Information loads progressively, diving deeper on demand:

```
Level 0  orbit repos        → Name + one-line brief (~50 tokens/repo)
Level 1  orbit info <repo>  → Repo roles + key entry points — when to add, where to start (~200 tokens)
Level 2  orbit add <repo>   → Complete source directory, can grep, read files, trace call chains
```

After working, the agent captures discoveries with `orbit jot` and folds them back into the repo memo via `orbit memo` — the same content later sessions read at Level 1, closing the knowledge feedback loop.

**Parallel isolation** — Each workspace is an independent multi-repo worktree combination that persists across sessions. Multiple agents work in parallel, each in its own workspace. Teams using polyrepo don't need to migrate to monorepo — agents grep and trace call chains across repos within a workspace, while each repo keeps its own Git history and CI.

**Knowledge accumulation** — Cloned repos grow richer with usage as agents write memos. Those memos persist across sessions, so your own later sessions skip re-exploration — and because they're plain files in the repo, sharing across teammates falls out for free: a new teammate's agent immediately reads accumulated repo understanding without exploring from scratch.

**Knowledge repo as a workspace member** — Beyond the per-repo memo, add a *dedicated knowledge repo* to the pool: a full Git repo of plain markdown — design notes, PRDs, decisions, an agent-maintained wiki — first-class alongside your code repos, with no cap on what it holds. One knowledge repo serves any workspace on demand (`orbit add`), and the agent writes back into it via branch + PR. So the auxiliary infrastructure you maintain by hand — agent skills, CI/CD, linters, compilers, PRD/notes — that rarely lives in the repo you're editing finally has a place for its feedback to accumulate: the agent routes pitfalls and fixes into the knowledge repo instead of losing them. A solo dev sweeps it on their own cadence; a team's owner aggregates daily — same git-native mechanism, no server. See [`docs/recipes.md`](docs/recipes.md#knowledge--notes-repo-as-a-workspace-member) for the general pattern, or [the toolchain feedback loop](docs/recipes.md#accumulate-toolchain-feedback-in-a-knowledge-repo) for that use case.

## What Orbit is Not

- **Not an agent orchestrator** — Orbit doesn't schedule or coordinate *peer* agents (a single owner agent may still delegate to worker sub-agents — see [`PRINCIPLES.md`](PRINCIPLES.md#7-tiered-decision-authority-for-agent-operations)). It gives each agent an isolated workspace; parallelism comes from isolation, not from a scheduler.
- **Not a cloud index or context service** — no server, no embeddings, no vector store. Knowledge lives as real source worktrees and plain-markdown memos in your own `.repos/`.
- **Not a RAG / code-indexing tool** — agents work against complete source they can grep, edit, commit, and push, not read-only retrieved fragments.

See [`PRINCIPLES.md`](PRINCIPLES.md#non-goals) for the full non-goals.

## Quick Start

### 1. Install

From a local checkout, install the runtime plus your agent's plugin:

```bash
./install.sh --claude          # Claude Code plugin
./install.sh --qoder           # Qoder plugin (--qodercli is an alias)
./install.sh --claude --zsh    # add shell completion: --zsh or --bash
```

`install.sh` always installs the global `orbit` runtime to `~/.local/bin` and puts it on your PATH. Add `--zsh` / `--bash` for tab-completion and `--force` to reinstall an existing plugin. To install only the runtime, run `./install.sh` with no flags — or bootstrap it without cloning:

```bash
curl -sL https://raw.githubusercontent.com/orbcli/orbit/main/install.sh | bash
```

To uninstall, remove the runtime and any plugin you installed:

```bash
rm ~/.local/bin/orbit                 # runtime
claude plugin uninstall orbit         # Claude Code plugin, if installed
qodercli plugins uninstall orbit@orbcli -s user   # Qoder plugin, if installed
```

Shell completion, if installed, is a single `_orbit` (zsh) or `orbit` (bash) file in your completion path; delete it to remove. Your `.repos/` pool is never touched by uninstall.

### 2. Configure agent launch command (one-time)

```bash
orbit config agent.recommend 'claude "orbit start"'
```

Once configured, each `orbit new` will recommend a launch command — just copy and execute. The agent automatically reads the goal, discovers repos, and starts working.

Baking the `orbit start` phrase into the command loads the orbit skill from the first turn. With the Claude Code or Qoder plugin installed, the bundled session hook detects the workspace and injects its state without the phrase — but loading the skill's full conventions is model-driven, so keeping the phrase (or `/orbit`) is still the reliable way to trigger them. It's essential only for skill-only or other-agent setups that have no hook. See [Context detection](#context-detection).

### 3. Create a workspace and start working

```bash
# Add repos to the source pool (one-time)
orbit clone git@github.com:org/backend.git
orbit clone git@github.com:org/frontend.git

# Create workspace, launch agent with recommended command
orbit new "Modify API definition and update frontend calls"
cd task-01 && claude "orbit start"

# Agent automatically:
#   orbit context --prime → primes on goal + status (fresh workspace; source loads on demand)
#   orbit add backend / frontend → pulls into workspace on demand
#   works, commits, pushes
#   orbit memo → writes back findings for subsequent sessions
#   orbit done --pr <url>
```

You can also use `--exec` to skip manual launch:

```bash
orbit new "Upgrade informer to v0.28 new API" --exec 'claude "orbit start"'
```

No separate `init` command is needed — `orbit clone` and `orbit new` automatically initialize the project root when required.

For the complete command flow, see [`USAGE.md`](USAGE.md); for common scenarios, see [`docs/recipes.md`](docs/recipes.md).

## Try it now (60 seconds, no setup)

Want the whole loop without wiring up your own repos? This spins up a tiny two-repo mission — a probe's flight computer (`navigator`) and its ground station (`mission-control`), wired by a shared telemetry-frame contract — entirely on your machine. No GitHub account, no network, no server: the "upstreams" are local bare repos, so even `git push` works.

```bash
curl -sL https://raw.githubusercontent.com/orbcli/orbit/main/examples/demo/try.sh | bash
# or fold in the agent plugin so you can launch straight away:
curl -sL https://raw.githubusercontent.com/orbcli/orbit/main/examples/demo/try.sh | bash -s -- --claude
```

It drops you into a ready workspace with both repos in the pool and a goal set: add a `fuel` field to the telemetry downlink — a change that must land in *both* repos in lockstep, because the frame is a positional contract neither repo can see alone. With `--claude` (or `--qodercli`) the plugin install is folded in, so you just `claude start` (or `qodercli start`) — the session hook detects the workspace, no magic phrase needed. The agent commits locally, then pauses for your OK before pushing. Prefer to drive it yourself? The script prints a by-hand path too. Clean up any time with `rm -rf ~/orbit-try`.

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

## Context detection

Orbit works best when the agent knows it is inside a workspace from its first turn. How reliably that happens depends on the integration:

| Integration | Reliable context detection | Workaround |
|:---|:---|:---|
| Claude Code plugin | **Yes** — a bundled `SessionStart` hook (startup / resume / compact) detects the workspace and injects its state automatically | — |
| Qoder plugin | **Yes** — a bundled `SessionStart` hook (startup / resume / compact) detects the workspace and injects its state automatically | — |
| Skill only / other agents | No | trigger manually |

Where detection is not automatic, trigger the skill at session start: the `/orbit` slash command in Claude Code, or an `orbit start` message (portable across frameworks). The plugin hooks (Claude Code and Qoder) guarantee detection and context injection, but loading the skill's full conventions is still model-driven — so `/orbit` or `orbit start` remains the reliable trigger even there.

## Launch sequence

A cold launch into a workspace unfolds the way a rocket reaches orbit — three beats, each loading only what that stage needs:

| Beat | Trigger | What happens |
|:---|:---|:---|
| **Prime** | `orbit context --prime` | *Systems primed.* On a cold-start workspace (no repos yet), the plugin hook injects orientation at session start — goal, status, any unfinished notes from the last session, and the pool roster: the repos on offer to `orbit add`, one line each. No source loaded yet; just bearings and the manifest. |
| **Ignition** | `orbit info` → `orbit add <repo>` | *Engines light.* The agent sizes up each candidate with `orbit info` (memo: roles + entry points), then pulls the repos it needs into the workspace as full worktrees — assess before you add, so the turbopumps spool up on the right source. |
| **Orbit** | *the work* | *On station.* The agent greps, traces call chains, edits, commits, and pushes in real source — operating in orbit toward the goal, each repo's memo already aboard from its `info` pass. |

On station the agent **resupplies rather than relaunches** — when a call chain reaches a repo not yet aboard, it pulls that one in on demand (`orbit repos` → `orbit info` → `orbit add`) without returning to the pad, still assessing before it adds. Resuming a workspace that already holds repos skips priming entirely: the hook simply nudges the agent to pick up the prior task, repo detail on demand.

## Auto-approving safe commands

An orbit session runs read-only and idempotent subcommands constantly, so per-command confirmation prompts add up. **Plugin users — nothing to do:** both plugins ship a `PreToolUse` hook that auto-approves exactly the safe subcommands and fails safe (destructive or non-orbit commands still prompt). Skill-only users can allowlist the same set by hand.

See [`skills/CONSTRAINTS.md`](skills/CONSTRAINTS.md#permission-and-auto-execution-policy) for the command tiers, the allowlist snippet, and the full rationale.

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
