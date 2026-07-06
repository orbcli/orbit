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

Memo is a finite-capacity knowledge cache, not an ever-growing document. Each session incrementally maintains what previous sessions built rather than rewriting.

### Capacity Budget

~80 lines. Cold start writes ~40 lines (half capacity), reserving space for knowledge accumulated by subsequent sessions.

### Creation (Cold Start)

Written when the memo is missing or low quality. The goal is just enough for the next agent to avoid starting from scratch — not completeness. Write only the most relevant 3–4 sections (brief + entry points + module boundaries + build commands).

### Incremental Update

When the agent discovers new knowledge: read existing memo -> minimal edit -> write back. Correct errors, append new knowledge, do not rewrite content that is still accurate. `orbit memo` at the CLI level is still a full stdin write; incremental logic is enforced at the agent skill layer.

### Compression

When memo exceeds budget, the agent evaluates each section's value to future sessions, judging whether to retain, compress, or discard based on three dimensions:

| Dimension | High Value (Retain) | Low Value (Compress or Discard) |
|-----------|--------------------|---------------------------------|
| **Inferrability** | Requires deep exploration to discover (hidden conventions, cross-repo call chains, pitfalls) | Can be directly inferred from file names/directory structure/code |
| **Cross-session universality** | Useful for any task (entry points, build commands, module boundaries) | Details specific to the current task only |
| **Reconstruction cost** | Rediscovery requires significant time (multi-file tracing, trial and error) | Can be recovered with a single grep or ls |

Low-value sections can be deleted entirely; medium-value sections compressed to 1-2 line summaries; high-value sections retain details. Brief (first paragraph) is never compressed.

Specific behavior rules are in `skills/CONSTRAINTS.md` Memo Write-back Rules.

## Agent-Driven Knowledge Generation

Metadata generation is not a side effect of orbit commands, but a natural output of the agent workflow:

- `orbit clone` only records url + head (machine-determinable facts)
- The agent discovers via `orbit repos` → understands via `orbit info` → adds via `orbit add` → gains understanding through actual work
- During work, the agent records discoveries via `orbit jot "one-liner"` — lightweight queue (~20 tokens per entry vs ~500 for full memo read-merge-write)
- At natural breakpoints (wrap-up before done, or jot overflow warning at >10 entries), the agent aggregates: `orbit jot <repo> --pop` → `orbit info <repo>` → merge entries into memo → `orbit memo <repo>`
- **Memo describes the pool repo's stable (main) branch state, not feature branch state.** The agent does not update memo while on a feature branch; after PR merge + `orbit sync`, it evaluates whether memo needs updating based on structural changes

This is why orbit does not auto-generate memos at clone time: machine-generated summaries without code understanding have low value — better to let the agent produce them naturally during work. Similarly, staleness hints only report distance numbers without auto-triggering updates — the timing and quality of updates are determined by the agent based on actual work. The jot queue further reduces the cost of knowledge capture: recording a discovery is cheap enough to do immediately, while the expensive memo merge is deferred to a natural breakpoint.

### Memo gap guarantee (seed jot + gap model)

The weakest link in agent-driven knowledge generation is the no/low-memo repo: an agent adds it, does the work, never jots, and finishes — leaving the pool repo with no reusable context, and compaction erases any in-context "write the memo later" intent. Orbit closes this with a durable seed plus a layered guarantee that survives context loss:

- **Seed (CLI).** When `orbit add` sees a thin/missing memo (missing, or fewer than `ORBIT_MEMO_THIN_LINES` ≈ 12 non-blank lines), it appends one `[seed] ...` jot entry (once per repo). The seed lives in `.orbit`, not agent context, so it survives compaction.
- **Gap definition.** A repo in the workspace is a **gap** when its memo is thin **and** it has no non-`[seed]` jot entry. The `[seed]` prefix is essential: a seed keeps the jot queue non-empty (so wrap-up `--pop` always resurfaces the instruction) without falsely counting as real capture that would close the gap. A single real jot closes the gap. `orbit context gaps` reports the current gap set (`--json` for tooling).
- **Layered response (detection lives only in the CLI; response is redundant).**
  - *Skill* — instructs the agent to explore + jot + write a memo, and to drop `[seed]` lines at aggregation (model-driven; may be ignored).
  - *Hooks* — `Stop` nudges once per gap repo before the agent finishes; `SessionStart:compact` re-surfaces gaps after context loss (work even if the model ignores the skill).
  - *CLI gate* — `orbit done` warns for any remaining gap (the backstop when no hooks and no skill compliance).
- **`[seed]` is never memo content.** It is a system instruction; aggregation drops it rather than folding it into the memo.

### Capture vs. aggregate under delegation

The capture/aggregate split is also the delegation boundary (see PRINCIPLES.md Principle 7). `jot` is append-only and concurrency-safe, so a **worker sub-agent** captures discoveries directly during its own work — this is how knowledge found inside a worker's context survives after that context is gone. `memo` write-back is read-modify-write (concurrent writers lose updates), so aggregation stays with the **owner agent**, who folds popped jot entries into memo serially at wrap-up. A read-only worker that cannot run `orbit` instead reports discoveries back for the owner to jot.
