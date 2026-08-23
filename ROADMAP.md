# Orbit Roadmap

## Completed

- Workspace full lifecycle: new → add → done → (prune | reactivate via goal), with three-layer branch verdicts
- Command system aligned with design specs: 18 commands covering the complete workflow (clone / new / add / switch / jot / sync / done / prune / status / goal / repos / info / memo / config / context / doctor / completion / version)
- Metadata infrastructure (`.repos/.orbit` global index + per-repo `.md` + workspace `.orbit` + brief extraction + staleness detection)
- CLI experience: `--json` output + bash/zsh shell completion
- Skills/plugins bundled for four agents (Claude Code / Codex / OpenCode / Qoder) + unified installer
- Core documentation (README / USAGE / ROADMAP / PRINCIPLES / spec series)
- `orbit add --ref <tag/branch>`: checkout to specified ref when creating worktree, ensuring the source code version the agent verifies matches the project's actual dependencies
- `orbit memo --scaffold`: generate scaffold template to stdout (directory structure + README first paragraph + primary language detection), agent uses this as reference to write formal memo
- `orbit sync [repo...] [--force] [--branch <branch>]`: sync pool repo to upstream latest (fast-forward / force reset / switch tracking branch)
- `orbit info` two-layer staleness detection (remoteAhead / memoBehind), reading last-fetched refs
- `orbit doctor`: environment health check (git ≥2.20 / bash ≥3.2 / jq+gh optional dependencies / `.repos/` structural integrity diagnostics)
- `orbit jot`: lightweight discovery queue (push/pop) for recording knowledge during work, aggregated into memo at natural breakpoints — reduces per-discovery cost from ~500 tokens to ~20 tokens
- Deterministic session-context injection: plugin-shipped hooks (SessionStart / resume / compact) keep the agent workspace-aware, working across all four bundled agents — zero user effort (prompts to install the runtime when `orbit` is missing)
- Destructive-surface hardening: machine-enforced root-only `prune` / `sync --force`, per-branch verdicts, `.prune-trash` recovery
- Context system: startup/cruise injection blocks; hook CWD anchoring across all four agents (incl. Qoder IDE JSON wrappers)
- Install semantics: every install refreshes to latest; `--force` = full plugin+marketplace reset with reachability probe
- Network-resilient installs (source chain + retries); SSH-less install; zero-config demo (`try.sh`)
- Plugin distribution: Claude Code / Codex / OpenCode / Qoder marketplaces + npm (`opencode-orbit`)

## Short-term

### Runtime & UX

- [ ] Performance: hot paths (session start, `status`, `context`, `prune`) get measurably faster
- [ ] Drop the `jq` dependency — auto-approve hooks parse payloads natively
- [ ] Color output (TTY-aware): auto-colorize when `[ -t 1 ]`, plain text when piped

### Integrity (pool & workspace)

- [ ] Pool repo lifecycle: `retire` / `rename` for pool repos (clone gives birth; nothing takes them away)
- [ ] Pool shared-config self-heal via touchpoint convergence (native git has no permission model — prevention isn't possible, so converge-and-repair it is)
- [ ] Workspace integrity recovery: best-effort restoration of required elements

## Mid-term

### Agent Ecosystem

- [ ] [pi](https://github.com/earendil-works/pi) support: bundled integration (skill + session-context injection) for the pi coding agent

### Feature Enhancements

- [ ] `orbit new --auto-name` agent auto-naming (opt-in)
- [ ] PR URL → worktree: `orbit add <repo> --pr <url>` fetches the PR head via origin's `pull/N/head` ref (GitHub first; no extra remote, no gh dependency)

## Long-term

### Repo Graph

- [ ] `graph`: cross-repo dependency/reference graph over the pool — code refs and memo links alike; the long-run shape is an Obsidian-style graph view built on the link structure

### Memo Management

- [ ] Memo write-pollution guard: a weaker agent's card write must not silently overwrite a stronger one (single-level `.bak` rotation before writeback)
- [ ] Memo staleness by content anchors (best-effort hints only: free-form card input means no hard verdicts)

## Known Issues and Compatibility

| # | Scenario | Tools Involved | Status | Description |
|:--|:-----|:---------|:-----|:-----|
| 1 | VS Code GitLens recognition of `.git` file | VS Code + GitLens | Unconfirmed | `.git` under worktree is a file, not a directory |
| 2 | JetBrains IDE worktree support | IntelliJ / GoLand | Unconfirmed | Whether VCS model correctly recognizes worktree |
| 3 | Language server cross-repo references | gopls / tsserver | Unconfirmed | Multi-repo cross-references under workspace |
| 4 | Qoder / VS Code worktree recognition | Qoder + VS Code | Confirmed (working) | Branch, status, diff all work correctly |
| 5 | Session-start context injection on other frameworks | Agent frameworks beyond the four bundled ones (Claude Code / Codex / OpenCode / Qoder) | Fallback only | No native `SessionStart`-equivalent hook means deterministic injection isn't available; the agent relies on the `orbit start` trigger phrase, which depends on the launch phrase actually being used |

## Notes

`README.md` explains what Orbit is; `USAGE.md` how to use it; `PRINCIPLES.md` why it's designed this way; `ROADMAP.md` where things stand and what's next; `docs/spec-*.md` defines behavioral specs (`spec-knowledge.md` covers loading, staleness, and lifecycle; `spec-metadata.md` covers format and fallback); `CONTRIBUTING.md` how to participate. Tool comparisons are in `docs/comparison.md`; common scenarios in `docs/recipes.md`.
