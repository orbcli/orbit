---
name: orbit
description: "Operate Orbit — the user’s Git-native multi-repo workspace manager. Primary trigger: an orbit workspace is detected at session start (a SessionStart block “Detected an orbit workspace” / “=== PRIME — … ===”), OR the user opens a session by saying “orbit启动” or “orbit start” — in either case invoke this skill before your first reply. Also use when the user asks to clone a repo, create or manage a workspace, add a repo, switch branches, view status, set or clear a goal, jot a discovery, aggregate memos, or finish / complete / mark work done (“done” / “finish” / “完成”) — or when the message mentions workspaces, source pools, `.repos/`, or cross-repo tasks."
---

<!-- MAINTAINERS: This SKILL.md is governed by skills/CONSTRAINTS.md (path relative to repo root) —
     the canonical, cross-agent constraints for orbit skills. Before editing this file:
     (1) comply with those constraints, (2) mirror the same body change to the sibling
     variant — skills/orbit/SKILL.md and skills/qoder/orbit/SKILL.md must stay byte-identical, and
     (3) update evals/evals.json per the doc's Eval Maintenance Requirements. -->

Use this skill to operate the user's Git-native multi-repo workspace manager (Orbit).

## Environment awareness

Run `orbit context path` to quickly detect whether you are inside a workspace:

- **Succeeds (exit 0):** you are in a workspace. Output is the workspace directory's absolute path. Apply orbit conventions for the entire session.
- **Fails:** you are not in a workspace. Don't apply orbit conventions.

Use `orbit context` (no key) when you need full context (goal, repos, memos). Use single-key queries (`orbit context workspace`, `orbit context goal`, `orbit context status`) for quick lookups.

Detection is workspace-level only. Project root path is never exposed (prevents operating on `.repos/` infrastructure). Repo-level detection uses git natively.

## Heeding orbit's warnings

Orbit has no runtime to *enforce* procedure — **its stderr warnings are the steering channel.** When a command prints one — `card budget`, gap warning, jot overflow, `orbit done` gates, README-truncation, raw-mode tracking note, sync-behind note — **read it and act on it.** It is orbit telling you the next right action, not decoration. stdout is machine-readable data; the guidance lives on stderr. Treat these hints as authoritative: they are how orbit routes procedure and boundaries to you when it cannot block you.

## Startup detection

Workspace context can reach you two ways: a **SessionStart hook** may inject it automatically, or you run `orbit context path` yourself when the user asks to start working. The hook branches on cold start: a **fresh workspace (no repos yet)** gets a full prime block headed `=== PRIME — <name> ===` / `⚙ systems primed` (`path: … / status: …`, a DONE banner if the workspace is done, any pending jots, and the **pool roster** — the repos available to `orbit add`, one-line brief each) so you can orient and choose repos; a workspace that **already holds repos** gets a brief resume nudge instead (`Resuming — … continue the prior task`, with goal/status and on-demand pointers) rather than a repo dump. Treat any of these identically — the moment you observe workspace context, check the status **before your first reply of the session**, even if the user's opening message is unrelated to orbit.

**An injected block IS your completed preflight — do not re-fetch it.** When either block is present, the hook has *already run* the startup preflight for you: the cold-start block is the output of `orbit context --prime`, and the resume nudge already carries goal + status. Read what's there and go straight to the workflow decision (done-check, then goal) — do NOT run `orbit context`, `orbit context --prime`, or `orbit repos` to "load" context you already hold. Reaching for **plain `orbit context`** at startup is a compounded error: it dumps every worktree's full memo, a mid-work lookup that is never a session-start action. You fetch context yourself only in the no-injection path below.

The prime roster already carries every pool repo's name + one-line brief, so any judgment that needs only a name or brief — does repo X exist? what's its rough purpose? — is settled from the block itself; do NOT run `orbit repos` to "confirm" it. Escalate to `orbit repos` / `orbit info <repo>` only when you need a field the brief lacks (URL, staleness, memo, entry points).

`status: done` is the workspace's **lifecycle state** — it means the workspace was already marked complete via `orbit done`. It is NOT a loading/progress indicator; do not misread it as "context finished loading".

When no context was injected and the user asks to start working, run `orbit context path` to detect whether you are in a workspace:
1. If the command succeeds, run `orbit context --prime` to load the startup preflight — goal, done status, any residual jots, and the **pool roster** (repos available to `orbit add`, one-line brief each — the cold-start "add menu"). `--prime` is lean by design: it lists the pool by name + brief and does **not** dump full memos — pull a repo's memo on demand with `orbit info <repo>` once you engage it. (Plain `orbit context` dumps every workspace worktree's full memo, which is why it's a mid-work lookup, not a session-start default.)
2. **If the workspace status is `done`, remind the user first** — before doing anything else (this applies to your very first reply of the session, whether the status came from the injected hook block or from `orbit context --prime`), tell them the workspace is already marked done and ask how they want to proceed (reopen work, prune, or start elsewhere). Do not silently continue the workflow on a done workspace.
3. If the goal is non-empty, proceed with the workflow based on the goal. If the preflight listed pending jots, fold them into memo and pop them per Workflow step 7 as you get started.
4. If the goal is empty, ask the user what they want to accomplish.

Do NOT check for `.orbit` files directly — metadata files are cache and may be absent. Orbit commands auto-recreate them when needed.

## What this skill assumes

- The `orbit` command is available on PATH (installed via the Orbit repo's `install.sh`).
- The project root is identified by a `.repos/` directory.
- Agents are launched from a workspace directory (not project root).
- `.repos/` is internal infrastructure — never `cd` into it or read/write files there directly.

If the `orbit` command is not found, tell the user to install the runtime with `! curl -sL https://raw.githubusercontent.com/orbcli/orbit/main/install.sh | bash`.

## Core concepts

- **Project root**: directory containing `.repos/`
- **Repos**: `.repos/<repo>/` — internal repos, only accessed via orbit commands
- **Workspace**: `<root>/<workspace>/` — task-scoped directory containing worktrees
- **Worktree**: `<root>/<workspace>/<repo>/` — actual development directory

## Workflow

These steps describe the work itself, independent of who performs it. Run them yourself, or delegate the exploration path (screen → assess → add → work + jot) to workers — see "Delegating to sub-agents" below. Lifecycle and aggregation (`memo`, `done`) always stay with you.

1. **Read goal first.** Run `orbit goal` to understand what this workspace is for.
2. **Screen.** Run `orbit repos` to see available repos (name + url + brief). Identify candidates relevant to your goal.
3. **Assess.** Run `orbit info <repo>` for each candidate — the memo card: the repo's roles (when/why to add) and entry points (where to start). Also detects upstream freshness and memo staleness.
   - **README fallback = no memo.** When `orbit info` falls back to showing the README, it means **no memo exists**. The README is the repo's unprocessed façade, not decision context — never treat it as "enough" to justify skipping `orbit add` or the step 7 exploration.
   - **Shortcut:** `orbit context` combines steps 1–3 into a single call (goal + all repos + memos).
4. **Decide.** Based on info: memo card gives enough context (the repo's roles and entry points answer your need) → don't add. Need to grep source, trace call chains, or modify code → `orbit add`. Repo not in pool → `orbit clone` then add. Only need docs → web search. A README fallback (step 3) is **not** "enough context" — it never justifies "don't add".
   - **Task type doesn't exempt you from exploring.** Release, ops, and pure-research tasks explore first too — the default mental model is not "editing code". If you judge full source truly isn't needed, state that reason explicitly here rather than skipping exploration by default.
5. **Cold-start sync.** If step 3 showed remoteAhead > 0, run `orbit sync <repo>` now — before add. Agent hasn't started relying on the code yet, so sync cost is lowest. This ensures `orbit add` creates the worktree from the latest pool HEAD. **Scope:** `sync` fast-forwards the *pool* repo (`.repos/<repo>`) only — it does **not** move a worktree you've already checked out. If a worktree tracks the branch you synced, it's now behind the pool; bring it up to date with native git if you want. Don't re-run `orbit sync` expecting the worktree to advance.
6. **Add repos.** Run `orbit add <repo>` only for repos that need full source (from inside a workspace directory). Worktree starts from pool's current HEAD (latest after sync). Pass `-s` when you already hold enough context to justify the add — from `orbit info` in step 3, the memo surfaced at prime, or a prior session: `orbit add <repo> -s`. Plain `orbit add` (no `-s`) echoes the memo as a safety net — reach for it only when adding without that context; seeing the memo dump means you added blind and should confirm you actually need the full source. **Hard rule:** if step 3's `orbit info` showed **no memo** (README fallback), `-s` is forbidden — no memo means zero inherited context, so add without `-s` and explore in step 7.
   - **Seed jot on no/low memo.** When you add a repo whose memo is missing or thin, `orbit add` auto-appends a `[seed]` jot — a durable placeholder that survives compaction and keeps the queue non-empty so wrap-up/done still force a memo. It is an *instruction to you*, not a discovery: act on it in step 7, and **never merge a `[seed]` line into the memo**. It stays in the queue (and keeps the repo flagged by `orbit context gaps`) until you capture a real jot or write a real memo.
7. **Memo check.** First, pop any residual jot entries from a prior session: `orbit jot <repo> --pop` (a `[seed]` line here is a system instruction, not a discovery — either "no real memo yet: explore and write one" or "card over budget: curate it back down"; act on its text, then discard the line). Then, based on staleness info from step 3 (recalculated after sync):
   - **"memo is N commits behind HEAD"** → memo is stale. Read the existing memo first, then skim recent changes. If structure changed (new entry points, renamed modules, changed deps), incrementally update — add or correct, don't rewrite. Merge any popped jot entries into the same write. If no structural changes and no jot entries, run `orbit memo <repo> --refresh` to reset the staleness counter (prevents re-evaluation in future sessions).
   - **No memo** or **thin card** (doesn't answer both card questions) → explore the repo and write one now, within the `explore.paths` scope orbit gives you (the seed jot names it — don't survey the whole tree). Use `orbit memo <repo> --scaffold` for the template. Capture the repo's roles + the MVP/VIP entry points while you're orienting. Include any popped jot entries.
   - **This step builds understanding *now* — it cannot be deferred to wrap-up.** Reading the code and drafting the memo skeleton happen here, before any target action. Step 10 only aggregates incremental discoveries on top of the understanding you build here; it is not where exploration first happens.
   - **Discovery gate — applies to every added repo.** Do not begin *any* target action — edit, branch, push, release, or tag — until steps 3–7 are complete for that repo. Jumping from `add` straight to a target action is the exact failure this gate prevents.
8. **Branch.** Before making changes, create a feature branch in each repo you'll modify:
   - **Raw mode** (default, most cases): `git checkout -b <branch>` — use when the branch is unlikely to conflict with other workspaces.
   - **Scoped mode**: `orbit switch -c <name>` — use when working on shared/public branches where multiple workspaces may touch the same repo.
9. **Work.** Use standard git commands inside worktrees. **jot feeds the card, so jot only what the card needs and doesn't have yet** — a role the card doesn't list, or an MVP/VIP entry point the card misses or gets wrong. Run `orbit jot "one-liner"` from within the repo directory — lightweight, no need to read or merge memo. If jot warns about accumulated entries (>10), consider aggregating now (see step 10). **Jot on others' behalf (fallback):** if a finding about a repo you added or worked in comes from a source you didn't brief on orbit (a custom agent, or non-agent external research), run `orbit jot <repo> "discovery"` yourself when you receive it. The primary path is to brief that agent so it jots on its own (see Delegating).
   - **What to jot**: only information the card is missing and needs — a **role** (why a workspace would pull this repo in) or an **MVP/VIP entry point** (the file/dir to start from, and why), about the repo's main branch, that isn't already captured. Reviewing a diff or refactoring counts as reading code: a role or entry point you learn while traversing the base (main-branch) structure is jottable even when the change itself is not. **Not**: deep code structure (module internals, conventions, pitfalls, call graphs) — that is out of card scope and belongs in a code-doc, not memo; not feature-branch changes; not debug notes; not anything the card already says.
   - **Jot triggers (event-driven — don't wait for wrap-up).** Jot the moment you realize (a) this repo also serves a role the card doesn't list, or (b) the real entry point for a task differs from — or is absent in — what the card names. If the discovery isn't a role or an entry point the card needs, it isn't a jot.
   - **Resume/compact sessions still jot.** A "continue the prior task, don't re-survey" resume nudge does not suppress discovery capture, and a compact can wipe your mental "to-jot" note — so jot findings as they surface, even mid-refactor after a compact.
   - **Need another repo?** (e.g., tracing a cross-repo dependency) → go back to steps 2–7: `orbit repos` to screen → `orbit info` to assess → decide whether to add → sync if needed → add → memo check. This cross-repo branch is a prime thing to delegate — a worker runs the same screen → assess → add loop autonomously via its briefing (see "Delegating to sub-agents").
10. **Wrap-up.** Before finishing, aggregate jot entries and assess PR impact. This step is **incremental aggregation only** — it folds discoveries onto the understanding built in step 7; it is never where first-time exploration you skipped earlier gets done:
   - **Reflect first**: before popping, review what you learned this session about repos you added or worked in. If any structural insight never made it into a jot, jot it now, then continue. Keep scope to repos you added or worked in; do not sweep repos you only read via `orbit info`.
   - **Jot aggregation**: for each repo with jot entries, run `orbit jot <repo> --pop` to consume entries, then `orbit info <repo>` to read current card, merge entries in — staying within the card budget orbit reports (curate, don't append) and following merge-first rules — write back via `cat <<'EOF' | orbit memo <repo>`. **Drop any `[seed]` line** — it is a system placeholder, never memo content. Run `orbit context gaps` to confirm no repo you developed is left with no real memo before `orbit done`.
   - **Writeback is terminal.** Merging into memo is the *last* action for that repo — capture everything *before* the pop→merge, including insights that surface while you draft your report to the user. A jot made after writeback is stranded: this session's aggregation is already closed, so it sits orphaned in the queue until a future session. If a genuine discovery surfaces post-writeback, re-run pop→merge to fold it in — don't leave it queued.
   - **Memo quality gate**: for each repo you actually explored this session (read its code/structure, not just skimmed), run `orbit info <repo>` and judge whether the card answers both questions — its roles, and the MVP/VIP entry points — by substance, not line count (an accurate thin card is fine; orbit's card budget is an append-drift guard, not a quota to fill). If it doesn't and you understand the repo well enough, upgrade it now (cold-start write per "Upgrade thin cards"); if you didn't explore deeply enough to write accurately, do NOT pad — report instead and let the user decide. Don't `orbit done` leaving a repo you actively developed in with a known-thin card unacknowledged.
   - **PR impact assessment**: memo describes the pool repo's stable (main) branch, not your feature branch — do NOT update memo based on feature branch state. If your PR introduces changes the card would need to reflect (a new entry point, or a new role for the repo), include a post-merge memo refresh suggestion: "After merge: `orbit sync <repo> && orbit info <repo>` — update the card if roles or entry points changed."
11. **Mark done.** When the workspace has a goal and you've completed the work (PR created, code committed, tests passing), run the wrap-up sequence from step 10, then `orbit done --pr <url>`. When the workspace has no goal, only run `orbit done` when the user explicitly asks.
   - **Session ending before done**: aggregate jot entries into memo, then suggest the user run `orbit done` — do not auto-done, as work may be incomplete.
12. **Prune.** `orbit prune` cleans up done workspaces (branch cleanup + directory removal).

Repos you didn't add or work in are not your responsibility.

## Delegating to sub-agents

Orbit exists to support cross-repo work, so a sub-agent should follow a thread across repos **autonomously** — not round-trip to you for every repo it needs. But sub-agents (Agent/Task tool) do NOT load this skill; they only see the prompt you write. So the split is by **operation nature** (not by "who loaded the skill"), and you must **brief** workers on the conventions they can't see.

**What a worker may do — the whole exploration path.** A sub-agent may autonomously `orbit repos` (screen), `orbit info` (assess), `orbit add -s` (pull source when the memo isn't enough), `orbit switch`, read/edit/commit inside worktrees, and `orbit jot` discoveries. `orbit add` is *guarded creation* — it fails cleanly on collision (worktree exists / branch checked out elsewhere), so it is safe to delegate.

**What stays with you — lifecycle, aggregation, pool.** Keep `new`, `done`, `goal`, `memo` writeback (read-modify-write — concurrent writers lose updates), and pool / cross-workspace ops `clone` / `sync` / `config`. Workers report these needs back instead of running them.

**Capture vs aggregate.** Workers `jot` during work (append-only, concurrency-safe); you fold jots into `memo` at wrap-up (step 10). This is how knowledge discovered inside a worker's context survives after that context is gone.

**Brief custom agents too — don't default to proxying.** No sub-agent loads this skill; jot reaches any of them only through the briefing you paste in. So when you delegate repo-touching work to a domain/custom agent (research, design, ops), add the jot lines from the template above to its prompt as well — then it jots its own structural findings about repos it added or worked in, same as a built-in worker. Proxy is only the fallback: for findings from an agent you didn't brief, or from non-agent external research, jot them yourself (step 9) and sweep for misses in the wrap-up reflection (step 10).

**Concurrency is your job.** Serial delegation (one worker at a time) has no race — a lone worker can do almost anything you can. When you fan out **parallel** workers, partition by repo so their mutations stay disjoint; converge writes (`memo`, `done`) serially yourself afterward.

**Brief every worker.** Workers can't see this skill, so paste a filled-in briefing into each orbit sub-agent prompt:

```
You are working in an Orbit workspace. The `orbit` CLI is on your PATH.
Workspace: <ws-name> at <ws-abs-path>. Repos already added: <repo>=<worktree-abs-path>, ...

Following a thread into another repo (do this yourself, don't ask me):
- `orbit repos` lists the pool; `orbit info <repo>` shows its memo — READ IT FIRST.
- Only if the memo isn't enough (you must grep source / trace calls), run
  `orbit add <repo> -s` from <ws-abs-path>, then work in <ws-abs-path>/<repo>.

Recording knowledge (the moment you find it, before it's lost):
- `orbit jot <repo> "one-liner"` ONLY for what the repo's memo card needs and lacks:
  a role (why a workspace would pull this repo in) or an MVP/VIP entry point (where to
  start, and why), about the repo's main branch.
- NOT deep structure (module internals, conventions, pitfalls, call graphs — out of card
  scope), NOT feature-branch changes, NOT debug notes.
- If you cannot run orbit, put the same items under a "## Discoveries" heading in your report.

Do NOT run: orbit memo / sync / done / new / goal / clone / config — report those needs to me.

Report back: findings, any repos you added, and your Discoveries list.
```

## Command map

```bash
# Repos management (work from anywhere in project)
orbit clone <url> [--push <fork-url>] [--name <repo>] [--branch <branch>]
orbit repos [--json]
orbit info <repo> [--json]
orbit memo [<repo>] [--refresh|--scaffold]
orbit sync [repo...] [--force] [--branch <branch>]  # updates the POOL repo only — NOT your worktree

# Workspace lifecycle (from inside a workspace)
orbit new ["<goal>"] [--name <name>] [--exec "<cmd>"] [--no-goal]
orbit add <repo> [--ref <tag/branch>] [-s|--silent]
orbit switch [-c] [repo] <name>
orbit jot [<repo>] ["<text>"]     # push a discovery to the jot queue
orbit jot [<repo>] --pop [--json]  # pop all entries (consume + delete)
orbit done [--pr <url>...] [--json]
orbit prune [workspace] [--older <dur>] [--dry-run] [--force] [--verify]

# Status (from workspace or root)
orbit status [workspace] [--json]
orbit goal ["text" / --clear]
orbit context [<key>] [--prime] [--json]   # key: workspace, path, goal, status, gaps; gaps = repos with no real memo (thin + no real jot); --prime = startup preflight (done banner + pending jots)

# Configuration & diagnostics
orbit config [<key> [<value> | --unset]]
orbit doctor
```

## Branch modes

> **Don't `git checkout master`/`main` inside a worktree.** The pool already has the base branch checked out, so git aborts with `fatal: '<branch>' is already used by worktree at '.repos/<repo>'`. To branch off the latest baseline, sync through orbit first: `orbit switch master` (creates a workspace-level tracking branch, fetching remote) → `git pull --ff-only` → `git checkout -b feature/x`. This starts the new branch from the synced remote HEAD, not stale local code.

**Which mode?**
- **Default = raw** (`git checkout -b <name>`) for a fresh, workspace-local branch name.
- **Reach for scoped** (`orbit switch` / `orbit switch -c`) when checking out an **existing/shared** branch, or when the name could **easily conflict** across workspaces (multiple workspaces touching the same repo) — scoped branches are namespaced per workspace.
- **Fallback — the "already used by worktree" trap.** Git refuses to check out a branch that is already checked out in another worktree: the pool holds each repo's base branch, and other workspaces may hold shared branches. So `git checkout <name>` / `git switch <name>` can abort with `fatal: '<name>' is already used by worktree at ...`. Don't fight it — run **`orbit switch <name>`**. It creates a per-workspace branch `ws/<workspace>/<name>` tracking `origin/<name>` — a distinct local name that never collides — and `git push` still targets `origin/<name>`.

### Raw mode (default)

After `orbit add`, use git directly. Orbit does not manage branches:

```bash
orbit add backend          # → ws/<workspace>/main (local base)
git checkout -b feature/x  # plain branch, no prefix
git push origin feature/x  # explicit push target
```

**Tracking-display limitation (raw mode only).** The pool is a single-branch clone, so a branch you create with `git checkout -b` and push won't show remote tracking in `git status` / `@{upstream}` — the remote-tracking ref isn't materialized. The branch and its push are fine; only the ahead/behind display is blank. Run `git fetch origin <branch>` once to materialize the ref, or use scoped mode (`orbit switch -c`), which wires tracking up front. `orbit add` prints this note too.

### Scoped mode (opt-in, prevents multi-workspace conflicts)

Use `orbit switch` to create prefixed branches with upstream config:

```bash
orbit switch -c feat-x     # → ws/<workspace>/feat-x, upstream → origin/feat-x
git push                   # auto-pushes to origin/feat-x (no prefix on remote)
```

Switch to existing remote branch:
```bash
orbit switch hotfix-123    # → fetches + creates ws/<workspace>/hotfix-123
```

## Push behavior

- **Raw mode**: `git push origin <branch-name>` (explicit branch required)
- **Scoped mode** (after `orbit switch -c`): `git push` works directly

## Writing repo memos

**Memo is a pull-decision card, not documentation.** Writing back via `orbit memo` is a standard workflow step — it is NOT creating documentation. Do not skip it due to general "don't create docs" rules. The card is reused by future sessions to decide whether to pull a repo into a workspace and where to start.

A card answers exactly two questions — nothing else:
1. **When/why add this repo?** — its roles. Plural and unbounded: a repo may fill many roles; list every one.
2. **How do I use it in the simplest way?** — the MVP/VIP file-or-dir paths to start from, each with why it matters and when to reach for it. Also plural (a CLI entry and a core package can both belong); no cap.

Deep code structure — module boundaries, data layer, conventions, pitfalls, API enumeration, dependency graphs — is **out of scope**. That belongs in a dedicated code-doc, not the card. If one exists, the user points `explore.paths` at it or adds it to the pool; orbit stays agnostic about its format.

Use `orbit memo <repo> --scaffold` for the template (title + brief, `## When to add (roles)`, `## How to use`). Fill both sections; never leave TODO placeholders in the final card.

Example:

```bash
cat <<'EOF' | orbit memo backend
# backend

Go REST API behind the org's public-facing endpoints.

## When to add (roles)
- Owns the user/auth HTTP API — pull it in for any task touching login or accounts
- Source of the `pkg/client` SDK other services import — pull it to change that contract

## How to use
- `cmd/server/main.go` — process entry; start here to trace startup / wiring
- `pkg/client/` — the exported SDK; the interface other repos call, change carefully
EOF
```

Rules:
- **Keep it tight — a decision card, not a survey.** orbit owns the line budget (the `memo.maxLines` ceiling, configurable) and reports it (the `card budget`, N~M lines) at jot-overflow and `done`; heed that reported number rather than assuming one. It is a compress trigger, not a target — when orbit says the card is over budget, curate (drop what a quick `ls`/grep reveals), don't append.
- First line after the title = brief (plain text, ≤ 120 chars, one sentence stating repo purpose); never compressed.
- Prefer specific over vague — concrete paths beat generic descriptions.
- NOT a copy of README or PRD — write what helps the next agent decide and start.
- README fallback briefs are often garbage (markdown tags, truncated) — replace them.
- **Cold-start scope:** explore only within the `explore.paths` scope orbit names for you (in the seed jot) — enough to name the roles and entry points without surveying the whole tree.
- **Merge-first:** existing card is accumulated knowledge from prior sessions — treat it like inherited context. Always read via `orbit info <repo>` before writing. Correct factual errors, add a role or entry point; never rewrite content that's still accurate. Curate (don't append) once past the ceiling.
- **Upgrade thin cards:** if the existing card doesn't answer both questions, rewrite it (counts as cold start, not incremental update).

## Safety rules

- **Never access `.repos/` directly.** All repos operations go through orbit commands.
- **Don't run `orbit new` if already in a workspace.** It creates at project root level.
- **Default scope is the current workspace** inferred from CWD. Don't target other workspaces unless explicitly asked.
- **Understand before your first target action on an added repo.** A *knowledge* gate, not an approval gate: before your first edit / branch / push / tag / release on a repo, complete Workflow steps 3–7 (info → memo → explore). `add` only creates a worktree — it is not understanding and never clears the gate. Normal work clears it at edit time; the trap is jumping straight from `add` to a high-impact action ("just tag a release", publish) on a repo you never read. (Gates on *understanding*, not permission — orbit takes no stance on *whether* you push or commit.)

## Safe to run freely

These orbit subcommands are read-only or idempotent workspace-writes — run them without asking:
- **Read-only:** `repos` `info` `status` `context` `goal` (read) `jot --pop` `version` `doctor` `completion`
- **Idempotent workspace-write:** `add` `switch` `sync` `memo` `jot` `goal` (write)

`done` `prune` `clone` `config` `new` are destructive or reach outside the workspace — confirm before running these.

## Communication

- **Name the command and its result.** After running an orbit command (`orbit context path`, `orbit jot`, …), say which one you ran and what it returned — don't act on it silently.
- **Facts first, structure opinions on request.** Report what you observe. Offer organizational judgments (e.g. "this repo doesn't belong in the pool") only when the user asks, and phrase them as suggestions.
- **Keep boundary notes to one line.** When you hit a hard limit (can't reach a private remote, etc.), state it in one sentence plus one alternative — don't over-explain.

## Anti-patterns

- Never guess a repo remote URL. If not in pool and user didn't provide one, ask.
- Never write full memo content (`cat ... | orbit memo <repo>`) for repos you haven't actually explored. Use `orbit memo <repo> --scaffold` to get a scaffold, then explore before writing.
- Never create a new workspace if an existing one matches the task context.
- Never write memos for repos you didn't add to your workspace or work in. Memo writeback is on-demand, not a sweep.
- Never dump README or PRD content into a memo. The card answers two questions (roles + how to use), not a documentation copy.

## Examples

**Start working in an existing workspace:**
```bash
orbit goal                    # understand the task
orbit repos                   # see what's available
orbit add backend             # bring repo into workspace
cd backend/
# ... work with git normally ...
orbit done --pr https://github.com/org/backend/pull/42
```

**Add a new repo:**
```bash
orbit clone git@github.com:org/new-service.git
orbit add new-service
```

**Switch branches (scoped mode):**
```bash
cd backend/
orbit switch -c feat-api-v2     # new branch from HEAD
# or
orbit switch release-1.29       # track existing remote branch
```
