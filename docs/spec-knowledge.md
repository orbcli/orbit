# Knowledge System

> Detailed behavior definitions for progressive loading, staleness detection, sync-memo cascading relationship, memo lifecycle, and agent-driven knowledge generation.

The core problem: agents need structural understanding of repos to work efficiently, but context windows are limited, knowledge goes stale as upstream changes, and refresh is expensive. Orbit controls information volume through progressive loading, exposes freshness through staleness detection, and manages accumulation through memo lifecycle.

## Progressive Loading Model

Agents fetch repo information on demand, drilling down level by level, autonomously deciding how much context they need:

```
Level 0:   orbit repos              <- global index: name + url + brief + memoBehind (purely local)
Level 1:   orbit info <repo>        <- per-repo markdown full text + fetch + two-layer staleness detection
Level 2:   orbit add                <- worktree enters workspace
Level 3:   agent reads/writes code  <- memo describes pool repo's stable branch (main branch) state
```

Fallback at each level:
- Level 0 index missing -> `orbit repos` automatically scans .repos/ directory + `git remote -v` to rebuild and write index
- Level 0 index has entry but brief is empty -> attempts extraction from per-repo `.md` first line, falls back to README extraction (display only, not written)
- Level 1 missing (no `.md` file) -> `orbit info` indicates no memo; agent can directly add and explore
- Missing data at any level does not block the workflow; it only means the agent needs more exploration steps

## Staleness Detection

Staleness detection has two layers, viewed from the perspective of the pool repo's local branch:

```
memo stored HEAD ---- memoBehind ----> pool local HEAD ---- remoteAhead ----> origin HEAD
```

### Layer 2: Memo Behind Pool HEAD (`memoBehind`)

When `orbit repos` and `orbit info` execute, they compare the index's `head` (HEAD at time of memo write) with the repo's current HEAD:

```bash
stored=$(git config --file .repos/.orbit --get 'repos.backend.head')
current=$(git -C .repos/backend rev-parse HEAD)
if [ "$stored" != "$current" ]; then
  distance=$(git -C .repos/backend rev-list "$stored".."$current" --count)
  echo "orbit: backend: memo is $distance commits behind HEAD" >&2
fi
```

### Layer 1: Pool Behind Upstream (`remoteAhead`)

When `orbit info` executes, it automatically fetches the repo's tracking branch, then compares the local branch with `origin/<branch>`:

```bash
git -C .repos/backend fetch origin main 2>/dev/null
local_head=$(git -C .repos/backend rev-parse refs/heads/main)
remote_head=$(git -C .repos/backend rev-parse refs/remotes/origin/main)
if [ "$local_head" != "$remote_head" ]; then
  distance=$(git -C .repos/backend rev-list "$local_head".."$remote_head" --count)
  echo "orbit: backend: $distance new commits on origin/main" >&2
fi
```

### Design Points

- Both layers output hints to **stderr**, avoiding stdout pollution
- `orbit repos` only checks Layer 2 (purely local, fast); `orbit info` checks both layers (triggers fetch)
- No hard thresholds are set; only distance numbers are reported, leaving the agent/human to decide whether to update
- Layer 2 precondition: `head` field exists **and** per-repo `.md` file exists (no .md triggers the fallback path)
- Layer 1 silently skips on fetch failure (network unavailability does not block viewing)
- `orbit clone` writes basic index fields (url + head) but does not generate per-repo `.md`

## Sync and Memo Cascading Relationship

`orbit sync` collapses Layer 1 (after sync, pool local HEAD = origin HEAD), but simultaneously advances pool HEAD, causing Layer 2's memoBehind to increase — this is **cascading invalidation**:

```
before sync:  memo(HEAD=abc) <-0-> pool(HEAD=abc) <-5-> origin(HEAD=xyz)
after sync:   memo(HEAD=abc) <-5-> pool(HEAD=xyz) <-0-> origin(HEAD=xyz)
```

Code becomes fresh, but memo becomes stale.

**Design decision: sync does not trigger memo refresh.** Code freshness and knowledge freshness are separate concerns:
- After sync, the memo may still be accurate (bugfix-type changes don't affect repo structure)
- Memo refresh is expensive (the agent must re-explore the code)
- Refresh timing is determined by the agent on demand during actual work

Specific agent behavior rules (cold-start sync before add, no mid-work sync prompts, no extra check at wrap-up) are in `skills/CONSTRAINTS.md` Sync Decision Rules.

## Memo Lifecycle

Memo is a **pull-decision card**, not a code survey. It answers exactly two questions so the next agent can decide whether to pull the repo into a workspace and where to start:

1. **When/why add this repo?** — its roles. Plural and unbounded: a repo may fill many roles; list every one.
2. **How do I use it in the simplest way?** — the MVP/VIP file-or-dir paths to start from, each with why it matters and when to reach for it. Also plural — a CLI entry and a core package can both belong here; no cap.

Deep code-structure documentation (module boundaries, data layer, conventions, pitfalls, API enumeration, dependency graphs) is **out of orbit's scope** — that is a code-doc's job. If such a doc exists, add its path to `explore.paths` or bring it into the pool as a workspace member; orbit stays agnostic about its format.

### Capacity Budget

Hard upper bound ~16 lines (`memo.maxLines`). The ceiling is a **compress trigger**, not a target: when the card passes it, curate instead of appending, so the jot → incremental-memo pipeline keeps the card tight rather than letting it re-bloat into a survey. Cold start writes well under it (roles + how-to-use). The soft lower bound `memo.minLines` (~4) is the gap/thin floor: below it, the repo counts as having no real card yet.

### Creation (Cold Start)

Written when the memo is missing or below the floor. The goal is a decision card, not completeness: the roles and the MVP/VIP entry points, nothing more. Cold-start exploration is bounded to `explore.paths` (a `path:depth` list, default root at depth 1; the user can extend it) — enough to name the roles and entry points without surveying the whole tree.

### Incremental Update

When the agent discovers new knowledge: read existing card -> minimal edit -> write back. Correct errors, add a role or entry point, do not rewrite content that is still accurate. `orbit memo` at the CLI level is still a full stdin write; incremental logic is enforced at the agent skill layer.

### Compression

When the card passes the `memo.maxLines` ceiling, curate — don't append. Keep what is costly to rediscover (why a role exists, a non-obvious entry point) and drop what a quick `ls`/grep would reveal anyway. Brief (first line) is never compressed.

Specific behavior rules are in `skills/CONSTRAINTS.md` Memo Write-back Rules.

## Agent-Driven Knowledge Generation

Metadata generation is not a side effect of orbit commands, but a natural output of the agent workflow:

- `orbit clone` only records url + head (machine-determinable facts)
- The agent discovers via `orbit repos` → understands via `orbit info` → adds via `orbit add` → gains understanding through actual work
- During work, the agent records card-relevant discoveries (a role or entry point the card needs) via `orbit jot "one-liner"` — lightweight queue (~20 tokens per entry vs ~500 for full memo read-merge-write)
- At natural breakpoints (wrap-up before done, or jot overflow warning at >10 entries), the agent aggregates: `orbit jot <repo> --pop` → `orbit info <repo>` → merge entries into memo → `orbit memo <repo>`
- **Memo describes the pool repo's stable (main) branch state, not feature branch state.** The agent does not update memo while on a feature branch; after PR merge + `orbit sync`, it evaluates whether the card needs updating — i.e. whether roles or entry points changed

This is why orbit does not auto-generate memos at clone time: machine-generated summaries without code understanding have low value — better to let the agent produce them naturally during work. Similarly, staleness hints only report distance numbers without auto-triggering updates — the timing and quality of updates are determined by the agent based on actual work. The jot queue further reduces the cost of knowledge capture: recording a discovery is cheap enough to do immediately, while the expensive memo merge is deferred to a natural breakpoint.

### The jot → memo reliable-trigger path

Memo value depends on discoveries actually reaching the memo. The path from a discovery to a curated card is designed so that **no single missed step loses the knowledge** — every stage persists to disk (`.orbit`), so context loss (compaction, session end, delegation) cannot silently drop it.

1. **Capture (jot, during work).** jot feeds the card, so its payload is scoped to what the card needs and lacks — a **role** or an **MVP/VIP entry point** the card is missing or gets wrong (deep code structure is out of card scope and is not jotted). The moment such a discovery surfaces, `orbit jot <repo> "…"` appends it to the workspace `.orbit`. Append-only + concurrency-safe → any agent or worker can capture without reading/locking the memo. Cheap enough (~20 tokens) to do immediately, so capture is never deferred "until wrap-up" (where compaction would have erased it).
2. **Trigger (reliable, not memory-based).** Three independent triggers resurface pending captures so aggregation is not left to the agent remembering:
   - *Overflow* — `orbit jot` warns past its threshold (10) entries, naming the `<min>~<max>`-line card budget as the aggregation target.
   - *Wrap-up / done* — `orbit done` warns if any repo still has un-popped jot entries, also printing the `card budget is <min>~<max> lines` reminder.
   - *Gap backstop* — the seed jot + gap model (next subsection) guarantees a no-memo repo keeps a non-empty queue, so the above triggers always fire for it.
3. **Aggregate (memo, at checkpoint, owner-only).** `orbit jot <repo> --pop` drains the queue; the owner folds entries into the card (read-modify-write) and writes back via `orbit memo <repo>`. Curation stays serial and owner-scoped (concurrent writers lose updates); `[seed]` lines are dropped, never folded. When the card passes the ceiling, curate rather than append.

Because each stage lands in `.orbit` before the next, a deferred fold loses nothing: popped entries not yet merged, or captures not yet popped, all persist until a future session drains them. This is why the card can be a deliberately thin cold-start artifact and still converge on real knowledge — the pipeline keeps topping it up during coding.

### Memo gap guarantee (seed jot + gap model)

This closes the weakest link in the path above: the no/low-memo repo an agent adds, works in, never jots, and finishes — leaving the pool repo with no reusable context, and compaction erasing any in-context "write the memo later" intent. Orbit closes it with a durable seed plus a layered guarantee that survives context loss:

- **Seed (CLI).** When `orbit add` sees a thin/missing memo (missing, or fewer than `memo.minLines` non-blank lines, default 4), it appends one `[seed] ...` jot entry (once per repo). The seed lives in `.orbit`, not agent context, so it survives compaction.
- **Gap definition.** A repo in the workspace is a **gap** when its memo is thin **and** it has no non-`[seed]` jot entry. The `[seed]` prefix is essential: a seed keeps the jot queue non-empty (so wrap-up `--pop` always resurfaces the instruction) without falsely counting as real capture that would close the gap. A single real jot closes the gap. `orbit context gaps` reports the current gap set (`--json` for tooling).
- **Layered response (detection lives only in the CLI; response is redundant).**
  - *Skill* — instructs the agent to explore + jot + write a memo, and to drop `[seed]` lines at aggregation (model-driven; may be ignored).
  - *Hooks* — `Stop` nudges once per gap repo before the agent finishes; `SessionStart:compact` re-surfaces gaps after context loss (work even if the model ignores the skill).
  - *CLI gate* — `orbit done` warns for any remaining gap (the backstop when no hooks and no skill compliance).
- **`[seed]` is never memo content.** It is a system instruction; aggregation drops it rather than folding it into the memo.

**Over-budget is the mirror case (surplus, not a gap).** A gap is *absence* — nothing to inherit. The opposite failure is *surplus* — a card that grew past the ceiling and now costs too much to read. Orbit reuses the same seed machinery for it: when `orbit memo` writeback (run inside a workspace) leaves a card longer than `memo.maxLines + memo.minLines`, it appends one `[seed] memo over budget ...` jot and prints an immediate curate-down warning, so the reliable triggers (done jot-remain, overflow, session-start) force a curation pass. The `+ minLines` buffer means best-effort curation that lands slightly over `maxLines` is left alone. A per-repo `[overlong "<repo>"]` throttle stops re-seeding while the card stays over budget (curation is best-effort — orbit forces one pass per episode, not an unbounded loop); it clears when the card drops back under the buffer, or on `orbit goal` reactivation. The over-budget `[seed]` never marks the repo a gap: the memo is well above `memo.minLines`, so `orbit context gaps` ignores it. Gap = explore-and-write; surplus = curate-and-cut — opposite fixes, one shared trigger path.

The gap guarantee is one instance of a broader mechanism: **warnings are orbit's guidance layer** (PRINCIPLES.md Principle 8). Orbit has no enforcement runtime, so it steers the agent through stderr hints — card budget, gap, jot overflow, staleness/sync-behind, tracking notes — that the agent is expected to act on. Warnings *guide*; they do not block (the sole exceptions are explicit gates like `orbit done`'s), and they never pollute stdout, which stays machine-readable data. The complete catalogue and message-format contract live in [spec-warnings.md](spec-warnings.md).

### Capture vs. aggregate under delegation

The capture/aggregate split is also the delegation boundary (see PRINCIPLES.md Principle 7). `jot` is append-only and concurrency-safe, so a **worker sub-agent** captures discoveries directly during its own work — this is how knowledge found inside a worker's context survives after that context is gone. `memo` write-back is read-modify-write (concurrent writers lose updates), so aggregation stays with the **owner agent**, who folds popped jot entries into memo serially at wrap-up. A read-only worker that cannot run `orbit` instead reports discoveries back for the owner to jot.
