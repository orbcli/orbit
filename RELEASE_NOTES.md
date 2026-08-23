# 🚀 Orbit v0.2.0 — MaxQ

*Released 2026-08-23*

**Multi-repo Git workspaces for any coding agent — real worktrees, no index, no server.**

MaxQ is the ascent phase where aerodynamic stress peaks and the airframe either holds or doesn't — seven weeks of daily dogfooding put this release under exactly that, and the structure held: 26 PRs of hardening, contract pinning, and repair.

## Highlights

- **The destructive surface is now machine-enforced.** `prune` and `sync --force`/`--branch` run from the project root only, verified by process ancestry — not by convention. Prune was rebuilt around all-or-nothing validation, per-branch verdicts, and a `.prune-trash` recovery window.
- **The context system was redesigned.** Session start injects a purpose-built startup block (goal, repo memos, staleness); resume/compact get a cheap cruise block. Hooks anchor to the host-injected project dir, so injection works across Claude Code, Codex, OpenCode, and Qoder — IDE included.
- **Install means latest.** Every install run now refreshes the marketplace snapshot and reinstalls the plugin from it; `--force` is a full reset (with a reachability probe so an offline reset can't destroy your last working install). The runtime itself refreshes the same way.

## ⚠️ Breaking changes (upgrading from 0.1.0)

- `prune` and `sync --force`/`--branch` run from the project root only — the CLI checks the calling shell's process ancestry, so `cd`-ing out first does not bypass it, and no flag does either. `prune` also left the agent skill's action surface: agents report the need, humans run it.
- `prune --force` now overrides the data guards too, not just branch protection — it announces what it discards first.
- `prune --verify` removed (merged-PR evidence now applies automatically from recorded PR URLs when `gh` is available); `ORBIT_BRANCH_PREFIX` is no longer read (use `orbit config branch.prefix`).
- `install.sh` refreshes on every run; `--force` is now a full plugin+marketplace reset (it probes source reachability first).
- Pool fetch and push config is Orbit-maintained (wildcard refspec + `fetch.prune` + `push.default=upstream`; opt out per key via `orbit config`) — a bare `git fetch`/`git pull` in any worktree now fetches every branch.
- Output contracts changed: the old fetch-refspec reconciliation lines are gone and prune's report shape changed — update anything that greps orbit's output.
- OpenCode plugin/skill removal is directory-level — anything inside `~/.config/opencode/skills/orbit/` is deleted.

Also in: network-resilient installs (source chain + retries), SSH-less plugin install, demo runs on zero-config machines, guidance for config-management tools that silently roll back plugin registration ([USAGE](USAGE.md#config-management-tools) — recovery and prevention, per host), and a set of removals (stop hooks, the refspec registry, `--replace-marketplace`, and more — the full list is in the changelog); the mission drops spent weight to stay on course. Covered by 396 bats tests.

Full details in the [changelog](CHANGELOG.md).

---

# 🚀 Orbit v0.1.0 — Liftoff

*Released 2026-07-06 · superseded by v0.2.0 (see above)*

**Source code as agent knowledge — multi-repo Git workspaces where agents read, code, and ship.**

Orbit manages multi-repo Git workspaces for AI coding agents. Instead of embeddings, vector stores, or stitching together scattered docs, agents work directly against full source worktrees — grepping API signatures, tracing call chains, then editing, committing, and pushing, all from one directory. Every task gets its own isolated workspace, so multiple agents can run in parallel without stepping on each other.

This is our first public release. The core workflow is stable, covered by 177 tests across 20 files, and already in daily use. We're shipping now because the foundation is solid enough to build on — together.

---

## ✨ Highlights

### 1. One source of truth — read and write unified

No RAG. No stale training data. Agents verify against real source, then edit, commit, and push from that same source. One mechanism for both reading and writing.

### 2. Agent self-service with progressive loading

Agents decide what they need — no human setup required:

```
Level 0  orbit repos        → Name + one-line brief (~50 tokens/repo)
Level 1  orbit info <repo>  → Repo roles + key entry points — when to add, where to start (~200 tokens)
Level 2  orbit add <repo>   → Full source — grep, read, trace
```

### 3. Parallel workspace isolation

Each workspace is an independent combination of multi-repo worktrees. Multiple agents, multiple tasks, zero conflicts. Polyrepo teams don't have to migrate to a monorepo — every repo keeps its own Git history and CI.

### 4. A knowledge feedback loop

Agents capture discoveries with `orbit jot` (cheap, ~20 tokens) and fold them into persistent repo memos via `orbit memo`. The next session's agent picks up those memos at Level 1 — no re-exploration needed.

### 5. First-class agent integrations

Ships with **Claude Code** and **Qoder** plugins — `SessionStart` hooks for deterministic workspace detection, `PreToolUse` hooks that auto-approve safe commands, and full skill definitions. Zero-config for supported agents.

---

## 📦 What's Included

### Core Commands
- **`clone`** — Add repos to the shared pool (supports fork push-URLs)
- **`repos`** — Browse the pool roster (`--json`, plus `memoBehind` staleness)
- **`info`** — Repo memo (roles + entry points) and auto-fetch, with two-layer staleness detection
- **`memo`** — Read and write repo knowledge (`--scaffold` to generate a template, `--refresh` to rebuild the index)
- **`sync`** — Fast-forward pool repos to upstream (force reset, branch switching)

### Workspace Lifecycle
- **`new`** — Create a workspace with a goal (`--exec` to launch an agent immediately, `--name` for custom naming)
- **`add`** — Pull a repo into the workspace as a full worktree (`--ref` to check out a tag or branch)
- **`switch`** — Branch operations within a workspace (`-c` to create, or switch to an existing branch)
- **`jot`** — Lightweight discovery queue (push/pop) for capturing knowledge in flight
- **`done`** — Mark work complete and record PR URLs
- **`prune`** — Reclaim done workspaces (`--dry-run`, `--verify`, `--older`, with branch protection)

### Workspace Reactivation
Setting a goal on a done workspace clears its completion record and PR history, reactivating it for reuse — no need to spin up a new workspace for follow-up work.

### Status & Context
- **`status`** — Workspace state at a glance
- **`goal`** — Read, set, or clear the workspace goal (pipe-friendly)
- **`context`** — A complete context dump in one call (`--prime` for cold starts, `--json`, or single-key queries)

### Configuration & Diagnostics
- **`config`** — Project-level settings (e.g. `agent.recommend`)
- **`doctor`** — Environment health check (git ≥ 2.20, bash ≥ 3.2, optional deps, project structure)
- **`completion`** — Shell completion for zsh and bash

### Agent Integrations
- Claude Code plugin (skill + `SessionStart` hook + `PreToolUse` hook)
- Qoder plugin (skill + `SessionStart` hook + `PreToolUse` hook)
- Unified `install.sh` with `--claude` / `--qoder` (alias `--qodercli`) / `--zsh` / `--bash` flags

---

## ⚡ Quick Start

```bash
# Install the runtime and an agent plugin
./install.sh --claude          # or --qoder

# Add repos to the pool
orbit clone git@github.com:org/backend.git
orbit clone git@github.com:org/frontend.git

# Set your recommended launch command (one-time)
orbit config agent.recommend 'claude "orbit start"'

# Create a workspace and launch
orbit new "Update the API definition and adjust frontend calls"
cd task-01 && claude "orbit start"
```

Or bootstrap without cloning the repo first:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/orbcli/orbit/main/install.sh)"
```

---

## ⚠️ Known Limitations

- **Convention-based isolation** — Agents are kept inside workspace boundaries by skill-level conventions, not filesystem sandboxing. This is fine for the single-owner model, but it isn't hardened for untrusted or adversarial multi-agent setups.
- **No color output yet** — All CLI output is plain text; TTY-aware coloring is planned.
- **IDE worktree recognition** — A few edge cases around the `.git` worktree-pointer file (VS Code + GitLens, JetBrains) are unconfirmed. Qoder and VS Code are confirmed working.
- **Skill-only agents lack deterministic detection** — Without the plugin hooks, agents fall back to the `orbit start` trigger phrase at session start.
- **No `export` / `import` yet** — Sharing team knowledge currently requires access to the same filesystem; a portable export is on the roadmap.
- **Dependencies** — Requires `git` ≥ 2.20 and `bash` ≥ 3.2. Optional: `jq` (JSON parsing) and `gh` (GitHub CLI features).

---

## 🙏 Get Involved

This is day one. The foundation is in place — directory model, branch strategy, metadata contract, knowledge system — and it's built so that whatever comes next never forces the base to be reworked.

If you work with AI agents across multiple repos and you're tired of fragmented context, take Orbit for a spin:

- ⭐ **[Star the repo](https://github.com/orbcli/orbit)** if the approach resonates
- 🐛 **[Open an issue](https://github.com/orbcli/orbit/issues)** — bug reports, UX friction, missing docs
- 💡 **[Start a discussion](https://github.com/orbcli/orbit/discussions)** — workflow ideas, integration requests, war stories
- 🤝 **[Read CONTRIBUTING.md](https://github.com/orbcli/orbit/blob/main/CONTRIBUTING.md)** — PRs welcome

More to come. Godspeed. 🛰️
