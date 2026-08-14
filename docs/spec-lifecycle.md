# Lifecycle Management

> Detailed behavior definitions for responsibility division, orbit new design, orbit done semantics, orbit prune reclamation, and environment variables.

## Responsibility Division

- **orbit**: structural management (new, add, prune), worktree operations, uniqueness guarantees, source pool management (clone/repos/info/memo)
- **agent** (via skill): goal -> repos -> info -> select repo -> add -> work (jot discoveries) -> aggregate jot into memo -> done
- **human**: provides task description, optional name override, triggers prune

The **agent** role splits into two when work is delegated (see PRINCIPLES.md Principle 7):
- **owner agent** — holds lifecycle (`new`/`done`/`goal`), knowledge aggregation (`memo` write-back, a read-modify-write step), and pool / cross-workspace ops (`clone`/`sync`/`config`). Exactly one owner per workspace.
- **worker sub-agent** — dispatched for exploration/implementation. Owns the whole exploration path (`repos`/`info`/`add`/`switch`, edit/commit in worktrees, `jot` capture) but reports owner-only needs back rather than running them.

This division is key to keeping commands simple: orbit provides atomic operations, and the agent orchestrates them into a coherent discovery-first workflow via skills. Specific orchestration rules are in `skills/CONSTRAINTS.md`.

## `orbit new`

### Command Forms

```bash
orbit new "fix API"                         # -> task-01/, prints cd + startup hint
orbit new "fix API" --name api-v2           # -> api-v2/
orbit new "fix API" --exec "claude"         # -> creates then launches agent directly inside the directory
echo "fix API definition" | orbit new       # -> reads goal from stdin (convenient for manual piping)
orbit new --no-goal                         # -> no-goal creation (free exploration mode)
```

### Core Behavior

1. Read goal: positional argument `"<goal>"` takes priority; if missing, the source depends on the environment — when `ORBIT_EDITOR` is set or stdin is an interactive terminal, an editor is opened; when stdin is piped (non-interactive), the goal is read from stdin. An empty result (blank editor buffer or empty pipe) **aborts** with an error rather than falling back — use `--no-goal` to intentionally create a workspace without a goal (free exploration mode)
2. Locate project root: traverses upward from CWD looking for `.repos/`; found -> uses that location as root; not found -> implicitly initializes at CWD (creates `.repos/` + `.repos/.orbit` + `.repos/README.md` pool marker) then uses CWD as root
3. Creates workspace directory + writes `.orbit` file (records goal and created)
4. Prints next steps (follows scaffolding tool conventions, does not auto cd)
5. If `--exec` is present -> executes the specified command directly inside the new directory

### Naming Strategy

- Default `task-{auto-increment}` (scans existing task-* directories, takes max+1)
- `--name` for manual override
- `--auto-name` (mid-term, **not yet implemented**) opt-in calls agent (single inference without directory context)

#### `--auto-name` (Mid-term Capability — planned, not yet implemented)

Calls a lightweight agent based on goal text to generate a semantic directory name (e.g., "fix API definition" -> `api-definition-refactor`). Single inference, no workspace context needed, falls back to default `task-{N}` strategy on failure. This flag is not accepted by the current CLI.

### Execution Location

`orbit new` can be executed from any location; the workspace directory is always created under project root:

| Current Location | Behavior |
|-----------------|----------|
| Project root (has `.repos/`) | Normal workspace creation |
| Subdirectory of project root (including inside workspace, inside worktree) | Locates root, creates workspace under root |
| Unrelated directory (no `.repos/` discoverable) | Implicitly initializes at current directory, then creates |

## `orbit done`

`orbit done` writes to the workspace's `.orbit` file (format described in [spec-metadata](./spec-metadata.md) "Workspace Metadata" section).

Pre-completion warnings (stderr, non-blocking — `done` still succeeds): before marking complete, `orbit done` emits per-repo reminders so knowledge is not lost on the subsequent `prune`. Each repo with remaining work gets one merged line, combining any of the conditions that apply to it (e.g. `orbit: backend: 3 jots remain (pop + merge), memo over budget (curate once)`):
- **Jot entries remain** — any un-popped jots, however few: `N jots remain (pop + merge)`. When jots are present the `memo thin` branch is skipped (the queue implies the card will be reassessed at aggregation time, not now).
- **Thin memo with no capture** — the memo is thin (missing, or fewer than `memo.minLines` non-blank lines, default 4) and the repo has no leftover jots: `memo thin (explore + write)`. This is the CLI backstop for the memo-surfacing model when hooks are absent.
- **Over-budget card** — the card exceeds `memo.maxLines + memo.minLines`: `memo over budget (curate once)` (best-effort, never blocks; may combine with the `jots remain` branch above).

When jots remain or a card is over budget, it also prints the `card budget is <min>~<max> lines` reminder. When any per-repo warning fired, it prints one closing line — `orbit: only memo survives done` — because session working memory and the jot queue do not survive done; the memo is the only durable artifact.

Idempotent semantics: executing `orbit done` again on an already `status=done` workspace overwrites `done-at`/`done-date` with the current time; `--pr` appends to the existing PR list (no deduplication, allowing multiple additions). This supports scenarios where multiple repos submit PRs in batches.

A done workspace is revived by setting a new goal — see `orbit goal` → Reactivation.

## `orbit goal`

The goal is the workspace's declared direction: optional, settable at any time, stored in the workspace `.orbit`. Command forms and storage details live in [spec-commands](./spec-commands.md) and [spec-metadata](./spec-metadata.md); what matters for the lifecycle is that the goal is the steering signal:

- present → the workspace has a direction; absent → free exploration (`orbit goal --clear`).
- set on a done workspace → **reactivation**, below.

### Reactivation (setting a goal on a done workspace)

Setting a goal with `orbit goal "<text>"` on a workspace whose `status=done` reactivates it: `status`, `done-at`, `done-date`, and the `pr.url` list are cleared, returning the workspace to the default active state. Rationale: setting a goal signals a new work cycle, and a reused workspace must leave `orbit prune` eligibility (only `status=done` workspaces are reclaimed) so active work is not deleted; the previous cycle's completion record (done timestamps + PR history) belongs to the old goal and would otherwise pollute the new one. A reactivation notice is printed to stderr.

`orbit goal --clear` does **not** reactivate — clearing a goal is not the start of new work.

Only `orbit goal` reactivates. Resuming work another way does not clear `done`: `orbit add` on a done workspace keeps the status and instead warns that the workspace is prune-eligible, pointing the user to `orbit goal` to reactivate first.

## `orbit prune`

`orbit prune` is the only command that destroys data it did not create. Its safeguards are derived from one model — the workspace footprint below, and the fixed pipeline that removes it — not accumulated incident by incident. The completeness criterion: every reachable state must fall into one of three classes — **self-healing** on the next run, **self-evident** and therefore reportable, or **explicitly out of scope**. The enumeration object is *element × pipeline step*; the tables in this section are that enumeration, they are part of the contract, and they must be re-derived whenever the pipeline changes. Message text is contract too; the full catalogue — report shapes, refusal lines, diagnostics — lives in [spec-warnings](./spec-warnings.md).

Two layers are kept distinct throughout this section. The **framework and the semantic constraints** — the pipeline's shape, the guards, the verdicts, the failure and exit semantics, recoverability, the residue classes — are workspace invariants. Every git mechanism named below is the **current binding**, consolidated in [spec-worktree](./spec-worktree.md) → Prune's Git Binding; a substrate swap rewrites that section, not this one.

### Reclamation Flow

```bash
orbit prune                       # clean up all workspaces with status=done (from the project root)
orbit prune --older 30d           # clean up done-at older than 30 days with status=done
orbit prune --older 30d --force   # same as above, skipping the validation phase
orbit prune task-01               # clean up a specific workspace (requires status=done)
orbit prune task-01 --force       # specific + skips the validation phase
orbit prune --dry-run             # validation + plan only, no execution
```

The time source for `--older` is the `done-at` field in the workspace `.orbit` file (only workspaces with `status=done` are cleaned up, so `done-at` always exists). Falls back to `created` if missing, then falls back to directory mtime.

### Workspace Footprint and the Fixed Pipeline

A workspace's complete footprint:

| # | Element (evidence class) | Current binding (git worktree) | Created by |
|---|---------|----------|-----------|
| E1 | workspace directory | `root/<ws>` | `orbit new` |
| E2 | workspace metadata (goal/created → jots → status/done-at/pr.url) | `.orbit`, inside E1 | `new` / auto-rebuilt by every writer |
| E3 | per-workspace repo view + registration pointer | worktree working dir + `.git` file, inside E1 | `orbit add` |
| E4 | repo-view registration | worktree admin dir, pool `.git/worktrees/` | `add` (written by git) |
| E5 | scoped branch state | `refs/heads/<prefix>/<ws>/*`, pool refs | `add` / `switch -c` / `switch` |
| E6 | branch upstream wiring | `branch.<name>.*`, pool config | `add` / `switch` |
| E7 | fetch config + tracking refs | wildcard map + `fetch.prune` + `origin/<branch>` refs, pool config/refs | `clone` (keys) / touchpoint fetches and pushes (refs) |
| E8 | content objects | pool ODB (`.git/objects/`, shared across worktrees) | commit/fetch — **prune never deletes**: it removes references; object reclamation belongs to gc |

Non-orbit content (created by native git or plain file operations): foreign repos, plain files and directories, ignored files, stashes, detached-HEAD commits, raw branches, remote branches. Each either disappears with D4 or is named in Out of scope.

**E3/E4/E5 have no creation order**: `orbit add` creates branch, working directory and registration with a single `git worktree add -b` — that is "no order", not "transactional" (the command itself can be interrupted into a half-created state). Only `switch -c` appends E5 alone inside an existing worktree. The deletion order therefore does not come from reversing creation but from the **dependency direction**: the registration references the branch (the checkout relation), git refuses to delete a checked-out branch, so deregistration must precede branch deletion.

The pipeline:

```text
D1  worktree remove                     (E3+E4 go together)
D2  branch delete                       (E5; git drops E6 along with the branch)
D3  config convergence                  (E6 leftovers, E7 keys)
D4a mv <ws> → <root>/.prune-trash/<ws>.<pid>  (atomic; the only directory-level commit point)
D4b rm -rf <root>/.prune-trash/<ws>.<pid>     (unordered; safe to interrupt at any point)
```

**Branch collection is pool-driven**: a candidate's branch set is the union of `refs/heads/<prefix>/<ws>/*` across pool repos, independent of whether any worktree directory still exists. (The counter-example: deriving the pool from the worktree path means an interruption between D1 and D2 drops the remaining branches from collection while D4 still removes the directory — manufacturing a ghost.)

**The "directory-level" qualifier on D4a matters**: branches deleted at D2 are already irreversible in reference terms (objects remain in the ODB until gc, but the refs — and their per-branch reflogs — are gone). D4a is the commit point for the *directory* evidence only, not a transaction boundary for the whole operation. All-or-nothing validation makes the distinction irrelevant on the normal path — passing validation means everything is slated for deletion; it only surfaces on a D2 mid-execution failure (see Execution phase).

#### The `.prune-trash` Transient

- Located at `<root>/.prune-trash/`. Same parent directory ⇒ same filesystem — the premise rename atomicity relies on, and a premise rather than a theorem: a workspace directory that is itself a mount point (bind mount / separate volume) fails rename with EXDEV. Degradation is safe — see the rename-failure rule below.
- A dotdir, so workspace detection structurally excludes it: never enumerated, never shown as a task.
- Lazily created — only `mkdir`'d when a workspace is first renamed into it.
- **Opening sweep**: every prune run first finishes deleting whatever the trash holds. Contents past the commit point are definitionally garbage — no validation, no `--force`. Entries are named `<ws>.<pid>` (unique per run), so a later rename can never collide with a leftover even when a sweep could not clear it — a plain `<ws>` name would otherwise nest inside it. Under `--dry-run` nothing is swept — the run is validation plus plan only, and a non-empty trash is reported as `would clear N interrupted deletion(s)`. A real run that cleared entries prints one housekeeping line on stderr (`orbit: .prune-trash: cleared N interrupted deletion(s)`).
- **Closing self-clean**: every run ends with a best-effort `rmdir` on the trash — it succeeds only when empty, so it is self-guarding; failure is silent (a failed deletion was already reported at its own step).
- Steady state = zero trace: the trash is transient infrastructure, not layout; the steady-state layout in spec-directory does not list it.
- The "definitionally garbage" claim holds **by exclusion**: the only entry path is the rename after D1–D3 succeed. Content a human `mv`'d into `.prune-trash/` is deleted by the sweep without validation — the same class as writing directly into `.repos/`, named in Out of scope.
- The ancestry guard cannot see the trash either (dotdir exclusion): a process whose cwd sits inside `.prune-trash/<ws>` does not trip the initiation guard, and the sweep deletes the ground under it. Bounded — the contents are garbage — but that process then fails confusingly (e.g. `git config --file` exits 128 with its cwd gone). Named here so nobody hunts it as an orbit bug.

The rename must come after D1–D3 all succeed: git tracks worktrees by registered path, so an earlier rename would defeat `git worktree remove`; and by rename time the scoped branches are gone, so the ghost scan never sees a trashed workspace. A failed rename keeps the workspace in place, reports, and exits non-zero.

### Candidate Recognition

Two evidence channels, unioned — plus the trash as a third, resume-only channel:

| workspace dir | scoped branches | marker | Verdict |
|---|---|---|---|
| present | present | done | live candidate (normal form) |
| present | present | not done / missing | active workspace — not a candidate (a targeted run refuses) |
| present | absent | done | live candidate, degenerate form (empty D2 set; also the resume state of an interruption after D2) |
| present | absent | not done / missing | active empty or junk directory — not a candidate. Unambiguous: deletion leakage never sits at the original path (it can only be in the trash) |
| absent | present | — | **ghost** (the directory evidence channel is dead; only refs remain) |
| absent | absent | — | does not exist |

Dir presence gates three things:

1. **Which steps apply** — the dirty/foreign/jot guards, D1 and D4 run only when the directory exists; the branch pipeline is identical in both forms.
2. **The authorization source** — dir present = the `done` marker (recorded intent), so validation is the full set; dir absent = intent evidence died with the directory, so authorization degrades to content legitimacy (merged → delete, unmerged → report + force suggestion).
3. **Whether an atomicity unit exists** — what makes that branch set "one object" is E1; with E1 dead there is no unit left to atomize.

**Invariant: the refs channel never fires while the directory lives.** An active workspace's branches are bound to the workspace's fate and must never be siphoned off by the ghost path underneath it.

**Ownership convention**: the refs channel trusts the namespace claim — a `<prefix>/<ws>/` shape declares belonging to `<ws>`. The workspace-name validation and the prefix-immutability guard defend this convention; a raw-git forged shape is the existing contract's boundary, not a new risk.

**Unit boundary.** All-or-nothing applies to a workspace that still exists *as a unit*. Live all-or-nothing and ghost convergent cleanup are not two policies with an exemption — they are one rule applied to two different objects. With E1 dead, what remains is a set of mutually independent orphan refs, and the convention for independent objects is per-item processing (`rm a b c`), distinct from whole-unit refusal (`git checkout`, terraform plan/apply) at the other scale. Ghost per-item cleanup is not a concession from all-or-nothing; the precondition for all-or-nothing does not hold there. All-or-nothing for ghosts would re-create an already-rejected shape:

- The gate's only automatic exit would destroy what it protects: with 20 merged + 1 unmerged, wholesale refusal leaves `--force` as the only automatic path — which force-deletes the unmerged one too.
- Risk asymmetry: a per-item mistake costs an incomplete listing; a wholesale-refusal mistake piles merged garbage behind one unmerged branch indefinitely — and silent residue accumulation is what this design exists to fix.
- Flag semantics stay unified: a flag gates **content risk**, not object count. Merged = content proven upstream = deleting the reference loses nothing = no flag — the same rule as maintenance self-heal's "no content ⇒ no flag", not another special case.

**A ghost is not a simplified pipeline but the same pipeline in dir-absent form**: D1 degrades to **stale-registration cleanup** — the directory is gone, but registrations pointing into it (E4) may remain (inevitably so when an agent `rm -rf`'d the directory), and a stale registration makes `git branch -d/-D` refuse (`used by worktree at <gone path>`), so this still precedes D2. D2/D3 are verbatim (the verdict gate degrades from unit gate to per-item gate). D4 is absent entirely — no directory to rename, no trash involvement.

### Prune Safety Guards

Prune's safeguards span **every invocation mode** — this section is the umbrella; the detailed contracts follow within it, and the failure semantics live in Execution phase below. Validation is a **pure function**: every blocker is recomputed from structural evidence (pool refs, worktree registrations, the filesystem, `.orbit`), and nothing is persisted. Any re-run re-derives — an interruption cannot corrupt validation results because there is no validation state to corrupt.

Which guard binds in which mode:

| Guard | non-force | `--force` | `--dry-run` |
|:------|:----------|:----------|:------------|
| Initiation guards (root-level + ancestry) | refuses | refuses | refuses |
| `done` requirement | refuses | refuses | only done candidates are previewed |
| Data guards (dirty / foreign / jots / damaged) | refuses the workspace | released, with the irreversibility notice | evaluated, reported as `would skip` |
| Branch verdicts (three layers) | block the workspace | released (`-D`) | evaluated and reported |
| Branch-set enumeration failure (a pool repo's refs cannot be scanned) | refuses the workspace | **refuses** — `--force` accepts consequences, it cannot supply the branch set git failed to enumerate | reported as `would skip` |
| Execution failure semantics (keep + resume) | applies | applies | n/a — no execution |
| Irreversibility notices | n/a | announced before the act | n/a |

Three things yield to no flag: where the invoking session stands (initiation), whether the human recorded "finished" (`done`), and whether the branch set could be enumerated at all (every other "cannot read" guard fails closed too — an unreadable `git status` counts as dirty, an unreadable `.orbit` as holding jots). Everything else is exactly one flag's worth of consequence acceptance — and the whole blocker set is reported together, so that decision is made once, not rediscovered one reason per run.

#### Evidence Classes

The guards decide from three kinds of evidence, and they are not equally trustworthy:

| Evidence | Location | Who can change it | Carries | On loss |
|:---------|:---------|:------------------|:--------|:--------|
| `<ws>/.orbit` | inside the workspace | any agent working there | `done` marker, jots, PR URLs | the workspace leaves automatic reclamation entirely |
| `<ws>/<repo>/.git` (gitdir pointer file) | inside the workspace | any agent working there | *this directory is a pool worktree* | the directory would read as ordinary content — caught as a damaged worktree |
| git refs, worktree registrations | in the pool, maintained by git | only a direct write into `.repos/` | branch ownership, worktree registry | out of scope |

**Every guard that reads workspace-side evidence fails closed on absence** — "cannot tell" is never "safe to delete". Reclamation follows the mirror rule: it derives *only* from pool-side evidence (git refs, the worktree registry, the filesystem), never from `.orbit`, because the decision to reclaim something must not depend on a file that thing could have deleted.

#### Initiation Guards — Both Modes, Never Waivable

- **Root-level only**: prune refuses to run when the CWD is inside any workspace — cross-scope destructive ops belong to the scope above (workspace = agent scope boundary). The comparison is on physical paths, so a symlinked cwd cannot slip past. The refusal replays the intended command (`cd <root> && orbit prune <args>`), but only when the ancestry is readable and confirmed clean (next guard); when the ancestry is unreadable the replay is dropped and the refusal states the fact alone.
- **Initiation-context protection (target-independent)**: prune refuses the whole invocation — named target and enumeration alike, one message — when any ancestor process's cwd is inside ANY workspace, at any depth (where the process tree stands, not which workspace is targeted). The check walks the process ancestry (per-ancestor cwd via `lsof` on macOS, `/proc/<pid>/cwd` on Linux; ppids from `/proc/<pid>/stat` when available, else `ps`) instead of trusting any shell's CWD — a shell can `cd`, but a session's launch directory stays on its process tree. Workspace detection is **structural**: any non-reserved direct child of the root (`.repos` and dotdirs excluded). It deliberately does **not** require a `.orbit` marker — workspace metadata is disposable (Principle 3), and a guard that a lost `.orbit` could silently disable would be no guard; a plain junk directory at the root is treated as workspace-like and refused too. The walk is best-effort and **announces its own blind spot**: with not one ancestor cwd readable (no `/proc`, no `lsof`, no usable `ps`), prune says the guard is inactive rather than proceeding as if it had checked (`orbit doctor` reports the facility too).

Rationale: the pre-guard cwd check ("skip the workspace you are currently in") was self-defeating — its skip message told an agent exactly how to route around it (`cd` out and prune by name), and `git worktree remove --force` destroyed uncommitted changes with no check at all.

#### `done` Is an Absolute Precondition

No flag and no argument form waives the `done` requirement. Not `--force`, not naming the workspace explicitly. The distinction is between kinds of evidence, not degrees of confidence — the data guards answer "would this destroy something irreplaceable?", which orbit can decide from the filesystem and from git; `done` answers "did the human decide this work is finished?", which nothing but the human can answer. `--force` is vocabulary for accepting a consequence, never for supplying an intent that was never recorded. Three states, one message each:

| `.orbit` | Recorded intent | Prune |
|:---------|:----------------|:------|
| present, `status = done` | "finished" | ordinary candidate |
| present, `status ≠ done` | "not finished" | refuses — `<ws> exists but is not marked done` — a recorded intent is never overridden |
| missing or unparseable | none | refuses — `<ws> exists but workspace metadata is missing or unreadable` |

The two refusals are distinct because the facts differ: the first is a recorded intent (never overridden), the second is a lost cache (cheap to rebuild — `orbit done` inside the directory re-declares the intent; see [spec-metadata](./spec-metadata.md) "Why `status=done` is the sole prune trigger"). Neither message names the remedy: an initiation refusal states the fact and stops; the remedy lives in USAGE and here, never in the refusal line.

**A workspace whose `.orbit` is gone leaves automatic reclamation — deliberately.** The asymmetry with the initiation guard is intentional, not an oversight: workspace *detection* must not depend on `.orbit` (a guard a lost file can disable is no guard), while *reclamation* must, because `done` is an expression of intent that exists nowhere but the metadata, and orbit will not manufacture it. Such a directory is never enumerated and never suggested for deletion — it is indistinguishable from a workspace someone is still using, so proposing it would break the rule that orbit never names a destructive target it cannot confirm.

#### Data Guards — Non-Force Only

- **Uncommitted-changes protection**: a candidate with a dirty worktree (uncommitted or untracked changes) is refused; `--dry-run` reports it as `would skip`. An unreadable `git status` counts as dirty — "cannot tell" is not "clean".
- **Foreign-repo protection**: a candidate holding a top-level git repo with no pool counterpart is refused. A pool worktree always has a `.git` *file* (gitdir pointer), so a `.git` *directory* is an independent clone even when it sits under a pool repo's name — typically a `git clone` run inside the workspace. Its objects live in its own `.git`, so the workspace removal would destroy history that exists nowhere else — the worktree guards do not cover it.
- **Unmerged-jot protection**: a candidate whose workspace `.orbit` still holds jot entries is refused, with the per-repo counts named. `done` warns about residual jots once; this is the last checkpoint before the queue is destroyed with the directory. An unreadable `.orbit` counts as *holding* jots, same direction as the dirty check — a corrupt marker must not read as "nothing to lose". (A fully missing `.orbit` never reaches this guard: without a `done` marker the directory is not a candidate at all.)
- **Damaged-worktree protection**: a direct child directory that the pool still registers as a worktree but whose gitdir pointer is unusable — `git -C <path> rev-parse --git-dir` fails, which covers a `.git` file that was deleted, truncated or overwritten with garbage — fails every "is this a git repo" test. Without this guard it bypasses the uncommitted-changes guard entirely and is destroyed with the directory unannounced, working tree and all. The pool's registration names the path, so the state is self-evident even though nothing inside the workspace can be trusted: the workspace is refused and the repo named. Prune does not repair it — restoring workspace usability is a separate recovery concern, not the reclaimer's job, and a worktree orbit cannot read is one it must not delete. `--force` proceeds, with the irreversibility notice, so an unrepairable worktree never becomes uncleanable.

Guard scope is the workspace's **top level**: the data guards enumerate every direct child that is a git repo (pool-backed or foreign) plus the workspace `.orbit` — not just the pool-backed worktrees. A repo nested deeper inside a plain subdirectory is outside the guards' view and is removed with the directory.

#### Branch Verdicts — the Three Layers

A candidate's branch set (pool-driven, see above) is verdicted **before any mutation**. The verdict is a pure function per branch, cost-ordered:

| # | Condition | Verdict | Rationale |
|---|-----------|---------|-----------|
| 1 | A recorded PR covers **this branch**: repo-matched (the URL's host/org/name triple against the pool repo's origin, ignoring scheme, user, `.git` suffix and case), `headRefName` equals the branch's **recorded upstream** (`branch.<name>.merge`, written by `orbit switch`/`add` — never a name mangling, so multi-segment names like `feat/login` map correctly), `gh` reports it merged, and the local tip is contained in the PR head (`merge-base --is-ancestor`, local objects only) | delete with `-D` | Externally confirmed merged; containment proves no post-push local commits would be lost |
| 2 | Merged into `origin/<default-branch>` (`merge-base --is-ancestor`) | delete with `-d` | History-level containment, git's native protection |
| 3 | Content proven upstream: `git merge-tree --write-tree origin/<default> <branch>` merges cleanly and yields exactly `origin/<default>`'s tree (git ≥ 2.38) | delete with `-D` | Content-level containment — the squash/rebase case: SHAs are rewritten so layer 2 can never fire, but a clean merge producing zero tree change proves the branch adds nothing |
| — | None of the above | **keep** — a blocker for a live workspace, a per-item keep for a ghost | Cannot confirm, no risk taken |

Layer 3 is what keeps the common case moving. Squash and rebase merges rewrite SHAs, so layer 2 never fires for them, and layer 1 needs both recorded PRs and `gh`. A squash-merged branch on a machine without `gh` — or a ghost, which carries no recorded PRs at all — is still provably zero-risk by tree equality, and deleting its reference loses nothing. Layer 3 needs git ≥ 2.38 and a clean merge; below that, or on a conflicting merge, the branch falls through to keep. `git cherry` is deliberately **not** a verdict layer: patch-id equivalence is 1:1 per commit and proves nothing about the final tree, so it stays a report hint (below). `merge-tree --write-tree` writes a few tree objects to the ODB (an invisible git-internal cache, also under `--dry-run`); verdict purity is about refs and files, not the object cache.

Layer 1 is **per-branch, never per-workspace**. The `pr.url` list in `.orbit` is flat, so the mapping is reconstructed at verdict time; a PR matching no branch in the set is ignored, and a branch matched by no merged PR falls through to layer 2. The branch side of the match is the **recorded upstream** (`branch.<name>.merge`), not the branch name: a branch with no recorded upstream — e.g. one raw-git created in the scoped shape — never fires this layer and falls through to layers 2/3 (the safe direction). The containment check is what licenses `-D`: without it, a merged PR would bless deleting unpushed local commits. Layer 1 activates **automatically** — no flag: whenever the workspace recorded PR URLs and `gh` is available, the evidence is used. `gh` absent or a call failing → one stderr warning that PR evidence was skipped, and verdicts degrade to the git layers. No recorded URLs → `gh` is never called (zero external dependency path). Results are cached for the whole run — the calls are network-bound, and a refused workspace must not pay for them twice (validation + execution); a workspace already blocked by a data guard is not verdicted at all. A ghost carries no `pr.url` (its `.orbit` died with the directory), so layer 1 never fires for ghosts — layers 2 and 3 are its whole verdict set.

A kept branch's report line names the case: when layer 3 could not answer (git < 2.38, or a conflicting merge) but `git cherry` finds every commit patch-equivalent upstream, the line says the content reads as already upstream (squash/rebase merge?) and prints the exact `git -C ".repos/<repo>" branch -D "<branch>"` cleanup command; otherwise it prints the review command `git -C ".repos/<repo>" log origin/<default>..<branch>`. An unresolvable upstream never fires the hint. Review commands use each repo's actual default branch (`orbit_default_branch`); when it cannot be determined, the review range is omitted. Every suggested command is shell-quoted (`%q`) — ref names may carry metacharacters and the receiver copy-pastes them.

#### All-or-Nothing

Any blocker — a data-guard reason, a damaged worktree, or a kept branch — means **zero mutation for that workspace**: no worktree removed, no branch deleted, nothing renamed. All applicable reasons are reported **together** (one skip line joins the data-guard reasons with `; `; each kept branch adds its own review/hint line), because `--force` releases them as a single decision and the operator needs the whole set to make it once. Workspaces block independently: one refused workspace never stops the enumeration of the rest.

This is the CLI-conventional shape for a single logical unit — validate everything, refuse wholly, change nothing (`git checkout` aborts the whole checkout over one overwritable file; `git worktree remove` refuses when dirty; terraform plans then applies). The enumeration layer uses the independent-objects convention (`rm a b c`): one refusal does not block the others.

#### `--force`

`--force` releases the data guards, the damaged-worktree guard, and the branch verdicts — the same pipeline then runs with `-D`. It does **not** release the initiation guards (they protect where the running session stands, not data the user can choose to discard) and it does **not** release the `done` requirement. Both modes share the identical end state — every associated resource of the workspace disappears; they differ only in the gate, the `git -d`/`-D` shape.

### Execution Phase and Failure Semantics

**Verdict and execution are separate functions.** The verdict side is pure (no mutation, no output beyond the verdict); the execution side deletes according to the decided verdict. Cheap layers (`merge-base`, `merge-tree`/`git cherry`) may re-run in execution — verdicts are stable. Layer-1 `gh pr view` results are cached for the whole run — they are network calls, and a refused workspace would otherwise pay for them twice.

Every step is **idempotent**, and every failure mode leaves a state the next run recognizes:

- **D1 worktree remove**: failures split by cause. "Is not a working tree" (never registered) leaves nothing git-side, so the pipeline proceeds. Any other failure (locked, IO) means git still tracks the directory; deleting the directory would leave a registration pointing at a vanished path, and every later deletion of that branch would refuse (`used by worktree at <gone path>`) — so the whole workspace is kept and reported. Directory removal runs only when git has no stake in the outcome.
- **D2 branch delete**: a git refusal forwards **git's first line only** on stderr (its `hint:` continuations name `git branch -D` — the bypass instruction a refusal must not hand out; see spec-warnings.md → Refusals and skips), and the **whole workspace is kept** (no rename) — an execution failure, not a validation outcome. "Kept" names the directory and whatever elements remain: worktree directories already removed at D1 do not come back (they passed the dirty guard), and the next run re-enters through the ordinary candidate row — D1 on them reports "not a working tree" and proceeds. Two refusals are retryable and retried exactly once: a stale worktree registration (clean the confirmed-dead path, retry), and — for branches the merged layers already proved upstream — `-d`'s "not fully merged", which measures against the local default checkout rather than `origin/<default>` and so lags after a fetch; that one is retried with `-D`.
- **D3 convergence**: best-effort, convergent by construction; leftover config sections are re-derived and the managed fetch keys are re-asserted on the next run.
- **D4a rename**: a failure (EXDEV on a mount point, permissions) keeps the workspace in place, reports, and exits non-zero.
- **D4b trash removal**: unordered deletion; a failure reports, exits non-zero, and is resumed by the next run's opening sweep. The workspace is already out of the namespace, so the message is not a "skipping" line.
- **Scan failure**: a git error while enumerating refs reports `cannot scan branches — residue check skipped for this repo` instead of reading as "no branches". A blind scan never passes as empty.

**Interruption resumability invariant**: an interrupted non-force run can always be continued by invoking non-force prune again; force holds trivially (no validation can block it, so a re-run converges). The proof has three legs: validation is a pure function (nothing persisted, nothing to corrupt); every execution step is idempotent (D1 on a removed worktree reports "not a working tree" and proceeds, D2 collects only existing refs, D3 converges, D4b is an unordered `rm`); candidacy survives every interruption point (before the rename: directory + `done` marker; after it: the trash entry, self-describing as deletion-in-progress and resumed by the opening sweep).

One honest boundary: **a file-level partial failure inside D1** (`git worktree remove` deleted half the working tree, then hit permissions/IO) leaves a worktree that re-validation reads as dirty, so non-force refuses. That state is indistinguishable from genuine uncommitted work without a persisted checkpoint, which the design deliberately refuses to keep — the exit is strategy 1: report, human review, `--force`. An interrupted execution destroyed the workspace's integrity; the ordinary path no longer applies.

**Exit status.** A validation refusal is expected operation, not an error: a run that only refuses workspaces exits 0. A step that *failed* exits non-zero (worktree removal, branch deletion, rename, trash removal). Refusals that abort the invocation (root-level, ancestry, no such workspace) exit non-zero as before. Scripts and agents can therefore read a non-zero exit as "something did not work", never as "something was protected".

### Residue Cleanup and Maintenance Self-Heal

Residue is produced **externally** — an agent force-deleting a workspace directory, a manual `rm -rf`, pre-redesign versions of prune. Prune itself never produces residue (all-or-nothing); it only cleans it. All residue handling derives from the structural truth sources (git refs, the worktree registry, the filesystem) — no metadata store is consulted.

- **Ghost groups** (scoped branches `<prefix>/<ws>/…` whose directory is gone): convergent per-item cleanup through the git verdict layers (2 and 3 — a ghost carries no recorded PRs, so layer 1 never fires): merged → deleted, unmerged → kept and reported, `--force` → force-deleted. A targeted `orbit prune <ws>` with no directory but residue branches processes the ghost group instead of erroring. **The report of one ghost group lists the deleted and the kept branches in the same block** — never counts alone. Run N's report is complete *for run N*; with `(was <sha>)` on every deletion line, the deleted half doubles as the recoverable record. No history is persisted across runs (it would break the pure-function premise validation stands on; a history store would be a new agent-writable element needing its own guards — a new residue source; and merged content is upstream anyway, so cross-run records belong to terminal scrollback and CI logs, not to orbit). Note the two counts differ in kind: a ghost's kept count **decreases across runs** (each run cleans the merged part), while a live workspace's changes only by human action — a reader must not read a dropping ghost count as "something was silently deleted". The group block — header, deletion lines, kept lines — is report content on **stdout** in dry-run and real runs alike; only true errors (scan failures, deletion refusals) go to stderr. The two halves must stay adjacent, and a channel split would silently un-adjacent them.
- **Untraceable raw branches** (not scoped-shaped — a single-segment `<prefix>/<name>` does not qualify — no `origin/<name>` copy, not checked out in any worktree): report only, never deleted by orbit — listed with merged status and the exact native `branch -D` command for the human operator, grouped by repo. Raw-mode branches and branches created under a former prefix only ever appear in this report — no automatic deletion path exists for them.
- **Worktree registry self-heal**: a registration whose gitdir target is gone (`git worktree list --porcelain` reports it `prunable`; equivalently, `<path>/.git` is absent) splits by whether the worktree **path** itself still exists. Path gone → **stale registration**, repaired automatically with no `--force`: leaving it would make every later deletion of that branch refuse forever, and nothing else surfaces it once the branch is gone (the branch-deletion retry only fires while a branch still exists to be refused). Path present → a **damaged worktree**, which validation refuses; the registration is deliberately left intact, because it is the only evidence that makes that state recognizable at all. `git worktree prune` alone cannot tell the two apart, so it is never run bare; orbit prunes by confirmed-dead path only, and maintenance is never repaired at the cost of un-persisted content. Exactly what a stale-registration removal touches (admin directory only — never objects, content, refs, or live registrations) is enumerated in [spec-worktree](./spec-worktree.md) → Prune's Git Binding.
- **Orphan branch config**: `branch.<name>.*` sections whose branch no longer exists are dropped in the same pass — three config lines describing a branch that is not there, reconstructible by the next `orbit switch`. Left in place, a stale `branch.<name>.merge` can make an untraceable branch look traceable and suppress its report. Two branches never count as orphans even when refless: a branch checked out in a non-pool worktree (unborn push routing in use), and the pool HEAD's target branch — possibly unborn, e.g. an empty repo's clone-written default section — whose config is first-push routing, not residue.
- **Branches left outside `branch.prefix`**: a local branch shaped like this workspace's (`*/<workspace>/*`) but outside the configured prefix is named rather than silently left behind — it is not orbit's to delete (a raw-mode branch, or one created while the prefix held another value). Git holds the branch names, so they remain the recoverable record even if the config that named them is lost.
- **Pool config maintenance** belongs to this family: a pool's managed config keys are re-asserted on every prune path, so a run with no live candidate still converges them. The contract is in [spec-worktree](./spec-worktree.md) → Config Ownership and Touchpoint Fetch Discipline.
- **Closing block**: after the whole report, every workspace with kept content — a validation refusal (live) or a kept ghost branch — gets one force-delete suggestion (`orbit prune <ws> --force`), gated behind the single confirm-useless caveat; raw-branch `branch -D` commands follow last.
- **`nothing to prune`** prints only when there are no live candidates, no ghosts, and no untraceable branches. Trash contents are not candidates — they are resumed deletions — but a run whose opening sweep cleared anything does not print it either: the sweep's summary line already reported the work.

### Recoverability

The pipeline compresses the irreversible surface to two points — nothing before the commit point is irreversible:

| Step | Recovery | Irreversible part |
|:-----|:---------|:------------------|
| D1 worktree remove | none needed — `orbit add` recreates it | — |
| D2 branch delete (`-d` / `-D`) | `git branch <name> <sha>` from the report's `(was <sha>)`, while the objects survive gc (`gc.pruneExpire`, two weeks by default — a deleted branch's own reflog is deleted with it, so the 90-day reflog window does **not** extend post-deletion coverage) | anything gc has already collected |
| D3 drop `branch.<name>.*` / converge the fetch config | re-set, or re-asserted by the next touchpoint | — |
| D4a rename | the directory sits whole in the trash, undeleted | — |
| D4b `rm -rf` the trash entry | tracked content: the remote copy | ignored files, non-repo content, detached-HEAD commits — **permanently** |

Two consequences the reports must carry. Every deletion line names the commit it removed (`(was <sha>)`, resolved before the deletion; the suffix is omitted entirely rather than left empty if the ref cannot be resolved): suppressing git's own `Deleted branch …` chatter is deliberate — the report owns the wording — so the report has to carry the one piece of that line with information in it, or the recovery handle is lost with it. And `--force` releasing a guard over content that cannot be recovered is announced before the act, in two forms: for a workspace the uncommitted-changes guard would have refused, and for a **damaged worktree**, where orbit cannot read what is at stake at all — the least verifiable case must not be the quietest one. Both are statements of consequence, not ways around a refusal. E8 covers the other half: prune deletes references, never objects, so a wrong deletion stays recoverable until gc collects them.

### Out of Scope — What Prune Does Not Protect

Naming these is part of the contract. A reader told that "uncommitted changes are guarded" would otherwise assume every un-persisted byte is:

- **`.gitignore`d files** — neither uncommitted nor untracked, so `git status` does not report them and no guard sees them. Agent scratch output frequently lands here. Recovery: none.
- **Non-repo content at the workspace top level** — the data guards enumerate direct children that are git repos, plus `.orbit`. A hand-written note or a `scratch/` directory has no guard and no report. Recovery: none.
- **Stashes** — `refs/stash` lives in the pool's common dir, so a stash survives the prune, but `git status` never reports it and the workspace it belonged to is gone: the entry outlives its attribution.
- **Detached-HEAD commits** — the branch protections assume work sits on a branch. A worktree left detached has commits no ref points at; deregistration makes them unreachable. Recovery: a new ref on the SHA if it was noted, else `git fsck --lost-found` — while the objects survive gc.
- **Concurrency** — orbit assumes one operator, one session, and takes no lock. The initiation guard covers a process whose *cwd* stands inside a workspace; it cannot see a process whose cwd is elsewhere while it writes into one (an editor, a build, a background agent).
- **Direct writes into `.repos/`** — the pool's internal structure is git's to maintain. Rewriting refs or worktree admin files by hand is outside every guard; recovery is re-cloning, since the objects are on the remote.
- **Content moved into `.prune-trash/` by hand** — the opening sweep deletes trash contents without validation; the "definitionally garbage" guarantee holds by exclusion (only the post-D1–D3 rename enters). Same class as direct writes into `.repos/`.
- **A workspace directory that is a mount point** — rename fails with EXDEV; the workspace is kept and reported (safe degradation). Cross-device moves are not attempted.
- **A process parked inside `.prune-trash/`** — the ancestry guard's structural workspace detection excludes dotdirs, so the guard does not see it and the sweep deletes the ground under it. Bounded (the contents are definitionally garbage); named here so the confused failure of that process is not mistaken for an orbit bug.
- **A filesystem that is not present** — every reclamation decision keys on presence: a workspace directory that is absent reads as reclaimed (ghost), a worktree path that is absent reads as a stale registration. A transiently unmounted volume or an unreachable network path therefore reads as "gone". The worst case is bounded — maintenance is repaired, no content is touched, and `orbit add` rebuilds — but prune assumes a present, stable filesystem and does not verify it.

## Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `ORBIT_ROOT` | Overrides project root auto-discovery, explicitly specifies the project root path | None (traverses upward from CWD looking for `.repos/`) |
| `ORBIT_EDITOR` | Editor used to compose free-form text (goal, jot, memo) when no argument/stdin is given; also forces editor mode in non-TTY contexts | Falls back to `VISUAL`, then `EDITOR`, then `vi` |

`ORBIT_ROOT` use cases:
- CI/CD environments where CWD is not under project root
- Scripts that need to explicitly specify the operation target

## Branch Prefix (`branch.prefix`)

The scoped-mode branch prefix contract lives in [spec-worktree](./spec-worktree.md) → The Prefix — it is part of the branching strategy (the name encodes the workspace so prune can attribute branches after the directory is gone), which is why prune matches on `refs/heads/<branch.prefix>/<workspace>/`.
