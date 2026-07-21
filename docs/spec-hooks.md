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
  tag pair below.
- **`<orbit-context>` tags are hook-generated only.** `orbit.sh` never emits
  them; hooks add them front and back so the agent can distinguish
  hook-injected context from its own command output. Seeing the tag means the
  preflight already ran — the agent must not re-run `orbit context` to reload
  what it already holds.
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
| OpenCode | `experimental.chat.system.transform` (first of session) → `--startup` | `session.compacted` event + ctxCache rebuild after orbit commands → cruise; resume ❌ (see TODO) |

- Claude/Qoder use the shared scripts under `hooks/` directly; Codex goes
  through its wrappers under `hooks/codex/`. `hooks.json` in each agent dir
  wires the matchers. Codex SessionStart sources verified against the Codex
  manual: `startup | resume | clear | compact` — `clear` is Codex-only today.
- **OpenCode** (`.opencode-plugin/plugin.ts`, TypeScript): the first
  transform of a session injects `--startup`; the per-session `ctxCache` is
  invalidated after any orbit bash command and rebuilt with the **cruise**
  block (never the full startup block — mid-session refreshes must not
  re-inject full memos). Compaction injects cruise two ways: an immediate
  prompt (the compacted history is gone) plus a cache update so subsequent
  transforms re-inject the cruise block.

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
