# Orbit Roadmap

## Completed

- Workspace full lifecycle: new → add → done → (prune | reactivate via goal), with three-layer branch protection
- Command system aligned with design specs: 18 commands covering the complete workflow (clone / new / add / switch / jot / sync / done / prune / status / goal / repos / info / memo / config / context / doctor / completion / version)
- Metadata infrastructure (`.repos/.orbit` global index + per-repo `.md` + workspace `.orbit` + brief extraction + staleness detection)
- CLI experience: `--json` output + bash/zsh shell completion
- Claude Code skill + Qoder skill + Unified installer
- Core documentation (README / USAGE / ROADMAP / PRINCIPLES / spec series)
- `orbit add --ref <tag/branch>`: checkout to specified ref when creating worktree, ensuring the source code version the agent verifies matches the project's actual dependencies
- `orbit memo --scaffold`: generate scaffold template to stdout (directory structure + README first paragraph + primary language detection), agent uses this as reference to write formal memo
- `orbit context`: output complete context of current workspace (goal + repo brief/memo + background info), agent gets all needed context with one command after entering workspace
- `orbit repos --json` output adds `memoBehind` field: agent can judge memo freshness at Level 0
- `orbit sync [repo...] [--force] [--branch <branch>]`: sync pool repo to upstream latest (fast-forward / force reset / switch tracking branch)
- `orbit info` auto-fetch + two-layer staleness detection (remoteAhead / memoBehind)
- `orbit doctor`: environment health check (git ≥2.20 / bash ≥3.2 / jq+gh optional dependencies / `.repos/` structural integrity diagnostics)
- `orbit jot`: lightweight discovery queue (push/pop) for recording knowledge during work, aggregated into memo at natural breakpoints — reduces per-discovery cost from ~500 tokens to ~20 tokens
- Deterministic session-start context injection: the plugin ships a `SessionStart` hook (startup / resume / compact) that runs `orbit context` to keep the agent aware it is inside a workspace — proven on **Claude Code** and **Qoder**, zero user effort (prompts to install the runtime when `orbit` is missing).

## Mid-term

### Knowledge Sharing

- [ ] `export`: export repos + workspace combination as a reproducible rebuild script, enabling team members to one-click replicate the knowledge base (strategic: portability foundation for repos as team knowledge assets)
- [ ] `import`: rebuild repos + workspace environment from export script

### Feature Enhancements

- [ ] Color output (TTY-aware): auto-colorize when `[ -t 1 ]` detects TTY, plain text when piped/redirected
- [ ] `orbit new --auto-name` agent auto-naming (opt-in)
- [ ] Cross-worktree conflict detection: detect files modified in the same repo across different workspaces, warning of potential merge conflicts
- [ ] PR URL → worktree: `orbit add <repo> --pr <url>` auto-fetch PR head branch to create worktree (depends on gh CLI)

## Long-term

- [ ] `graph`: cross-repo dependency graph

## Backlog

The following items come from community benchmarking analysis. Not prioritized now but not excluded for the future. Entry criteria: short-term feasibility + validated real demand.

- [ ] `trust` security model: repo-defined executable hooks require explicit approval before execution, preventing malicious repo injection (distinct from the plugin `SessionStart` hook; prerequisite: after a repo-hooks mechanism exists)
- [ ] Workspace fork: `orbit fork <src-ws> <new-ws>` derive from existing workspace (prerequisite: after lifecycle stabilization)
- [ ] `orbit watch`: daemon monitoring PR merged / branch deleted, triggering notifications or auto prune
- [ ] Port range environment isolation: each workspace assigned an independent port range to avoid multi dev server conflicts (opt-in)
- [ ] MCP server: expose orbit capabilities as MCP endpoint (skill already provides agent integration path, MCP is supplementary not prerequisite)
- [ ] `exec "<cmd>"`: batch execute on all repos within workspace (not essential for agent scenarios, nice-to-have for human scenarios)
- [ ] `orbit add` config file copy: copy gitignored config files from repos to worktree (only serves "running code" scenarios, not core to agent knowledge path)
- [ ] `.code-workspace` auto-generation: pure human IDE DX, not core to agent knowledge path
- [ ] Optional TUI mode: pure human interactive experience (prerequisite: after core command system stabilization)

## Known Issues and Compatibility

| # | Scenario | Tools Involved | Status | Description |
|:--|:-----|:---------|:-----|:-----|
| 1 | VS Code GitLens recognition of `.git` file | VS Code + GitLens | Unconfirmed | `.git` under worktree is a file, not a directory |
| 2 | JetBrains IDE worktree support | IntelliJ / GoLand | Unconfirmed | Whether VCS model correctly recognizes worktree |
| 3 | Language server cross-repo references | gopls / tsserver | Unconfirmed | Multi-repo cross-references under workspace |
| 4 | Qoder / VS Code worktree recognition | Qoder + VS Code | Confirmed (working) | Branch, status, diff all work correctly |
| 5 | Session-start context injection on other frameworks | Agent frameworks beyond Claude Code / Qoder | Fallback only | No native `SessionStart`-equivalent hook means deterministic injection isn't available; the agent relies on the `orbit start` trigger phrase, which depends on the launch phrase actually being used |

## Notes

`README.md` explains what Orbit is; `USAGE.md` how to use it; `PRINCIPLES.md` why it's designed this way; `ROADMAP.md` where things stand and what's next; `docs/spec-*.md` defines behavioral specs (`spec-knowledge.md` covers loading, staleness, and lifecycle; `spec-metadata.md` covers format and fallback); `CONTRIBUTING.md` how to participate. Tool comparisons are in `docs/comparison.md`; common scenarios in `docs/recipes.md`.
