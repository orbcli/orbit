# Hooks: deterministic context injection

> Behavior contract for orbit's agent-integration hooks — what fires when, what
> it runs, what it injects, and the wrapper discipline that keeps every agent's
> integration identical. Agent-facing behavior rules (what the agent should *do*
> with an injected block) live in [skills/CONSTRAINTS.md](../skills/CONSTRAINTS.md);
> per-agent skill usage lives in `skills/orbit/SKILL.md`.

## Injection contract

- **Hook = thin wrapper.** A hook runs exactly one `orbit context` command and
  injects its markdown output. All logic (jot counting, three-band levels,
  staleness detection, memo state, per-repo status assembly) lives in
  `orbit.sh`, where it is bats-testable. The only wrapping a hook adds is the
  tag pair and the hint line below.
- **`<orbit-context>` tags are hook-generated only.** `orbit.sh` never emits
  them; hooks add them front and back so the agent can distinguish
  hook-injected context from its own command output. Seeing the tag means the
  preflight already ran — the agent must not re-run `orbit context` to reload
  what it already holds.
- **One XML comment hint per block, hook-layer only, tier-specific wording.**
  The skill description names "an `<orbit-context>` hook block is present"
  as the skill's primary trigger — seeing the tag alone demands the load.
  The hint is only an in-band **backstop** for that trigger: the block
  payload itself carried no pointer to the skill, and agents were observed
  reading the block without ever loading it. Startup blocks carry
  `<!-- orbit workspace: invoke the orbit skill before your first reply -->`
  (unconditional — a fresh session never has the skill loaded). Cruise
  blocks carry `<!-- orbit workspace: invoke the orbit skill (skip only if
  its content is already in your context) -->` — resume/compact fires
  mid-session, and a compaction can wipe the skill CONTENT while a summary
  still "remembers" loading it, so the condition is content-in-context, not
  loaded-this-session. XML comment syntax keeps the hint out of the data.
  `orbit.sh` never emits it — hook furniture, not runtime output. In
  skill-only setups with no hook, the launch phrase (`orbit start`) remains
  the only entry point.
- **Two injection tiers, decreasing token budget: startup > cruise.**
  - **startup** (`orbit context --startup`): cold start (empty workspace) →
    durables (`path` / `goal` / `state`, DONE banner when done) + the pool
    roster; populated workspace → durables + each repo's memo card + two-layer
    staleness (memoBehind + remoteAhead — fetches like `orbit info`, advisory
    only; sync stays on-demand) + conditional per-repo status + small jot
    queues inlined (up to `jot.bufferSize`).
  - **cruise** (bare `orbit context`): cheap durables + conditional per-repo
    status only (pending jots with level / commits behind upstream /
    `memo thin` / `memo over budget`). Never fetches, never dumps memos —
    the in-session counterpart of the startup block.
- **Conditional output.** Per-repo status lists only repos with something
  pending; a fully-ok repo is silent. From the status the agent infers the
  next action ("0 jots + memo thin" = explore + write; "overflow" = pop +
  merge; "behind" = sync; "over budget" = curate).
- **Fail-safe.** Every hook is a silent no-op when orbit is missing or CWD is
  not in a workspace (`orbit context` fails fast in both cases).

## Event routing

Rows are agents (the set grows); columns are the two injection tiers. Upstream
event names are implementation details of each agent (not ours to rename);
block names (`startup` / `cruise`) are ours. ❌ = no hook window, skill
fallback (the agent runs bare `orbit context` itself).

| Agent | startup tier | cruise tier |
|------|--------------|-------------|
| Claude | `SessionStart:startup` → `hooks/session-start.sh` | `SessionStart:resume` / `SessionStart:compact` → `hooks/session-resume.sh` |
| Codex | `SessionStart:startup` → `hooks/codex/session-start.sh` | `SessionStart:resume\|clear\|compact` → `hooks/codex/session-resume.sh` |
| Qoder | `SessionStart:startup` → `hooks/session-start.sh` | `SessionStart:resume` / `SessionStart:compact` → `hooks/session-resume.sh` |
| OpenCode | `experimental.chat.system.transform` (first of session) → `--startup` | `experimental.session.compacting` → summary-pass guard (below); `session.compacted` event → cruise + pins the session to cruise tier; ctxCache refreshes after orbit CLI commands rebuild the current tier (startup pre-compact, cruise post-compact); resume ❌ (see TODO) |

- Claude/Qoder use the shared scripts under `hooks/` directly; Codex goes
  through its wrappers under `hooks/codex/`. `hooks.json` in each agent dir
  wires the matchers. Codex SessionStart sources verified against the Codex
  manual: `startup | resume | clear | compact` — `clear` is Codex-only today.
- **OpenCode** (`.opencode-plugin/plugin.ts`, TypeScript): the first
  transform of a session injects `--startup`; the per-session `ctxCache`
  re-pushes the block on later transforms (the system prompt is rebuilt per
  request — nothing persists on its own) and is refreshed after any orbit
  **CLI** command — a bash command whose invoked binary is `orbit` /
  `orbit.sh`. Path substrings never count: workspace paths conventionally
  contain "orbit" (`~/coding/orbit-demo`), and a `cmd.includes("orbit")`
  matcher once downgraded every session to cruise after the first `ls`.
  The refresh rebuilds the session's **current tier in full**: the startup
  block before any compaction (Claude/Qoder parity — there the injected
  block rides conversation history for the whole pre-compact session), the
  cruise block after (compaction means context pressure — full memos are
  never re-injected). Compaction injects cruise two ways: an immediate
  prompt (the compacted history is gone) plus a cache update and tier pin
  so subsequent transforms and refreshes stay on cruise. A failed summary
  never publishes `session.compacted` (opencode only publishes it on
  success), so a failed compaction leaves the session unpinned and
  injection resumes normally next turn.
- **Compaction summary-pass guard (OpenCode).** The summary request
  forbids tool calls, but `experimental.chat.system.transform` fires for
  it like any other request — an injected block whose hint says "invoke
  the skill" primes the model to attempt a tool call, which opencode
  rejects with `Tool call not allowed while generating summary`, failing
  the compaction. So `experimental.session.compacting` flags the session
  and the transform suppresses injection for the whole compaction
  episode — including provider-level retries of the summary request,
  each of which re-fires the transform. The flag clears on
  `session.compacted` (success) or `session.idle` (failure/abort — a
  failed summary never publishes `session.compacted`), so injection
  resumes normally from the next turn. The workspace durables (bare
  cruise text — no tags, no hint) are handed to the summary prompt
  through the hook's `context` channel, the official way to carry
  information across compaction.

## File inventory

| Path | Role |
|------|------|
| `hooks/session-start.sh` | Shared startup script (thin wrapper over `orbit context --startup`) |
| `hooks/session-resume.sh` | Shared resume/compact script (thin wrapper over bare `orbit context`) |
| `hooks/auto-approve.sh` | Shared PreToolUse auto-approve script |
| `hooks/codex/session-start.sh` | Codex wrapper — delegates to `hooks/session-start.sh` |
| `hooks/codex/session-resume.sh` | Codex wrapper — delegates to `hooks/session-resume.sh` |
| `hooks/codex/auto-approve.sh` | Codex wrapper — wraps `hooks/auto-approve.sh`; exit 0 = allow |
| `hooks/{claude,qoder,codex}/hooks.json` | Per-agent event wiring |
| `.opencode-plugin/plugin.ts` | OpenCode integration (context injection + auto-approve) |

## Auto-approve semantics

`hooks/auto-approve.sh` (wired as `PreToolUse`/`Bash` for Claude/Qoder,
`PermissionRequest`/`Bash` for Codex via the exit-code wrapper) auto-approves
only a **single, un-chained** `orbit` invocation whose subcommand is in the
two safe tiers — the tier contract itself lives in
[skills/CONSTRAINTS.md](../skills/CONSTRAINTS.md#permission-and-auto-execution-policy):

- Refuses anything with shell chaining/redirection/substitution (`;` `&` `|`
  `` ` `` `$(` `>` `<`, newline) — the normal confirmation prompt happens.
- Refuses non-orbit binaries and tier-3 subcommands (`done` `prune` `clone`
  `config` `new`, and `sync --force`).
- Claude/Qoder: emits an `allow` decision JSON. Codex wrapper: exit 0 =
  allow, non-zero = prompt. OpenCode: the `permission.ask` hook in plugin.ts
  applies the same tier set (`SAFE_SUBCOMMANDS`).
- Fail-safe: missing `jq`, non-Bash tool, or any parse problem → no output
  (or non-zero exit), i.e. the normal confirmation prompt.

## TODO

- **OpenCode resume routing** — blocked on
  [anomalyco/opencode#5409](https://github.com/anomalyco/opencode/issues/5409)
  (SessionStart hook with startup/resume/compact sources). Verified by
  testing: resume is a UI navigation that fires no event and does not re-run
  transform, so the plugin has no injection window for it. Once upstream
  lands the hook, restore the resume tier for OpenCode: fresh session →
  `--startup`, resumed session → cruise.
