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
| raw-mode branch (not scoped) | `orbit add` (non-silent), or per-repo status (context/status/done) | `orbit_add`, `orbit_collect_repo_status` | `orbit switch -c <name>` to convert to scoped mode | skill step 8, spec-worktree |
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

## Config convergence lines (contract text)

Three steering lines report config convergence, one per managed key, and their text is
fixed by contract (a changelog-visible output surface):

```text
orbit: <repo>: fetch config converged: git remote set-branches origin "*" (stop converging and re-apply yours: orbit config git.fetchAllBranches once)
orbit: <repo>: fetch config converged: git config fetch.prune true (stop converging and re-apply yours: orbit config git.fetchPrune once)
orbit: <repo>: push routing converged: git config push.default upstream (stop converging and re-apply yours: orbit config git.pushUpstreamByDefault once)
```

| Warning | Trigger (command + condition) | Source (function) | Named next action | Backstops |
|:--------|:------------------------------|:------------------|:------------------|:----------|
| config converged (per key, forms above) | any fetching touchpoint (`orbit sync` / `orbit info` / `orbit context --startup` / `orbit prune`) that converges a non-standard pool config value, per managed key, under the default `always` maintenance mode | `orbit_maintain_pool_config` | the parenthesized opt-out: `config git.fetchAllBranches once` / `config git.fetchPrune once` / `config git.pushUpstreamByDefault once` stops future convergence; re-applying the custom value is the user's step | — (one-shot: fires only when a write actually happens; `once`/`never` pools are untouched and unreported) |

The lines deviate from the two-colon shape on purpose: their first duty is *reporting a
mutation orbit just made* (silent config rewrites are forbidden), and the extra colons belong
to the embedded native command and the opt-out command, quoted verbatim so they can be run
as-is. The parenthetical names two steps deliberately — convergence happens first and the
report second (a pre-warning would need a persisted "already warned" flag, which the
zero-state model forbids), so the wording must admit the value was replaced: the switch
only stops future convergence; it does not bring the replaced value back. Under `--dry-run`, prune previews the same convergence on stdout unprefixed as
`would converge fetch config: git remote set-branches origin "*"` / `would converge fetch
config: git config fetch.prune true` / `would converge push routing: git config push.default
upstream` (Report lines below).

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
| `<repo>: WARNING: cannot fetch default branch origin/<branch> though the remote answers — the remote may have lost its default branch` | any fetching touchpoint: the default branch's named fetch failed while the remote answers a probe — a repo-level event (a renamed/deleted default), deliberately naming no remedy: the right one depends on what happened on the remote. Offline everything fails quietly instead | `orbit_touchpoint_fetch` |

The `building` note is a count without a named action — the queue is filling but has not hit the aggregation threshold; the `overflow` steering warning (registry above) fires when it does. Naming an action at `building` would cry wolf.

Naming `memo <repo>` on the screening notes would be wrong: you cannot write an accurate memo for a repo you have not added and explored, and a README stand-in is explicitly **not** enough context to write one (that is the "README ≠ enough" anti-pattern). The memo-writing action belongs where the repo is actually in hand — the **add note** (`orbit_add`, after add) and the **`orbit done`** per-repo warnings (before finishing) — both of which are in the steering registry above. These screening notes just supply the fact those later steps act on.

## Refusals and skips (deliberately no named action)

A third class: a destructive command declining to act. These state the fact and stop — naming a way forward is exactly what they must not do. The rule comes from a real incident: `prune`'s old skip line (`skipping <ws>: you are currently in this workspace`) read as an instruction, and the agent followed it — `cd` out, prune by name, workspace gone. **Audit every refusal by assuming the receiver will do what it says.** The rule splits by audience: **initiation refusals** (who may run this at all) never name a way forward; **execution reports** (what a run left behind) may suggest follow-up commands, because the initiation guard guarantees the receiver is the project-root operator — but every force-delete suggestion carries the confirm-useless caveat and a review command first.

| Refusal | Command + condition | Source |
|:--------|:--------------------|:-------|
| `prune must be run from the project root — cd <root> && orbit prune <args>` | `orbit prune` with CWD inside a workspace AND a readable, clean ancestry (aborts) | `orbit_prune` |
| `prune must be run from the project root` (no replay) | `orbit prune` with CWD inside a workspace but ancestry unreadable — blind guard withholds the replay (aborts) | `orbit_prune` |
| `prune should not be initiated from inside workspace <ws>` | `orbit prune […]`: an ancestor cwd is inside any workspace, at any depth (aborts the whole invocation, named and enumeration alike) | `orbit_prune` |
| `skipping <ws>: <reason>[; <reason>...]` | `orbit prune` without `--force`; reasons are `uncommitted changes in: <repos>` / `git repos not from the pool: <repos>` / `unmerged jots in: <repo> (<n>)`, all applicable ones joined by `; ` | `orbit_prune` |
| `skipping <ws>: damaged worktree in <repo> (gitdir pointer unusable, pool registration intact) — content may be un-persisted` | `orbit prune` without `--force`: the pool registers a direct child as a worktree but `git -C <path> rev-parse --git-dir` fails (pointer deleted, truncated or garbage), so every "is this a git repo" test fails and the uncommitted-changes guard would never see it. Prune does not repair — a worktree it cannot read is one it must not delete | `orbit_prune` |
| `skipping <ws>: worktree removal failed in <repo> (<git error>) — workspace kept` | `orbit prune`: `git worktree remove --force` failed for a reason other than "not a working tree" (locked, IO); the directory stays — removal runs only when git has no stake in it | `orbit_prune` |
| `skipping <ws>: rename to .prune-trash failed (<error>) — workspace kept` | `orbit prune`: the atomic rename into `.prune-trash/` failed (EXDEV on a mount point, permissions); the workspace stays in place, exits non-zero | `orbit_prune` |
| `<ws>: trash removal incomplete (<error>) — left in .prune-trash, resumed on the next run` | `orbit prune`: deleting a trash entry failed mid-way; the workspace is already out of the namespace (not a "skipping" line), the next run's opening sweep resumes; exits non-zero | `orbit_prune` |
| `.prune-trash: cleared N interrupted deletion(s)` | `orbit prune` opening sweep finished prior interrupted deletions — housekeeping note; under `--dry-run` it reads `would clear …` and nothing is touched | `orbit_prune` |
| `no such workspace: <ws>` / `<ws> exists but is not marked done` / `<ws> exists but workspace metadata is missing or unreadable` | `orbit prune <ws>` with no matching candidate and no ghost residue — three distinct facts, reported separately; none names a way forward. The second is a recorded intent (never overridden, no flag waives it); the third is a lost cache (rebuilt by `orbit done` inside the directory) — and the remedy is deliberately left unnamed in both: an initiation refusal states the fact and stops | `orbit_prune` |
| `<ws> is marked done but not older than <dur>` | `orbit prune <ws> --older <dur>` where the workspace is done but younger than the duration — the age fact, not a metadata problem | `orbit_prune` |
| `skipping <ws>: cannot scan branches in: <repos>` | `orbit prune`: a pool repo's refs could not be enumerated for this workspace's branch set — blocks in BOTH modes (`--force` cannot supply missing evidence); never feeds the closing block's force suggestion (a rerun would fail the same way). Same exit class as a validation refusal (nothing was attempted) | `orbit_prune` |
| `<ws>: --force discards un-persisted work in <repos> — this cannot be undone` / `<ws>: --force removes <repo> whose state cannot be read — content may be un-persisted, this cannot be undone` | `orbit prune --force` immediately before removing a workspace that a content guard would have skipped — the uncommitted-changes guard (first form) or the damaged-worktree guard (second form, where orbit cannot read what is at stake). The only steps with no recovery path, so the consequence is stated before the act | `orbit_prune` |
| `<repo>: pruned N stale worktree registration(s), M orphan branch config section(s)` | `orbit prune` residue phase: maintenance whose subject no longer exists (a registration whose worktree path is gone, `branch.<name>.*` whose branch is gone) — repaired automatically, no `--force`: no object and no file with content is removed, only the admin directory and three config lines | `orbit_prune` |
| `<git error first line>` | `orbit prune` branch cleanup: git refused the deletion (checked out elsewhere, and other native refusals). git's own first line only — its `hint:` continuations name `git branch -D`, which a refusal must not hand out. The branch counts as skipped | `orbit_branch_delete` |
| `workspaces kept: <ws>, …` + `after confirming …, force-delete:` + per-workspace `orbit prune <ws> --force` | closing block of a `prune` run with kept content — fed by validation refusals (live workspaces, all-or-nothing) and kept ghost branches; scoped entries only — a raw skip belongs to the raw report below. Two refusals never feed it because the suggestion cannot help: a scan failure (above; the rerun fails the same way) and a deletion that git *refused* mid-execution (an execution failure, not a keep) | `orbit_prune` |
| `untraceable branches (raw, no remote, no workspace) — human disposal:` + per-branch status/review lines (grouped by repo) + `branch -D` commands | `orbit prune` enumeration report of branches traceable to nothing; orbit never deletes them | `orbit_prune_raw_residue` |
| `cannot read process ancestry on this host: the initiation guard is inactive` | `orbit prune`, not one ancestor cwd could be read (no `/proc`, no `lsof`, or no usable `ps`) | `orbit_collect_ancestor_cwds` |
| `keeping unmerged branch: <branch> (content reads as already upstream — squash/rebase merge? clean up: git -C ".repos/<repo>" branch -D "<branch>")` | `orbit prune` branch verdict: the merge-tree layer could not answer (git < 2.38 or a conflicting merge) but `git cherry` finds every commit patch-equivalent upstream. The definitive tree-level case is a delete verdict (layer 3), not this hint. "Keeping", not "skipping": in a live workspace this branch blocks the whole reclaim; in a ghost group it is one kept item among deletions | `orbit_branch_verdict` |
| `keeping unmerged branch: <branch> — review: git -C ".repos/<repo>" log origin/<default>..<branch>` | `orbit prune` branch verdict: no layer fires; the keep line carries the concrete review command (omitted when the default branch is undeterminable). Same "keeping" wording as above | `orbit_branch_verdict` |
| `<repo>: cannot scan branches — residue check skipped for this repo` | `orbit prune`: a git error while enumerating refs; a blind scan never passes as empty | `orbit_prune` |
| `<repo>: left branch outside branch.prefix: <branches>` | `orbit prune`: a local branch shaped like this workspace's (`*/<ws>/*`) but outside the configured prefix — named rather than silently left behind; not orbit's to delete, no action named | `orbit_prune` |
| `<repo>: worktree not registered to the pool repo; left to directory removal` | `orbit prune`: D1 found no registration for the worktree ("is not a working tree") — git has no stake in it, so removal proceeds | `orbit_prune` |
| `PR evidence recorded but gh unavailable — falling back to git merged checks` | `orbit prune`: the workspace's `.orbit` holds `pr.url` entries but `gh` is absent or a call failed; layer-1 verdicts degrade to the git layers. Informational degradation note, not a refusal | `orbit_branch_verdict` |
| `sync <flags> should not be initiated from inside workspace <ws>` | `orbit sync --force` / `--branch`: an ancestor cwd is inside any workspace (aborts; shared guard with `prune` — `orbit_require_root_scope`) | `orbit_sync` |
| `sync <flags> must be run from the project root — cd <root> && orbit sync <args>` | `orbit sync --force` / `--branch` with CWD inside a workspace AND a readable, clean ancestry (aborts) | `orbit_sync` |
| `sync <flags> must be run from the project root` (no replay) | `orbit sync --force` / `--branch` with CWD inside a workspace but ancestry unreadable — blind guard withholds the replay (aborts) | `orbit_sync` |
| `branch.prefix is part of existing branch names under '<current>/': <repo> (n)` | `orbit config branch.prefix <new>` while branches still carry the current prefix (aborts) | `orbit_config` |
| `invalid branch.prefix: <value>` | `orbit config branch.prefix` with a value that is not one refname-legal segment (aborts) | `orbit_config` |
| `invalid <key>: <value> (expected always, once, or never)` | `orbit config git.fetchAllBranches` / `git.fetchPrune` / `git.pushUpstreamByDefault` with a value outside the three-mode vocabulary (aborts) | `orbit_config` |
| `invalid repo name: <name> (expected a pool repo basename: [A-Za-z0-9._-], no leading '.' or '-')` | `clone --name` / `add` / `info` / `memo` / `sync` with a repo name outside the contract in [spec-commands.md](spec-commands.md#repo-name-contract) (aborts; `sync` skips that argument) | `orbit_require_repo_name` / `orbit_sync_one` |
| `repos.* is pool index data, not project config` | `orbit config repos.<...>` set or unset (aborts) | `orbit_config` |

No **skip/refusal line** mentions `--force`, even where it would in fact proceed: the flag exists for a user who decides to discard work, not as an escape hatch the tool suggests mid-flow. Two deliberate exceptions, both of which prove the rule rather than bend it. The **closing block** comes after the full report, addresses the root operator, and leads with the review command plus the confirm-useless caveat. The **irreversibility notices** name the flag because the operator already passed it: they are not a way past a refusal, they are the consequence of a decision already made, stated in the last moment where the work still exists. All applicable data-guard reasons are reported **together** in one line rather than one per run — `--force` releases them as a single decision, so the operator has to see the whole set to make that decision once. Under `--dry-run` the skips are reported on stdout as `would skip: <ws> (<reasons>)`, same wording rule. The guard contract itself lives in [spec-lifecycle.md](spec-lifecycle.md#prune-safety-guards).

One row deliberately breaks the "no named action" rule: the **content-upstream keep hint**. It fires only where `git cherry` finds every commit patch-equivalent upstream but the definitive tree-level check (`git merge-tree`) could not answer — had it answered, the branch would have been deleted as a layer-3 verdict, not hinted. Prune runs only at the project root where the operator is human — handing that operator the exact native-git cleanup command is service, not a bypass map. The hint never names `--force`, and it never fires on a failed or unresolvable check.

One row deliberately **drops** part of git's own text: a branch-deletion refusal forwards git's first line only. git's `hint:` continuations say "If you are sure you want to delete it, run `git branch -D <name>`" — a ready-to-run bypass, aimed at exactly the receiver this section is written for. Passing native errors through is right; passing native *advice* through would import someone else's steering into a channel this contract governs.

## Report lines (stdout payload — not steering)

Prune's run report is stdout payload and never carries the `orbit:` prefix, in either mode (the prefix marks the stderr diagnostics channel). Shapes:

```text
pruning: <ws> (N worktrees) / pruned: <ws> (N worktrees removed, M branches deleted)   # live run header/summary
pruning: <ws> (residue) / pruned: <ws> (residue) (N branches deleted, M kept)          # ghost group header/summary
would prune: <ws> … / would skip: <ws> (<reasons>) / would clear N interrupted deletion(s)   # dry-run
  (no worktrees)                                                  # a candidate with no repo dirs
would remove workspace directory (via .prune-trash)               # dry-run only: the D4 step
    deleted branch (force|PR merged|merged|content upstream): <branch> (was <sha>)   # the SHA is the recovery handle — good while the objects survive gc
    would delete branch (merged|PR merged|content upstream): <branch> / would force-delete branch: <branch>   # dry-run
    would keep unmerged branch: <branch> …                        # dry-run only; a real-run live keep is a stderr diagnostic
    kept branch (unmerged): <branch> — review: …                            # ghost group only: kept lines report in the same block as deletions
    would leave branch outside branch.prefix: <branches>          # dry-run; the real run is a stderr note
    would converge fetch config: git remote set-branches origin "*" / git config fetch.prune true   # dry-run; the real run is the stderr steering lines above
    would converge push routing: git config push.default upstream   # dry-run; likewise
pool maintenance:                                                 # section header for pool-level accounts (config convergence previews / pool self-heal) — from the enumeration sweep or a targeted ghost run; never nested inside a workspace block
nothing to prune
```

A live workspace's kept branches are reported on the stderr refusal lines above (a validation refusal is a diagnostic); in dry-run the kept lines go to stdout **unprefixed**, and the `would skip: <ws> (<reasons>)` summary appears only when data-guard reasons also apply. A ghost group's kept lines are report content, because the group is a reconciliation report, not a refusal. The closing block (`workspaces kept: …` + caveat + force suggestions) is stderr with the `orbit:` prefix in a real run; in dry-run it goes to stdout **unprefixed**, the summary reading `would keep …` — the report-payload rule above applies to it too.

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
