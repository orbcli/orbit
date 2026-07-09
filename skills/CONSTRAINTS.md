# Orbit Skills — Unified Constraints and Design Principles

> This document defines the unified constraints that all agents (Claude, Qoder, and future additions) must follow when implementing or maintaining orbit skills, and how those skills are packaged into agent plugins.

## Packaging and Layout

Orbit ships one shared runtime plus a per-agent skill and hook. Repo layout → what each agent loads:

| Path | Role | Wired by |
|------|------|----------|
| `orbit.sh` | The runtime (all commands) | `install.sh` / curl bootstrap installs it to PATH |
| `skills/orbit/SKILL.md` | Claude Code skill | `.claude-plugin/plugin.json` → `"skills": ["./skills/orbit"]` (explicit allowlist so the Qoder skill nested under `skills/` is not also discovered) |
| `skills/qoder/orbit/SKILL.md` | Qoder skill | `.qoder-plugin/plugin.json` → `"skills": "./skills/qoder/"` |
| `skills/CONSTRAINTS.md` | This doc — shared constraints, not shipped as a skill | — |
| `hooks/session-start.sh` | Shared `SessionStart` script (context injection) | Referenced by both `hooks.json` |
| `hooks/auto-approve.sh` | Shared `PreToolUse` script (auto-approve safe orbit commands) | Referenced by both `hooks.json` |
| `hooks/claude/hooks.json` | Claude hook wiring | `.claude-plugin/plugin.json` → `"hooks"` |
| `hooks/qoder/hooks.json` | Qoder hook wiring | `.qoder-plugin/plugin.json` → `"hooks"` |
| `.claude-plugin/` | Claude plugin + marketplace manifest | Claude marketplace |
| `.qoder-plugin/` | Qoder plugin manifest | Qoder marketplace |

The two `SKILL.md` files are kept in sync — content is identical, so edit both together when changing skill behavior.

## Permission and Auto-Execution Policy

Agents gate every shell command behind a user confirmation prompt. For an orbit session that runs `context` / `repos` / `info` / `status` dozens of times, that turns into confirmation fatigue. This section defines which orbit subcommands are safe to run without a prompt, why, and how to enable that per agent.

### Command Tiers (by side effect)

The tiers below are the contract. Anything not in the first two tiers must keep prompting.

| Tier | Subcommands | Side effect | Auto-approve? |
|------|-------------|-------------|---------------|
| **Read-only** | `repos` `info` `status` `context` `goal` (read) `jot` (read/pop) `version` `doctor` `completion` | None, or reads workspace/pool metadata. No repo, no remote, no filesystem mutation outside `.orbit` cache | **Yes** |
| **Idempotent workspace-write** | `add` `switch` `sync` `memo` `goal` (write) `jot` (write) | Mutates the local workspace/worktree or the `.orbit` cache. Re-runnable, reversible, never touches a remote | **Yes** |
| **Destructive / externally-visible** | `done` `prune` `clone` `config` `new` | Marks lifecycle state, deletes worktrees/branches, writes to `.repos/`, or changes project config | **No — always prompt** |

**Why the first two tiers are safe to auto-run:** they cannot lose the user's work or leak outside the machine. Reads have no effect; the idempotent writes only build up the workspace the agent is already working in (worktrees, memos, jots) and are trivially reversible with git. **Why the third tier still prompts:** `prune` deletes worktrees and branches, `done` flips lifecycle state, `clone` writes into the shared pool, and `config` changes project-wide behavior — each is either hard to reverse or visible beyond the current workspace, so the user should stay in the loop.

`new` is excluded on purpose: new workspaces are created at project root, outside the agent's scope (see Anti-Pattern #3), so it should be human-initiated regardless of permissions.

### Two ways to enable it

**1. Bundled auto-approve hook (zero config, recommended).** Both plugins ship `hooks/auto-approve.sh`, wired as a `PreToolUse` / `Bash` matcher in each `hooks.json`. It inspects the pending Bash command and emits an `allow` decision only when the command is a **single, un-chained** invocation of `orbit` whose subcommand is in the two safe tiers. It is fail-safe by construction — if `jq` is missing, the tool is not Bash, the command contains any shell chaining/redirection/substitution (`;` `&` `|` `` ` `` `$(` `>` `<`, newline), or the leading binary is not `orbit`, it prints nothing and the normal confirmation prompt happens. Nothing to configure; installing the plugin is enough.

**2. Static allowlist in agent settings (opt-in, for users who prefer explicit config or run skill-only without the plugin hook).** Plugins cannot declare a permission allowlist — only the user's own settings can — so this path is manual. Mirror the two safe tiers:

*Claude Code* — `.claude/settings.json` (project) or `~/.claude/settings.json` (global):

```json
{
  "permissions": {
    "allow": [
      "Bash(orbit repos:*)",
      "Bash(orbit info:*)",
      "Bash(orbit status:*)",
      "Bash(orbit context:*)",
      "Bash(orbit goal:*)",
      "Bash(orbit jot:*)",
      "Bash(orbit version:*)",
      "Bash(orbit doctor:*)",
      "Bash(orbit completion:*)",
      "Bash(orbit add:*)",
      "Bash(orbit switch:*)",
      "Bash(orbit sync:*)",
      "Bash(orbit memo:*)"
    ]
  }
}
```

*Other vendors (Qoder, Codex, Cursor, …)* — the same tier mapping applies; only the config dialect differs. Community contributions welcome: add the vendor's allowlist snippet here when its integration is verified.

### Maintainer contract

If you change the tier of any subcommand, or add/remove a subcommand, update **all three** in the same change so they never drift:
1. the tier table above,
2. the `case` allowlist in `hooks/auto-approve.sh`,
3. the example allowlist snippet(s) above.

## Product Design Principles (Must Be Enforced)

### 1. Workspace = Agent Scope Boundary
- Agent launches within the workspace directory, not at project root
- Each workspace is self-contained
- orbit new creates workspaces always under the project root

### 2. .repos/ Is Infrastructure, Not an API Surface
- Agent must not see .repos/
- All repos access goes through orbit commands
- Skill must not expose .repos/ paths or guide the agent to cd into .repos/
- Violating this principle = breaking Layer 2 abstraction

### 3. Metadata Is Cache, Not the Source of Truth
- Metadata can be deleted / rebuilt without data loss
- Missing/stale memo is for reference only; agent is responsible for writing back only to repos it actually added and worked in

### 4. Git-Native First
- Use git natively for operations within the workspace
- orbit only handles operations that cross the workspace<->.repos boundary
- Don't wrap operations in orbit if git can handle them directly
- orbit switch -c is an enhanced option, not mandatory

### 5. Layer Evolution
- Orbit is Layer 2 (Workspace structure management); it does not assume Layer 3 (agent session) or Layer 4 (GUI)
- Skill must be agent-neutral, terminal-agnostic
- No hardcoded assumptions about tmux, screen, or IDE session management

## Skill Required Behaviors

### Environment Awareness (Required)

Agent uses `orbit context path` to quickly determine whether it is inside a workspace:

- **Success (exit 0)** — inside a workspace; output is the workspace directory's absolute path
- **Failure (exit != 0)** — not inside a workspace; do not trigger orbit conventions

Run `orbit context` (full context: workspace name, goal, status, repos + memo) only when complete context is needed.

Detection granularity is **workspace-level only**. Project root path is never exposed (prevents agent from operating on `.repos/` infrastructure); no repo-level detection (use native `git` commands for positioning within a repo).

### Startup Detection (Required)

**Two layers.** In the Claude Code and Qoder plugins, a bundled `SessionStart` hook (startup / resume / compact) detects the workspace and injects its state deterministically, at zero user effort — so the agent knows it is inside a workspace. The hook branches on whether the workspace is a cold start: with **no repos yet** it runs `orbit context --prime` to inject the full preflight (goal, status, done banner, pending jots, and the pool roster — the repos available to `orbit add`) so the agent can orient and choose repos; with **repos already present** it treats the session as a resume and injects only a brief nudge to continue the prior task (goal + status + on-demand pointers), rather than re-dumping the repo roster. Loading the skill's full conventions is still model-driven, so the launch phrase (`orbit start`) remains the reliable way to activate them. In skill-only setups (no plugin hook), that phrase is the only entry point. The detection logic below is identical regardless of layer.

**An injected block is the completed preflight — do not re-fetch it (Required).** When the hook has injected a block — the cold-start `=== PRIME — <name> ===` block or the populated-workspace `Resuming` nudge — the startup preflight has *already run*; its output is in context (the cold-start block **is** the output of `orbit context --prime`, and the resume nudge already carries goal + status). The skill must direct the agent to read that block and proceed straight to the workflow decision (done-check, then goal), and must NOT re-run `orbit context`, `orbit context --prime`, or `orbit repos` to reload what it already holds. Reaching for **plain `orbit context`** at startup is a compounded defect, not a fallback: it dumps every worktree's full memo, a mid-work lookup that is never a session-start action. The agent fetches context itself only when *no* block was injected and the user signals to start (below). **Escalation boundary:** the prime roster already carries every pool repo's name + one-line brief, so any judgment that needs only a name or brief (does repo X exist? what is its rough purpose?) is answered from the block itself — the skill must forbid running `orbit repos` to "confirm" it. Escalation to `orbit repos` / `orbit info <repo>` is warranted only when a field the brief lacks is needed (URL, staleness, memo, entry points).

After the agent launches, **if no context was injected** and the user signals to start working (e.g. `orbit start`), the skill must detect whether it is inside a workspace via `orbit context path`:

1. Command succeeds → run `orbit context --prime` to load the workspace preflight (goal + done banner + pending jots + the pool roster). `--prime` is **lean by design**: the pool roster lists repos available to `orbit add` with a one-line brief each (the cold-start "add menu"), but it does not dump full memos — the agent pulls a repo's memo on demand via `orbit info <repo>` (progressive loading). Plain `orbit context` dumps every workspace worktree's full memo and is a mid-work lookup, not the session-start default
2. **Workspace status is `done` → remind the user first**, before anything else: state that the workspace is already marked done and ask how to proceed (reopen, prune, or start elsewhere). Do not silently continue the workflow on a done workspace
3. Goal is non-empty → begin working based on the goal, entering the Discovery-First workflow
4. Goal is empty → ask the user what to do

**Do NOT check whether `.orbit` files exist directly.** `.orbit` is a metadata cache that may be deleted; orbit commands auto-rebuild it when missing. Directly checking the file bypasses auto-maintenance capability, causing inconsistent behavior depending on whether `.orbit` exists.

Skill description must include the startup trigger phrase (`orbit start`) and the `orbit context path` detection condition.

### Communication Conventions (Required)

The skill must guide the agent to:
- **Name the orbit command it ran and its result** — no silent `orbit context path` / `orbit jot`; the agent states which command it ran and what came back
- **Report facts before structural opinions** — organizational judgments ("this repo shouldn't be in the pool") are offered only when the user asks, and as suggestions, not asserted as facts
- **Keep hard-boundary explanations to one line** — state the limit plus one alternative, don't over-explain

**stderr guidance is the steering channel** (PRINCIPLES.md Principle 8). Any new CLI/hook stderr
line that nudges the agent toward a next action MUST follow the format contract and be registered
in [docs/spec-warnings.md](../docs/spec-warnings.md): shape `orbit: <what happened>: <suggested
workflow>` (two colons, ASCII, `~` for ranges), the workflow clause names the exact next commands
with the `orbit` prefix dropped, and the warning guides without blocking. Hard errors that abort
keep the `orbit: <context>: <message>` diagnostic form and stay out of the registry.

### Discovery-First Workflow (Required)

Every skill must guide the agent to discover before acting:

1. `orbit goal` — understand the workspace objective
2. `orbit repos` — screen: view available repos (name + url + brief), identify potentially relevant candidates
3. `orbit info <repo>` — assess: read the memo card for candidate repos (roles: when/why to add; entry points: where to start), also detects upstream freshness and memo staleness
   - **README fallback = no memo.** When `orbit info` falls back to the README, no memo exists. The README is the repo's unprocessed façade, not decision context — it must not be treated as "enough" to skip `orbit add` or the step 7 exploration
   - **Shortcut:** `orbit context` loads goal + all repos + memo in one call, can replace steps 1–3
4. Decide: based on info, determine whether to add — card answers your question (which repo, where to start) → don't add; need to grep source, trace call chains, modify code → `orbit add`; not in pool → `orbit clone` then add; only need docs → web search. A README fallback is **not** "sufficient" and never justifies "don't add"
   - **Task type does not exempt exploration.** Release, ops, and pure-research tasks explore first too — the default is not "editing code". If full source is genuinely not needed, the agent states that reason explicitly at this step rather than skipping exploration by default
5. **Cold-start sync** — if step 3 showed remoteAhead > 0, run `orbit sync <repo>` now (before add). Agent hasn't started relying on the code yet, so sync cost is lowest. This ensures `orbit add` creates the worktree from the latest pool HEAD
6. `orbit add <repo>` — bring into workspace only repos confirmed in step 4 as needing full source. Worktree starts from pool's current HEAD (latest after sync). `-s` suppresses the memo echo only when context is already held (from step 3 `orbit info`, prime, or a prior session). **Hard rule:** if step 3 showed **no memo** (README fallback), `-s` is forbidden — no memo means zero inherited context, so add without `-s` and explore in step 7
   - **Seed jot invariant:** when the added repo's memo is missing or thin, `orbit add` auto-appends a `[seed]` jot (a durable, compaction-proof placeholder that keeps the queue non-empty so wrap-up/done still force a memo). The `[seed]` prefix marks it as a system instruction, not a real capture — the skill must guide the agent to act on it and **never merge a `[seed]` line into the memo**. A repo stays flagged by `orbit context gaps` until it has a real (non-seed) jot or a real memo
7. **Memo check** — first, pop any residual jot entries from a prior session: `orbit jot <repo> --pop`. Then, based on staleness info from step 3 (recalculated after sync):
   - "memo is N commits behind HEAD" → memo is stale. Read existing memo as a base, check whether recent changes involve structural changes, only incrementally append or correct — don't rewrite. Merge any popped jot entries into the same write. If no structural changes and no jot entries, run `orbit memo <repo> --refresh` to reset the staleness counter (prevents re-evaluation in future sessions)
   - No memo or thin card (doesn't answer both card questions) → `orbit memo <repo> --scaffold` to get template, explore repo (within `explore.paths`) then write. Include any popped jot entries
   - **This step builds understanding *now*** (read code / draft the memo skeleton) — it cannot be deferred to wrap-up. Step 10 only aggregates incremental discoveries on top of it; it is not where first-time exploration happens
   - **Discovery gate:** for every added repo, no target action (edit / branch / push / release / tag) may begin until steps 3–7 are complete for that repo. Jumping from `add` straight to a target action is the failure this gate prevents
8. Branch — raw mode `git checkout -b` (default, most scenarios) or scoped mode `orbit switch -c` (shared branches)
9. Work: use native git commands inside worktrees for development. **jot feeds the card, so jot only what the card needs and lacks** — a role, or an MVP/VIP entry point the card misses or gets wrong → `orbit jot "one-liner"` from within the repo directory. Lightweight queue — no need to read or merge memo during work. If jot warns about accumulated entries (>10), consider aggregating now (see step 10)
   - **What to jot**: only information the card needs and doesn't yet have — a role (why a workspace would pull this repo in) or an MVP/VIP entry point (where to start, and why), about the repo's main branch. **Not**: deep code structure (module internals, conventions, pitfalls, call graphs — out of card scope, belongs in a code-doc); feature-branch changes; temporary debug info; anything the card already says
   - **Need a new repo during work** (e.g., tracing a cross-repo dependency) → return to the discovery flow of steps 2–7: `orbit repos` to screen → `orbit info` to assess → decide whether to add → sync if needed → add → memo check
10. **Wrap-up** — before finishing, aggregate jot entries and assess PR impact. This step is **incremental aggregation only** — it folds discoveries onto the understanding built in step 7, never a place for first-time exploration skipped earlier:
   - **Jot aggregation**: for each repo with jot entries, `orbit jot <repo> --pop` (consume entries) → `orbit info <repo>` (read card) → merge entries into card (stay within the card budget orbit reports: curate, don't append; merge-first rules) → `cat <<'EOF' | orbit memo <repo>` (write back). **Drop any `[seed]` line** — it is a system placeholder, never memo content. Before `orbit done`, `orbit context gaps` must be empty for repos the agent developed (no repo left with only a seed and no real memo)
   - **Writeback is terminal**: the memo merge is the *last* action for that repo this session, so every capture (reflection plus any insight surfacing while reporting to the user) must precede the pop→merge. A jot produced *after* writeback is stranded — this session's aggregation is already closed, so it sits orphaned in the queue until a future session. If a real discovery surfaces post-writeback, re-run pop→merge to fold it in rather than leaving it queued
   - **PR impact assessment**: memo describes the pool repo's stable branch state, not the feature branch state. If the PR changes what the card reflects (a new entry point, or a new role for the repo), include a post-merge refresh suggestion: "`orbit sync <repo> && orbit info <repo>` — update the card if roles or entry points changed"
11. `orbit done --pr <url>` — record PR and mark workspace as reclaimable (see Done Trigger Rules below)
12. `orbit prune` — reclaim completed workspaces (optional)

Don't touch repos you haven't worked in.

Rationale: let the agent make informed decisions before checking out code. Fallback behavior for each step is documented in `docs/spec-knowledge.md` "Progressive Loading Model".

### Full Workflow Example

```
Human: orbit new "fix API" --exec "claude"
                ↓
orbit: implicit init (if needed) → mkdir task-01 → write .orbit → exec claude in task-01/
                ↓
Agent launches, orbit goal → learns the workspace objective
                ↓
Agent: orbit repos → view available repos in pool → determine which are needed
                ↓
Agent: orbit info backend → learn the repo's roles and entry points
                ↓
Agent: orbit add backend && orbit add frontend
                ↓
Agent works: modify code, git push, create PR
                ↓
Agent: cat <<'EOF' | orbit memo backend
# backend

Go REST API, sqlc-generated DB layer.

## Key Entry Points
- `cmd/server/main.go` — server startup
- `internal/service/` — business logic
EOF
                ↓
Agent: orbit done --pr https://github.com/org/backend/pull/42
```

### When Repos Is Empty

Brand new project, `.repos/` just initialized with no repos. Agent uses the skill to ask the user for a repo URL, then executes `orbit clone <url>`. After clone, agent should bring it into the workspace via `orbit add`, understand the code through actual work, then write a valuable memo via `orbit memo`. No special handling needed on the orbit side.

### Commands Exposed by the Skill (Complete List)

| Command | Purpose | Why git alone can't replace it |
|---------|---------|-------------------------------|
| `orbit repos` | View available repo list + URL + brief | Needs to read .repos/.orbit (invisible to agent) |
| `orbit info <repo>` | View per-repo memo + freshness | Needs to read .repos/.<repo>.md |
| `orbit memo <repo>` | Write per-repo memo (stdin) | Needs to write .repos/.<repo>.md |
| `orbit memo <repo> --scaffold` | Output memo template to stdout (no file write, no analysis) | Provides recommended section structure |
| `orbit memo [<repo>] --refresh` | Refresh index entry (url + brief + head) | Needs to read/write .repos/.orbit |
| `orbit add <repo> [--ref <tag/branch>] [-s]` | Bring repo into workspace (`-s` suppresses the memo echo once you've already run `orbit info`) | Needs to create worktree from .repos |
| `orbit jot [<repo>] ["<text>"]` | Push a discovery to the jot queue | Needs to write workspace .orbit (invisible to agent) |
| `orbit jot [<repo>] --pop` | Pop all jot entries (consume + delete) | Needs to read/clear workspace .orbit |
| `orbit switch [-c] [repo] <name>` | Switch/create tracking branch | Needs prefix naming convention + upstream config |
| `orbit clone <url>` | Add repo when not in pool | Needs to write .repos/ + generate metadata |
| `orbit sync [repo...] [--force] [--branch <branch>]` | Sync pool repo to upstream latest | Needs to operate on repos inside .repos/ (ff/reset/switch branch) |
| `orbit done [--pr]` | Mark task complete | Workspace-level semantic, not a git concept |
| `orbit status` | View workspace status | Aggregates multi-repo branch/ahead/behind |
| `orbit goal` | Read/set workspace objective | Reads/writes workspace/.orbit goal field |
| `orbit context [<key>] [--prime] [--json]` | Full context or single key query (workspace/path/goal/status/gaps; `gaps` = repos with no real memo — thin + no non-seed jot); `--prime` = lean startup preflight (pool roster + done banner + pending jots; full memos via `orbit info` on demand) | Aggregates goal + repos + memo, needs to read .repos/ |
| `orbit prune` | Reclaim completed workspaces | Cross-workspace cleanup of worktrees + branches |
| `orbit config [<key> [<value>]]` | Read/set project configuration | Needs to read/write .repos/.orbit |
| `orbit doctor` | Environment health check | Checks git/bash version + .repos/ integrity |

### Operations the Skill Should NOT Expose
- Configuring push target — agent uses `git remote set-url --push origin <url>` inside the worktree
- Pushing code — agent uses `git push` inside the worktree
- Creating plain branch (raw mode) — agent uses `git checkout -b` inside the worktree
- Any native git operation — agent uses git directly

## Metadata Update Constraints

**Memo is a pull-decision card, not documentation.** Content written via `orbit memo` is part of the workspace system, reused by subsequent agent sessions, and is not subject to general "don't create documentation" rules. A card answers exactly two questions: **when/why to add this repo** (its roles — plural, unbounded) and **how to use it** (the MVP/VIP entry points to start from — also plural). Deep code structure is out of scope; it belongs in a dedicated code-doc, not the card.

### Memo Writeback Rules

**Write back on demand** — scope is limited to repos you actually `orbit add`-ed and worked in, but within that scope you must actively maintain them. Memo describes the pool repo's stable branch (main branch) state, not feature branch state.

**Line bounds (project config)**: `memo.maxLines` (default 16) is a hard upper ceiling; `memo.minLines` (default 4) is the soft floor below which the card counts as thin/absent. The ceiling is a **compress trigger, not a target** — the card is a decision card, not a survey.

**Merge-first**: existing card is accumulated knowledge from prior sessions, with status equivalent to inherited session context. When `orbit info` returns real memo content (not a README fallback), use the existing content as a base for incremental edits — correct factual errors, add a role or entry point; don't rewrite content that's still accurate. Curate (don't append) once past the ceiling.

**Memo Lifecycle:**

**Creation (cold start)**: write when card is missing or below the floor. Write the roles + the MVP/VIP entry points, nothing more — a decision card, not completeness. Cold-start exploration is bounded to `explore.paths` (a `path:depth` list, default root at depth 1).
- **Missing** → must write. Use `orbit memo <repo> --scaffold` to get template, explore then write the actual card
- **Thin** (doesn't answer both card questions) → must upgrade
- **Stale** (`orbit info` shows stale warning) → check recent changes; update if roles/entry points changed
- **Answers both questions, no structural changes** → leave alone

**Incremental update (during work)**: use `orbit jot "one-liner"` to record discoveries as they happen — lightweight, no memo read/merge needed. At natural breakpoints (wrap-up, overflow warning from jot), aggregate: `orbit jot <repo> --pop` → `orbit info <repo>` (read card) → merge entries into card → write back.
- **Correct**: card has errors or outdated paths → edit in place
- **Add**: a newly discovered role, or an entry point worth starting from → add it
- **Leave alone**: content that's still accurate should not be rewritten, even if you'd phrase it differently
- Curate against the ceiling before writing

**Compression (when past `memo.maxLines`)**: curate — don't append. Keep what is costly to rediscover (why a role exists, a non-obvious entry point); drop what a quick `ls`/grep would reveal anyway. Brief (first line) is never compressed.

**Wrap-up (before done)**: aggregate remaining jot entries into card (pop → read → merge → write), then assess PR impact scope. Agent does not write memo on a feature branch. If the PR involves structural changes, prompt the user to refresh after merge: "`orbit sync <repo> && orbit info <repo>`"

Don't touch repos you haven't worked in; don't proactively scan or patch the state of other repos in the pool.

**Memo Content Quality Requirements**:
- First line after the title is the brief (plain text, ≤ 120 characters, one sentence describing repo purpose)
- Prefer specifics — a concrete path with why/when beats a generic overview
- `orbit memo <repo> --scaffold` outputs the card structure (roles + how to use); agent fills both, never leaves TODO placeholders

**Prohibited behaviors**:
- Scanning the entire codebase to produce a summary without having worked in the repo
- Dumping README / PRD full text or large excerpts as memo content
- Padding the card with deep code-structure detail (that's a code-doc's job, not the card's)
- Full rewrite of a still-accurate card (should be incremental edits)

### Sync Decision Rules

Sync (`orbit sync`) advances pool HEAD, causing memoBehind to increase — there is cascading invalidation between sync and memo. The following rules balance code freshness and memo maintenance cost.

**Core principle**: sync does not trigger memo refresh. Memo validity is determined by actual needs during work, not driven by commit distance. (Model definition in `docs/spec-knowledge.md` "Relationship between Sync and Memo Cascading")

**Two phases:**

**Cold start (before add)**: `orbit info` detects remoteAhead > 0 → run `orbit sync <repo>` before `orbit add` (agent hasn't started relying on the code yet, sync cost is lowest). This ensures the worktree is created from the latest pool HEAD. After sync, check memo staleness — memoBehind now reflects the gap against the code the agent will actually work with.

**During work**: agent does not proactively propose sync. `orbit sync` updates the pool repo, not the active worktree — syncing mid-work has no direct effect on the agent's feature branch and disrupts workflow. Upstream changes are resolved at PR time (merge/rebase before merge). If `orbit info` shows remoteAhead > 0 during work, this is informational only.

**Wrap-up (before done)**: no additional upstream checks. PR impact assessment (see "Wrap-up" in Memo Writeback Rules) already covers this: if the PR involves structural changes, prompt the user to `orbit sync && orbit info` after merge.

### Scaffold Generation (`orbit memo <repo> --scaffold`)

`--scaffold` outputs a pure template to stdout (no file write, no code analysis): the card structure — title + brief, `## When to add (roles)`, `## How to use` — with TODO placeholders. After the agent explores the repo (within `explore.paths`):
- Fill both sections; list every role and every MVP/VIP entry point that matters (don't leave TODO placeholders)
- Keep it a decision card — don't add deep code-structure sections; that's a code-doc's job
- Write via `cat ... | orbit memo <repo>`

### Done Trigger Rules

`orbit done` marks the workspace as reclaimable. The agent must know when to trigger it.

**Proactive trigger (agent-initiated)**: workspace has a goal → agent has completed the work (PR created, code committed, tests passing) → run wrap-up sequence (jot aggregation → PR impact assessment) → `orbit done --pr <url>`.

**User-initiated**: workspace has no goal (free exploration), or user explicitly says done/finished → agent runs wrap-up then `orbit done`.

**Session ending**: if the session ends before done, agent aggregates remaining jot entries into memo and suggests the user run `orbit done` — do not auto-done, as work may be incomplete.

**Gap gate**: `orbit done` warns (does not block) for repos still flagged by `orbit context gaps` — thin memo with only a `[seed]` placeholder and no real jot. This is the CLI backstop that fires even when hooks are absent and the agent skipped the wrap-up memo. The seed jot written at `orbit add` guarantees this warning triggers for any repo added no/low-memo.

**Not a trigger**: pausing, switching topics, or intermediate work stages do not trigger done.

## Push Behavior

Orbit takes no stance on git push workflow — that is the developer's (or automation system's) call, and the permission mode governs whether any command prompts. The skill documents *mechanics*, not policy: it must not gate pushes behind a push-safety flag or a confirmation dialog. (Discovery-first before high-impact actions is already covered by the Discovery gate in the Discovery-First Workflow, on knowledge grounds, not as a push-approval policy.)

### Branch Mode Choice (Must Be Documented)

The skill must give the agent a basic rule for picking a branch mode:
- **Default = raw** (`git checkout -b <name>`) for a fresh, workspace-local branch name.
- **Reach for scoped** (`orbit switch` / `orbit switch -c`) when the branch is an **existing/shared** branch, or when the name could **easily conflict** across workspaces (multiple workspaces touching the same repo) — scoped branches are namespaced per workspace.
- **Fallback (the "already used by worktree" trap):** git refuses to check out a branch already checked out in another worktree — the pool holds each repo's base branch, and other workspaces may hold shared branches. When `git checkout <name>` or `git switch <name>` aborts with `already used by worktree`, the skill must direct the agent to run `orbit switch <name>` instead: it creates a per-workspace `ws/<workspace>/<name>` branch tracking `origin/<name>` (a distinct local name that never collides), and `git push` still targets `origin/<name>`.

### Push Behavior by Mode (Must Be Documented)

Skill documentation must inform the agent of the push differences between the two modes:

**Raw mode (default)**:
- After `orbit add`, manage branches with plain git
- Branch name is your choice, no prefix needed
- Push: `git push origin <branch-name>` (explicit target required)

**Scoped mode (when branch isolation is needed)**:
- Created using `orbit switch -c <name>`
- Local branch: `ws/<workspace>/<name>` (managed by orbit)
- Remote branch: `origin/<name>` (clean, no prefix)
- Push: `git push` works directly (upstream auto-configured)

Skill does not need to explain internal mechanics (prefix stripping, push.default configuration), only inform the agent of behavioral differences.

## Anti-Pattern Checklist (Must Be Warned in Skill)

1. **Directly accessing .repos/** — breaks Layer 2 boundary
2. **Assuming the agent understands git config internals** — use behavioral descriptions instead of config details
3. **Agent running orbit new inside a workspace** — new workspaces are created at project root, but the agent's scope is the current workspace and it cannot switch to the new workspace. `orbit new` should be initiated by humans
4. **Forcing scoped mode** — raw mode is a perfectly valid choice
5. **Scanning the entire codebase to write descriptions without having worked in the repo** — memo should arise naturally from actual work, not as a standalone summarization task
6. **Writing memo for repos you haven't touched** — memo writeback is on-demand; only manage repos you added and worked in
7. **Copying README/PRD content into memo** — the card answers two questions (roles + how to use), not a documentation copy
8. **`git checkout master`/`main` inside a worktree** — the pool holds the base branch, so this aborts with `already used by worktree`; use `orbit switch master` to sync the baseline, then branch
9. **Merging a `[seed]` line into a memo** — `[seed]` jots are system placeholders/instructions written by `orbit add` for no/low-memo repos; act on them, then drop them, never paste them into memo content

## Skill Document Structure Requirements

Each agent's SKILL.md must include:
- Startup Detection logic (`orbit context path` → `orbit context --prime` → act based on goal)
- Discovery-First workflow (with command examples)
- Two branch mode explanations (Raw + Scoped)
- Anti-pattern warnings (covering at least the 5 items above)
- Command quick-reference table (only exposed commands)

When referencing detailed specs, point to: `docs/spec-*.md` series (knowledge system references point to `docs/spec-knowledge.md`)

## Eval Maintenance Requirements

Each agent's `evals/evals.json` must be maintained in sync with SKILL.md.

### Coverage Principles

- **Every exposed command must have at least one eval covering it.** All commands in the "Commands Exposed by the Skill" table should appear in evals
- **Add evals when adding new commands or options.** Don't modify SKILL.md without updating evals
- **Remove corresponding evals when commands are deleted or renamed.** Evals referencing non-existent commands (e.g., the removed `branch --tracking`, now `switch`) must be removed or rewritten

### Eval Writing Standards

- `prompt`: simulate a natural language user request; don't directly mention orbit command names (tests whether the agent can map needs to the correct command)
- `expected_output`: describe the orbit command and key behaviors the agent should use, with commands marked in backticks
- Each eval tests one independent scenario; avoid stacking too many commands in a single eval
- Command syntax in evals must exactly match the SKILL.md command map

### Checklist

When the command system changes, check in this order:
1. Whether `docs/spec-commands.md` has new/modified/deleted commands
2. Whether SKILL.md command map has been synced
3. Whether `evals/evals.json` covers the changed commands
4. Whether existing evals reference deprecated commands or options

## References

- Design principles and key decisions: `PRINCIPLES.md`
- Directory structure: `docs/spec-directory.md`
- Branching strategy: `docs/spec-branching.md`
- Command system: `docs/spec-commands.md`
- Metadata design: `docs/spec-metadata.md`
- Knowledge system: `docs/spec-knowledge.md`
- Lifecycle management: `docs/spec-lifecycle.md`
- Usage examples: `USAGE.md`
- Tool comparison: `docs/comparison.md`
