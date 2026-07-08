# Orbit Design Principles

This document records Orbit's design motivations, goals, core principles, and key decisions. All spec documents derive from these principles.

## Design Motivation

### Agents need to verify and work on real source code

AI coding agents rely on API knowledge from training data, but training data goes stale — API signatures change, parameters get deprecated, behavioral details shift. Code written against nonexistent or changed APIs at best fails to compile, at worst exhibits silent runtime bugs. Even for single-repo projects, the accuracy of dependency library APIs is a critical bottleneck for agent output quality.

Solving this requires letting agents verify directly against complete dependency source code — grep API signatures, read implementation details, trace call chains, review test cases — rather than relying on stale training data or fragmented documentation searches.

But verification is only half the story. An agent's full work cycle is read → understand → modify → commit → push. Code indexing and RAG only provide read-only retrieval — requiring two separate mechanisms for reading and writing creates a gap. The ideal solution unifies both: the directory where the agent consults source code is the same directory where it modifies code and pushes PRs.

### Multi-repo coordination still has gaps

In practice, a single task often spans internal business repos, PRD/config repos, and community repos like Kubernetes/Koordinator/Hadoop. While single-repo agent workflows are relatively mature, multi-repo coordination still has clear gaps:

| Tension | Description |
|:---|:---|
| Isolation vs. Aggregation | Agents need task-scoped visibility, but developers need cross-repo references and joint debugging |
| Uniqueness vs. Multiple Views | A repo can't have multiple source copies, but different tasks need different repo combinations |
| Automation vs. Review | Agents need autonomous Git operations, but developers still need diff, review, and PR workflows |
| Lightweight vs. Reproducible | A solo developer wants simple structure with no config overhead; sharing a setup across machines or teammates needs reproducibility |

### Combined Requirements

Therefore, a solution must simultaneously satisfy:
1. Complete dependency source code serves as a verifiable, modifiable knowledge source for agents
2. Agents can decide which knowledge they need autonomously (no human pre-configuration)
3. Multiple repos organized by task, with naturally isolated agent visibility
4. Git and IDEs continue working natively
5. Community repos can switch between release branches for debugging
6. No heavy platform dependencies

And system constraints derived from this model:

7. Each repo has only one local source copy; different tasks share it via worktrees
8. Knowledge produced by agent work is reusable across sessions and team members
9. Agents frequently read/write metadata; missing or corrupted metadata must not block workflows
10. Agents fetch repo information on demand to conserve context window tokens
11. Workspaces have a complete lifecycle — create → complete → reclaim — without growing indefinitely

## Design Goals

| Goal | Description |
|:---|:---|
| Source-driven, read-write unified | Complete dependency source replaces stale training data; each repo worktree has full read-write capability — dependencies are primarily used for verification (grep, read implementations), owned repos for development (modify, commit, push), unified in a single directory model — no tool switching |
| Agent self-service | Agents decide which repos they need (browse index → read details → bring into workspace) without human pre-configuration |
| Knowledge accumulation | Repo memos written by agents persist across sessions so a developer's own later sessions skip re-exploration; because memos are plain files in the repo, sharing across teammates falls out for free — a new member's agent reuses existing knowledge |
| Multi-workspace isolation | Each task runs its agent in an independent workspace |
| Multi-repo coordination | A single workspace can contain multiple independent repos simultaneously |
| Single source of truth | Each repo identity maps to exactly one source in the pool; forks use separate push remotes without creating new identities |
| Git-native | Can directly use git worktree / fetch / rebase / push |
| IDE compatible | VS Code / Qoder can recognize each repo's Git status |
| Community repo version debugging | The same community repo can follow different upstream branches in different workspaces |
| Low maintenance cost | No extra YAML/TOML knowledge required as a daily prerequisite |
| Metadata is disposable | Missing or corrupted metadata never blocks workflows; there is always a fallback |
| Progressive loading | Agents fetch repo information on demand (brief → info → source code), conserving tokens |
| Lifecycle closure | Workspaces have a complete lifecycle of create, work, complete, and reclaim — a completed workspace can also be reused by setting a new goal, which reactivates it |

## Non-Goals

Not pursued in the current phase:
- Code indexing/RAG replacement (Orbit provides complete source code directories, not embeddings or tokenized indexes)
- GUI-first experience
- Multi-agent coordination *platform* — peer agents scheduling and distributing tasks among themselves. Note: a single **owner** agent delegating to subordinate **worker** sub-agents *is* supported (see Principle 7); what stays out of scope is peer-to-peer agent orchestration
- Central database or registry
- Automatic PR orchestration
- Complex team permission controls
- Unified abstraction layer for all AI tools

## Design Principles

### 1. Workspace is the primary interaction surface

- Users primarily interact with multiple workspaces
- `.repos/` is the underlying source pool, not the user's primary mental model
- Workspace directory boundary = agent's operational scope; agents access pool knowledge (repos/info) through orbit commands but never see project root paths or `.repos/` internals — a security boundary preventing accidental metadata corruption

### 2. Directory and Git are the structural source of truth, no manifest needed

- Workspaces are real directories, not config files projected onto the filesystem
- Git serves as the source of truth for runtime semantics like remote, upstream branch, ahead/behind, dirty state
- `ls <root>/<workspace>/` is the workspace's repo manifest — no separate manifest file needed

### 3. Metadata is cache, not the source of truth

- All metadata is disposable and rebuildable
- Missing → fallback (read README, `git remote -v`); corrupted → delete and rebuild
- No orbit operation should fail due to missing or incorrect metadata
- **Agents do not directly perceive metadata files** (such as `.orbit`, `.repos/.orbit`, `.repos/.<repo>.md`); they access everything through orbit commands. Orbit commands auto-rebuild when metadata is missing; agents checking files directly would bypass these auto-maintenance capabilities

### 4. Knowledge accumulates progressively, with bounded capacity

Memo is not documentation — it is a cross-session knowledge cache. Design centers on three constraints: context window is finite, knowledge expires, and refresh cost is high.

- On-demand loading: agents spend minimal tokens filtering, load details on demand, then operate — designed for context window economy. The session boot sequence mirrors this — prime (orientation) → ignition (`add` the repos actually needed) → orbit (work, pulling memos on demand) — each stage loads only what it needs
- Bounded capacity: memos have a capacity budget and are maintained incrementally — existing memos represent knowledge from prior sessions; only factual errors are corrected and new discoveries appended, compressed only when exceeding budget
- Sync and memo are decoupled: code freshness and knowledge freshness are separate concerns; sync does not trigger memo refresh
- Knowledge is a natural output of agent work, not a side effect of commands — orbit provides the pipeline, valuable understanding comes from actual exploration
- Discovery capture is decoupled from memo maintenance: recording a finding during work should be cheap (a single line), while the expensive merge into memo is deferred to natural breakpoints — this separation reduces the marginal cost of knowledge capture, making agents more likely to record rather than skip
- Memos describe the stable branch (main) state of pool repos, not feature branch state — preventing temporary code from polluting cross-session knowledge

### 5. Lightweight dependencies, portability first

- Core depends only on git + bash; optional tools (gh, jq) enhance but aren't required
- Builds on Git's existing mental model (worktree, remote, fetch) without inventing new concepts
- Operations achievable with native git inside a workspace are not wrapped — orbit only handles operations that cross the workspace↔.repos boundary

### 6. Foundation-permanent, surface-additive

- The lower layer establishes directory structure, branch naming, and sync rules; upper layers add GUI, tmux, multi-agent, shared config, container isolation as needed
- This is a constraint, not an aspiration: upper-layer features may only *add* to the foundation, never force it to be redone. Any proposed feature that would require changing the directory model, branch rules, or metadata contract belongs in the foundation and must be settled there first — not bolted on above it

### 7. Tiered decision authority for agent operations

Two roles operate a workspace:

- **Owner agent** — the single agent that owns the workspace. It holds the workspace lifecycle (new/done/goal), knowledge aggregation (memo write-back), and pool / cross-workspace operations (clone/sync/config). Exactly one owner per workspace — this single-owner invariant is what keeps shared mutable state safe under concurrency.
- **Worker sub-agent** — subordinate agents the owner dispatches for exploration or implementation. They act on specific worktrees and may follow cross-repo threads autonomously, but never perform owner operations. Workers are the owner's hands, not peer agents.

Operations fall into categories by data recoverability and blast radius, each with different authority:

| Impact Scope | Operation Examples | Owner Agent | Worker Sub-agent |
|---|---|---|---|
| Read / assess | repos, info | Autonomous | Autonomous |
| Lifecycle (metadata) | new, goal setting, done marking | Autonomous | No — report back |
| Knowledge capture | jot | Autonomous | **Autonomous** — append-only, concurrency-safe |
| Knowledge aggregation | memo write-back | Autonomous | No — report back (read-modify-write, lost-update risk) |
| Repo into workspace | add (worktree creation) | Autonomous | **Autonomous** — guarded creation, fails clean on collision |
| Reversible pool change | clone (add repo to pool — can be deleted and recovered) | Autonomous | No — report back (pool-level) |
| Git state (no dependency risk) | cold-start sync (agent hasn't started depending on code yet) | Autonomous | No — report back (pool-level) |
| Git state (with dependency risk) | in-progress sync | Not recommended — sync updates pool, not the active worktree; upstream changes are resolved at PR time | No |
| Remote write (push) | push | Autonomous (native git; orbit takes no stance — gated by permission mode) | No — report back (externally-visible remote write; owner converges) |
| Irreversible structural changes | prune | Propose → human confirms | No |

The delegation boundary follows operation **nature**, not "who loaded the skill": a worker may do read/assess, worktree creation (add), branch work inside worktrees, and append-only knowledge capture (jot), but `push` is not delegable — it is an externally-visible remote write, so the worker commits locally and reports back, letting the owner converge the remote writes. The auto-approve tiers that decide which operations run without a prompt are specified in [`skills/CONSTRAINTS.md`](skills/CONSTRAINTS.md#permission-and-auto-execution-policy) — this principle fixes *who* may act; that document fixes *how* each operation is gated.

Concurrency is the owner's responsibility: serial delegation has no contention; when fanning out parallel workers, the owner partitions work by repo so mutations stay disjoint, then converges aggregation (memo) serially afterward.

## Design Stance

Orbit serves both agents and humans: agents orchestrate orbit commands through integration layers (skills, MCP) to get work done; humans operate and review directly via CLI. The command system is designed around the agent workflow as the primary path, while remaining directly usable by humans — no separate human UI layer.

The priority is the **Git-native base model**, not **multi-agent platform orchestration**.

### Key design choices

- Top-level model uses **project root + `.repos/` + workspace siblings**
- Metadata uses **git-config INI + markdown** dual format for different consumers: INI for zero-dependency programmatic parsing (`git config --file`), markdown for natural agent read/write
- Orbit spans two dimensions — workspace structure and agent knowledge — each with its own lifecycle: structure follows the **new → add → done → (prune | reactivate via goal)** loop — a done workspace is either reclaimed or reused by setting a new goal, which reactivates it — knowledge follows **repos → info → add → work → jot → memo** progressive accumulation; `add` is the intersection point. `sync` is a maintenance operation outside the core lifecycle — it keeps pool code fresh, independent of structural changes and knowledge updates
- Workspace context is implicitly inferred from CWD, reducing command parameters
- Commands remain atomic — each command does one thing, without chaining side effects; complex workflows are orchestrated by integration layers
- stdout is data, stderr is hints — all command warnings, staleness detection, and guidance messages go to stderr, not polluting parseable stdout

These form the foundation — established first so that whatever upper-layer agents or UIs are added later, the underlying model doesn't need to be redone.

## Risks and Controls

| Risk | Control Mechanism |
|:---|:---|
| Workspace count proliferation | `orbit done` + `orbit prune` lifecycle management; reusing a done workspace via `orbit goal` (reactivation) also avoids spawning new ones |
| Oversized community repos | `--single-branch` + sparse-checkout; fetch additional branches on demand |
| Agent boundary violations | Convention-based enforcement: skills prohibit exposing `.repos/` paths; agents start from workspace directory. No technical enforcement — relies on skill constraints rather than sandboxing |
| Rising team sharing costs | Maintain directory-as-configuration; can later add export capability |
| Workspace name conflicts | Workspace names must be single-level path segments, not containing `/`, and must not start with `.` |
| Metadata corruption | Metadata is cache; any missing data has a fallback and can be rebuilt at any time |
| Metadata concurrent writes | Owner partitions parallel workers by repo so mutations stay disjoint; append-only capture (jot) is concurrency-safe by design, aggregation (memo, read-modify-write) stays serial in the owner. File-level locks guarantee single-operation atomicity; unpartitioned races fall back to last-write-wins, with lost entries auto-recovering on next operation |
| Memo quality variance | Brief extraction rules validate format; content quality relies on skill constraints (budget, scaffold template) |
| Knowledge decay without maintenance | `orbit repos` displays memoBehind; agents detect staleness on cold start; refresh is not forced |
| Pool repo count proliferation | No automatic cleanup yet; `orbit doctor` provides environment checks, extensible to detect unused repos |
| Prune mid-failure | A single repo failure is skipped with a warning without interrupting subsequent repos; residuals can be manually recovered |

## Rationale for Solution Choices

### Comparison of three underlying approaches

| Dimension | This approach: project root + `.repos` + workspace | Manifest-first | Reference clone-first |
|:---|:---|:---|:---|
| Learning cost | Low | Medium | Medium |
| Configuration maintenance | Low | High | Medium |
| Git nativeness | High | Medium | Medium |
| IDE compatibility | Good | Good | Best |
| Manual recoverability | High | Medium | Medium |
| Team reproducibility | Medium | High | Medium |

### Why not manifest-first

The advantage of manifest-first is that workspace compositions can be versioned and team sharing is more direct. The cost is that config files introduce extra mental overhead and can drift from actual directories. The goal is to make workspaces first-class citizens, not configs.

### Why not symlinks

Symlinks are not used: Git and IDE recognition is unstable, they don't solve branch isolation, and agent boundaries become inconsistent with filesystem boundaries. `git worktree` provides a real working directory, real Git status, and real branch boundaries.

### Why not code indexing/RAG

Read-only retrieval can't cover the agent's need to modify code and push PRs — requiring two separate mechanisms for reading and writing creates a gap. Complete source code is also better suited than fragmented embedding matches for tracing call chains and verifying API signatures. The cost is higher token consumption, controlled through progressive loading (brief → info → source code).

### Why not a database for metadata

Files (git-config INI + markdown) have zero dependencies, are disposable, manually editable, and need no daemon. Metadata is cache, not the source of truth — database ACID guarantees are over-engineering for rebuildable data. Markdown lets agents read and write naturally without a serialization layer.

### Why knowledge is written by agents rather than auto-generated

Auto-summarization (README extraction, AST analysis) produces mechanical descriptions lacking the hidden conventions, cross-repo call chains, and pitfalls that only emerge through actual work. Orbit makes memos a natural output of agent work — it provides the pipeline (scaffold template, capacity budget), while valuable understanding comes from actual exploration. On cold start memos are empty, mitigated by fallback (README first line).

### Why knowledge is attached to repos rather than workspaces

Memos are bound to pool repos (shared across workspaces), not to individual worktrees. Workspaces are short-lived (reclaimed when tasks complete); repos are long-lived — knowledge should persist with the long-lived entity. This lets repo understanding written in one session be reused in any subsequent workspace, rather than being lost on prune.

### Why conventions rather than sandboxing to isolate agents

Agents not accessing `.repos/` directly is enforced through skill constraints, not filesystem permissions or container sandboxing. Sandboxing introduces runtime dependencies (container runtime, filesystem ACLs), violating the lightweight portability principle. Under the current single-owner model (one owner plus the subordinate workers it briefs), conventions suffice — agents get everything they need through orbit commands with no incentive to circumvent. Stronger isolation (sandboxing) can be layered on for peer multi-agent scenarios.