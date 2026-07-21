# Warnings: the steering channel

> Catalogue of orbit's stderr guidance warnings — the primary mechanism by which an
> advisory-by-design tool routes the next-right-action to the agent. See
> [PRINCIPLES.md](../PRINCIPLES.md) Principle 8 ("stderr is the steering channel").

Orbit has no runtime to enforce procedure. With few exceptions (explicit gates like
`orbit done`'s completion path), commands do not block — they *guide*, and that guidance
travels on **stderr**. stdout stays clean, machine-readable data. The agent is expected to
read these warnings and act on them as authoritative procedure, not decoration.

This registry exists so the steering surface stays coherent as the CLI grows: every guidance
warning is listed with its trigger, the exact commands it names, and any redundant backstops.

## Message format contract

All guidance warnings follow one shape:

```
orbit: <what happened>: <suggested workflow>
```

- **Exactly two colons** — the `orbit:` progname prefix (standard GNU/Unix diagnostic
  convention) and the one separating *what* from *workflow*. The repo name folds into the
  "what" clause (`backend has no memo`), never as its own colon-delimited field.
- **Spoon-feed the commands.** The workflow clause names the exact next commands so the agent
  acts directly instead of inferring them from the skill. Drop the `orbit` prefix inside the
  workflow (`memo backend`, not `orbit memo backend`) — humans read these to see *intent*;
  only the agent runs them, and it knows the binary.
- **ASCII, human-readable.** No em/en-dashes, no arrows, no backticks. Ranges use `~`
  (`4~16 lines`). Phrase the workflow as a natural sentence that strings the command tokens
  together, not a symbol-chained list.
- **Guide, don't block.** Warnings never abort (the sole exception is `orbit done`'s gate,
  which still only warns — it does not refuse). They never go to stdout.

Two other message classes are **not** steering and do not name a next command:
- **Hard errors** (abort + non-zero exit) keep the nested `orbit: <context>: <message>`
  diagnostic form (e.g. `orbit: backend: repo not in pool, skipping`) — failure reports.
- **Informational status facts** state a condition the agent should factor into a decision it is
  already making (e.g. a missing memo during `orbit repos`/`info` screening, before the repo is
  added). Plain `orbit: <fact>`, no action. See "Informational notes" below for why naming a
  command there would be premature.

Only the steering warnings in the registry below carry a named workflow.

## Registry

Located by function (line numbers drift; `grep` the function name). "Backstops" lists other
layers that resurface the same guidance if this one is missed (see the layered-response model
in [spec-knowledge.md](spec-knowledge.md)).

| Warning | Trigger (command + condition) | Source (function) | Named next action | Backstops |
|:--------|:------------------------------|:------------------|:------------------|:----------|
| memo behind HEAD | any command running staleness check; stored memo commit ≠ repo HEAD | `orbit_memo_staleness` | `memo <repo>` (update) or `memo <repo> --refresh` (reset counter if unchanged) | skill workflow step 7 |
| new commits on origin | staleness check; local pool branch behind `origin/<branch>` | `orbit_upstream_check` | `sync <repo>` before add/rely | skill step 5 (cold-start sync) |
| workspace done + prune-eligible | `orbit add` in a `status=done` workspace | `orbit_add` | `goal "<text>"` to reactivate first | skill (reactivation rules), spec-lifecycle |
| raw-mode branch (not scoped) | `orbit add` (non-silent), or per-repo status (context/status/done) | `orbit_add`, `orbit_collect_repo_status` | `orbit switch -c <name>` to convert to scoped mode | skill step 8, spec-branching |
| no memo for repo (add) | `orbit add` (non-silent), memo missing | `orbit_add` | explore `explore.paths`, then `memo <repo>` | per-repo status (context), done gate, skill step 7 |
| memo thin for repo (add) | `orbit add` (non-silent), memo below `minLines` | `orbit_add` | explore `explore.paths`, expand via `memo <repo>` before done | per-repo status (context), done gate, skill step 7 |
| memo over budget | `orbit memo` writeback (in a workspace), card exceeds `maxLines`+`minLines` | `orbit_memo` | curate the card back to `<min>~<max>` lines | done gate, per-repo status (context) |
| worktree behind after sync | `orbit sync`; workspace worktree tracks the advanced branch | `orbit_sync` | `git pull` in the worktree if you want the new commits | — (informational, native git) |
| jot overflow | `orbit jot` past `jot.bufferSize` (default 4) | `orbit_jot` | `jot <repo> --pop`, then merge into memo | done gate, per-repo status (context) |
| done: jot entries remain | `orbit done`, un-popped jots exist (any count) | `orbit_done` | `jot --pop`, `info`, merge into memo before done | jot overflow, per-repo status (context) |
| done: memo thin | `orbit done`, thin memo + no leftover jots | `orbit_done` | explore + write a memo before done | per-repo status (context) |
| done: memo over budget | `orbit done`, card exceeds `maxLines`+`minLines` | `orbit_done` | curate once, back to `<min>~<max>` lines | per-repo status (context) |
| done: card budget | `orbit done`, when a jot/over-budget warning fired | `orbit_done` | curate memo to `<min>~<max>` lines (roles + how to use), don't append | skill "keep it tight" rule |
| done: only memo survives | `orbit done`, when any per-repo warning fired | `orbit_done` | (closing line — session working memory and the jot queue do not survive done; memo is the only durable artifact) | — (no named action; reinforces the debt above) |
| index out of sync | `orbit repos`, index brief missing but memo has one | `orbit_repos` | `memo <repo> --refresh` (repairs an existing memo's cache; no add/exploration needed) | — |

## Informational notes (not steering — no named action)

`orbit repos` and `orbit info` are **screening** commands: the agent runs them to decide
*whether* to add a repo, before it is in the workspace. When they report a missing memo, that is
a **fact for the add decision**, not a call to action — so these notes deliberately name **no**
next command:

| Note | Command + condition | Source |
|:-----|:--------------------|:-------|
| `<repo> has N jots (building)` | `orbit jot`, queue above half of `jot.bufferSize` but not past it | `orbit_jot` |
| `<repo> has no memo, using README instead` | `orbit repos`, memo absent, README present | `orbit_repos` |
| `<repo> has no memo or README` | `orbit repos`, both absent | `orbit_repos` |
| `<repo> has no memo, showing README` | `orbit info`, memo absent, README present | `orbit_info` |
| `<repo> README truncated to <N> lines, no memo yet` | `orbit info` README fallback exceeds `memo.maxLines` | `orbit_info` |
| `<repo> has no memo` | `orbit info`, both absent | `orbit_info` |

The `building` note is a count without a named action — the queue is filling but has not hit the aggregation threshold; the `overflow` steering warning (registry above) fires when it does. Naming an action at `building` would cry wolf.

Naming `memo <repo>` on the screening notes would be wrong: you cannot write an accurate memo for a repo you have not added and explored, and a README stand-in is explicitly **not** enough context to write one (that is the "README ≠ enough" anti-pattern). The memo-writing action belongs where the repo is actually in hand — the **add note** (`orbit_add`, after add) and the **`orbit done`** per-repo warnings (before finishing) — both of which are in the steering registry above. These screening notes just supply the fact those later steps act on.

## Backstop layers

The memo-surfacing warnings are deliberately redundant — no single missed step loses the knowledge. The same per-repo state (thin memo / over-budget card / leftover jots) is **computed inline on every read** and surfaces at: the **add-time stderr** (`orbit add`, the high-attention moment), the **cruise block** (bare `orbit context` and the `--startup`/reignite block — after compaction and at every session start), and the **`orbit done`** per-repo warnings (the final backstop). There is no durable sentinel to lose: the condition lives in the memo file and the jot queue, so it persists until fixed. This layering is the surfacing model described in [spec-knowledge.md](spec-knowledge.md); it is one instance of the broader steering-channel principle. Staleness/tracking/sync notes are single-shot advisories with no backstop by design (they inform a decision rather than guard an invariant).

## Maintenance rule

Any new stderr line that guides the agent toward a next action MUST:

1. follow the message-format contract above (two colons, ASCII, names the exact commands,
   drops the `orbit` prefix in the workflow clause);
2. be added to the registry with its trigger, source function, named commands, and backstops.

Errors that abort do not belong here — keep them in the `orbit: <context>: <message>`
diagnostic form and out of this registry.
