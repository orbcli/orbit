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
| branch left outside `branch.prefix` | `orbit prune`, pool holds a local branch shaped `*/<workspace>/*` but outside the configured prefix | `orbit_prune` | (states the fact; the branch is not orbit's to delete — rename or delete it with native git if unwanted) | — |

## Informational notes (not steering — no named action)

`orbit repos` and `orbit info` are **screening** commands: the agent runs them to decide
*whether* to add a repo, before it is in the workspace. When they report a missing memo, that is
a **fact for the add decision**, not a call to action — so these notes deliberately name **no**
next command. `orbit repos` carries the fact in its table's MEMO column (`ok` / `stale N` /
`none`) rather than as a stderr note; `orbit info` prints it on stderr:

| Note | Command + condition | Source |
|:-----|:--------------------|:-------|
| `<repo> has N jots (building)` | `orbit jot`, queue above half of `jot.bufferSize` but not past it | `orbit_jot` |
| MEMO column shows `none` | `orbit repos`, memo absent (README extract shown as brief, or `-`) | `orbit_repos` |
| MEMO column shows `stale N` | `orbit repos`, memo N commits behind HEAD | `orbit_repos` |
| `<repo> has no memo, showing README` | `orbit info`, memo absent, README present | `orbit_info` |
| `<repo> has no memo; showing first <N> of <M> README lines` | `orbit info` README fallback exceeds `memo.maxLines` | `orbit_info` |
| `<repo> has no memo` | `orbit info`, both absent | `orbit_info` |

The `building` note is a count without a named action — the queue is filling but has not hit the aggregation threshold; the `overflow` steering warning (registry above) fires when it does. Naming an action at `building` would cry wolf.

Naming `memo <repo>` on the screening notes would be wrong: you cannot write an accurate memo for a repo you have not added and explored, and a README stand-in is explicitly **not** enough context to write one (that is the "README ≠ enough" anti-pattern). The memo-writing action belongs where the repo is actually in hand — the **add note** (`orbit_add`, after add) and the **`orbit done`** per-repo warnings (before finishing) — both of which are in the steering registry above. These screening notes just supply the fact those later steps act on.

## Refusals and skips (deliberately no named action)

A third class: a destructive command declining to act. These state the fact and stop — naming a way forward is exactly what they must not do. The rule comes from a real incident: `prune`'s old skip line (`skipping <ws>: you are currently in this workspace`) read as an instruction, and the agent followed it — `cd` out, prune by name, workspace gone. **Audit every refusal by assuming the receiver will do what it says.**

| Refusal | Command + condition | Source |
|:--------|:--------------------|:-------|
| `prune must be run from the project root` | `orbit prune` with CWD inside any workspace (aborts) | `orbit_prune` |
| `sync --force must be run from the project root` (or `--force/--branch` when both are given) | `orbit sync` with a destructive flag and CWD inside any workspace (aborts) | `orbit_sync` |
| `cannot prune workspace with an active session: <ws>` | `orbit prune <ws>`, an ancestor process is rooted in it (aborts) | `orbit_prune` |
| `skipping <ws>: workspace has an active session` | `orbit prune` enumeration, ancestor rooted in the candidate | `orbit_prune` |
| `skipping <ws>: <reason>[; <reason>...]` | `orbit prune` without `--force`; reasons are `uncommitted changes in: <repos>` / `git repos not from the pool: <repos>` / `unmerged jots in: <repo> (<n>)`, all applicable ones joined by `; ` | `orbit_prune` |
| `cannot read process ancestry on this host: the active-session guard is inactive` | `orbit prune`, not one ancestor cwd could be read (no `/proc`, no `lsof`, or no usable `ps`) | `orbit_collect_ancestor_cwds` |
| `skipping unmerged branch: <branch> (content already upstream — squash/rebase merge? clean up: git -C "<pool>" branch -D "<branch>")` | `orbit prune` branch cleanup: ancestor check fails but the branch's content is fully in `origin/<default>` (cost-ordered detection: `git merge-tree` ≥ 2.38, else `git cherry`; an unresolvable upstream never fires the hint) | `orbit_branch_protection_delete` |
| `branch.prefix is part of existing branch names under '<current>/': <repo> (n)` | `orbit config branch.prefix <new>` while branches still carry the current prefix (aborts) | `orbit_config` |
| `invalid branch.prefix: <value>` | `orbit config branch.prefix` with a value that is not one refname-legal segment (aborts) | `orbit_config` |
| `invalid repo name: <name> (expected a pool repo basename: [A-Za-z0-9._-], no leading '.' or '-')` | `clone --name` / `add` / `info` / `memo` / `sync` with a repo name outside the contract in [spec-commands.md](spec-commands.md#repo-name-contract) (aborts; `sync` skips that argument) | `orbit_require_repo_name` / `orbit_sync_one` |
| `repos.* is pool index data, not project config` | `orbit config repos.<...>` set or unset (aborts) | `orbit_config` |

None of these mention `--force`, even where `--force` would in fact proceed: the flag exists for a user who decides to discard work, not as an escape hatch the tool suggests. All applicable data-guard reasons are reported **together** in one line rather than one per run — `--force` releases them as a single decision, so the operator has to see the whole set to make that decision once. Under `--dry-run` the skips are reported on stdout as `would skip: <ws> (<reasons>)`, same wording rule. The guard contract itself lives in [spec-lifecycle.md](spec-lifecycle.md#prune-safety-guards).

One row deliberately breaks the "no named action" rule: the **content-upstream branch hint**. It fires only where the check has *proven* the branch's content is already merged (a squash/rebase merge the ancestor check cannot see), and prune runs only at the project root where the operator is human — handing that operator the exact native-git cleanup command is service, not a bypass map. The hint never names `--force`, and it never fires for a branch whose content is not fully upstream.

## Backstop layers

The memo-surfacing warnings are deliberately redundant — no single missed step loses the knowledge. The same per-repo state (thin memo / over-budget card / leftover jots) is **computed inline on every read** and surfaces at: the **add-time stderr** (`orbit add`, the high-attention moment), the **cruise block** (bare `orbit context` and the `--startup`/reignite block — after compaction and at every session start), and the **`orbit done`** per-repo warnings (the final backstop). There is no durable sentinel to lose: the condition lives in the memo file and the jot queue, so it persists until fixed. This layering is the surfacing model described in [spec-knowledge.md](spec-knowledge.md); it is one instance of the broader steering-channel principle. Staleness/tracking/sync notes are single-shot advisories with no backstop by design (they inform a decision rather than guard an invariant).

## Maintenance rule

Any new stderr line that guides the agent toward a next action MUST:

1. follow the message-format contract above (two colons, ASCII, names the exact commands,
   drops the `orbit` prefix in the workflow clause);
2. be added to the registry with its trigger, source function, named commands, and backstops.

Any new **refusal or skip** from a destructive command MUST instead:

1. state only the fact — no flag, no relocation, nothing the receiver can invert into a bypass;
2. be added to the refusals table above with its trigger and source function.

Errors that abort do not belong here — keep them in the `orbit: <context>: <message>`
diagnostic form and out of this registry.
