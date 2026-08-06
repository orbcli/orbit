# Orbit Design Principles

This document records Orbit's design motivations, goals, core principles, and key decisions. All spec documents derive from these principles.

## Design Motivation

### Agents need to verify and work on real source code

AI coding agents rely on API knowledge from training data, and that data goes stale: signatures change, parameters get deprecated, behavior shifts. Code written against a changed API fails to compile at best, and carries silent runtime bugs at worst. Even in a single-repo project, dependency API accuracy is a bottleneck on agent output quality.

The fix is to let agents verify against complete dependency source: grep signatures, read implementations, trace call chains, check tests — not stale training data or scattered doc searches.

Verification is only half of it. The full cycle is read → understand → modify → commit → push, and indexing or RAG covers only the read half; two mechanisms leave a gap between them. So the directory where an agent consults source must be the directory where it edits and pushes.

### Multi-repo coordination still has gaps

In practice a single task spans internal business repos, PRD/config repos, and fast-moving community repos whose APIs are tightly version-coupled — Kubernetes (client-go), Terraform, gRPC. Single-repo agent workflows are relatively mature; multi-repo coordination still has clear gaps:

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

How Orbit answers each requirement above.

| Goal | Description |
|:---|:---|
| Source-driven, read-write unified | Complete dependency source replaces stale training data, and every worktree is read-write: verify dependencies in place (grep, read implementations), develop owned repos the same way (modify, commit, push). One directory model, no tool switching |
| Agent self-service | Agents decide which repos they need (browse index → read details → bring into workspace) without human pre-configuration |
| Knowledge accumulation | Agent-written memos persist across sessions, so later sessions skip re-exploration. They are plain files, so teammates get the same benefit for free |
| Multi-workspace isolation | Each task runs its agent in an independent workspace |
| Multi-repo coordination | A single workspace can contain multiple independent repos simultaneously |
| Single source of truth | Each repo identity maps to exactly one source in the pool; forks use separate push remotes without creating new identities |
| Git-native | Can directly use git worktree / fetch / rebase / push |
| IDE compatible | VS Code / Cursor can recognize each repo's Git status |
| Community repo version debugging | The same community repo can follow different upstream branches in different workspaces |
| Low maintenance cost | No extra YAML/TOML knowledge required as a daily prerequisite |
| Metadata is disposable | Missing or corrupted metadata never blocks workflows; there is always a fallback |
| Progressive loading | Agents fetch repo information on demand (brief → info → source code), conserving tokens |
| Lifecycle closure | Workspaces run create → work → complete → reclaim. A completed workspace can also be reactivated by setting a new goal |

## Non-Goals

Not pursued in the current phase:
- Code indexing/RAG replacement (Orbit provides complete source code directories, not embeddings or tokenized indexes)
- GUI-first experience
- Multi-agent coordination *platform* — peer agents scheduling work among themselves. One **owner** agent delegating to **worker** sub-agents is supported (Principle 7); peer-to-peer orchestration is not
- Central database or registry
- Automatic PR orchestration
- Prescribing git workflow — commit, branch and push are native git, governed by the agent's permission mode, not by orbit or its skill
- Complex team permission controls
- Unified abstraction layer for all AI tools
- Managing language workspace files — `go.work`, Cargo workspaces and the like work because the directory layout is real, but placing them is the user's or agent's call

## Design Principles

### 1. Workspace is the primary interaction surface

- Users primarily interact with multiple workspaces
- `.repos/` is the underlying source pool, not the user's primary mental model
- Workspace directory boundary = agent's operational scope. Agents reach pool knowledge through orbit commands, never seeing project root paths or `.repos/` internals — a boundary that prevents accidental metadata corruption
- Destructive operations stay inside the scope they were invoked from. The test is destruction, not visibility: reads and additive creation may cross the boundary; destroying what the workspace does not own may not. Memo write-back is the standing exception — knowledge is pool-level by design, and no mechanism yet distinguishes a write that accumulates from one that regresses

### 2. Directory and Git are the structural source of truth, no manifest needed

- Workspaces are real directories, not config files projected onto the filesystem
- Git is the source of truth for runtime semantics: remote, upstream branch, ahead/behind, dirty state
- `ls <root>/<workspace>/` is the workspace's repo manifest — no separate manifest file needed

### 3. Metadata is cache, not the source of truth

- All metadata is disposable and easily rebuildable
- **Agents do not perceive metadata files** (`.orbit`, `.repos/.orbit`, `.repos/.<repo>.md`) — everything goes through orbit commands, which rebuild missing metadata on the way. Reading the files directly bypasses that repair
- Metadata derivable from the structural source of truth (index fields, backfilled timestamps) is rebuilt on the read path — absence or corruption never breaks a command
- Metadata covered by a fallback (briefs, memos) degrades to it on loss (read README, `git remote -v`); corrupted → delete and rebuild
- Recorded human/agent intent (the `done` marker) is derivable from nothing structural, so loss requires re-declaration — and its absence only ever **removes** a capability (the workspace leaves automatic reclamation), never grants one

### 4. Knowledge accumulates progressively, with bounded capacity

Memo is not documentation but a cross-session knowledge cache, shaped by three constraints: the context window is finite, knowledge expires, and refreshing it is expensive.

- On-demand loading: filter cheaply, load details only when needed. The boot sequence mirrors it — prime (orient) → ignite (`add` what's needed) → orbit (work, pulling memos on demand)
- Bounded capacity: memos have a capacity budget (soft floor + hard ceiling) and grow incrementally — fix factual errors, fold in new roles or entry points, and curate instead of appending once the card passes its ceiling. Cold-start exploration has its own configurable scope, so a first touch never surveys the whole tree
- Sync and memo are decoupled: code freshness and knowledge freshness are separate concerns; sync does not trigger memo refresh
- Knowledge is an output of agent work, not a side effect of commands — orbit provides the pipeline; understanding comes from exploration
- Discovery capture is decoupled from memo maintenance: a finding costs one line to record, and the expensive merge waits for a breakpoint. Cheap capture is what makes an agent record instead of skip
- Memos describe pool repos on their stable branch, not feature-branch state, so temporary code never pollutes cross-session knowledge

### 5. Lightweight dependencies, portability first

- Core depends only on git + bash; optional tools (gh, jq, and `/proc` or `lsof` for prune's session guard) enhance but aren't required — a degraded capability says so rather than silently doing nothing
- Builds on Git's existing mental model (worktree, remote, fetch) without inventing new concepts
- Native git inside a workspace is not wrapped — orbit only handles operations crossing the workspace↔.repos boundary

### 6. Foundation-permanent, surface-additive

- The lower layer establishes directory structure, branch naming, and sync rules; upper layers add GUI, tmux, multi-agent, shared config, container isolation as needed
- This is a constraint, not an aspiration: upper layers may only *add*, never force the foundation to be redone. Anything that would change the directory model, branch rules or metadata contract belongs in the foundation and must be settled there first

### 7. Tiered decision authority for agent operations

Two roles operate a workspace:

- **Owner agent** — the one agent that owns the workspace. It holds the lifecycle (new/done/goal), knowledge aggregation (memo write-back), and pool operations (clone/sync/config). Exactly one per workspace: that invariant is what keeps shared mutable state safe under concurrency.
- **Worker sub-agent** — dispatched by the owner for exploration or implementation. Workers act on worktrees and may follow cross-repo threads on their own, but never perform owner operations. They are the owner's hands, not peers.

Authority follows data recoverability and blast radius:

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
| Pool-wide destruction | `sync --force`, `sync --branch` | Propose → human runs it from the project root | No |
| Irreversible structural changes | prune | Propose → human runs it from the project root | No |

The last two rows are the only authority that is **machine-enforced rather than conventional**: each destroys state the calling workspace does not own, so each is refused when the CWD sits inside any workspace. Bare `sync` is unaffected — `ff-only` cannot lose data. An owner agent is by definition inside its workspace, so it proposes and the human executes; the skill therefore carries no procedure for them.

The boundary follows operation **nature**, not who loaded the skill: the table fixes which side each operation falls on, and a worker never performs the owner's shared-state mutations.

The skill's remit is *how and when* to use orbit commands, never the developer's git workflow — commit, branch and push are native git, gated by the agent's permission mode. This principle fixes *who* may act; [`skills/CONSTRAINTS.md`](skills/CONSTRAINTS.md#permission-and-auto-execution-policy) fixes *how* each command is gated.

Concurrency is the owner's job: serial delegation has no contention, parallel workers are partitioned by repo so mutations stay disjoint, and aggregation (memo) converges serially afterward.

### 8. stderr is the steering channel

Orbit is **advisory by design** — it has no runtime to enforce procedure. Apart from explicit gates like `orbit done`, commands guide rather than block, and that guidance travels on **stderr**: card budget, memo-thin nudges, jot overflow, staleness notes, raw-mode tracking, README truncation. It is not decoration but how orbit routes the next right action to an agent it cannot compel.

- The agent is expected to act on these hints as procedure, not noise.
- stdout carries two payload classes: **machine-facing data** by default, and **model-facing context** for the `orbit context` family — readable markdown whose only consumer is the agent or human reading it, forwarded into model context by the session hooks. stderr is the steering channel for every command.
- The memo-surfacing layers (add-time stderr → cruise block → done gate, [spec-knowledge](docs/spec-knowledge.md)) are one instance: warnings guide, never block, never pollute stdout.
- The full catalogue — triggers, named commands, backstops, message format — lives in [spec-warnings](docs/spec-warnings.md).

## Design Stance

Orbit serves agents and humans through the same CLI: agents drive it through integration layers (skills, MCP), humans operate and review directly. It is designed around the agent workflow, with no separate human UI.

The priority is the **Git-native base model**, not **multi-agent platform orchestration**.

### Key design choices

- Top-level model uses **project root + `.repos/` + workspace siblings**
- Metadata uses **git-config INI + markdown**, one format per consumer: INI parses with zero dependencies (`git config --file`), markdown reads and writes naturally for agents
- Orbit spans two lifecycles. Structure: **new → add → done → (prune | reactivate via goal)** — a done workspace is either reclaimed or revived by a new goal. Knowledge: **repos → info → add → work → jot → memo**. `add` is where they intersect; `sync` sits outside both, keeping pool code fresh on its own schedule
- Workspace context is inferred from CWD, reducing command parameters
- Commands stay atomic — one thing each, no chained side effects; integration layers orchestrate the workflows
- stdout is data, stderr is hints — warnings, staleness and guidance never pollute parseable stdout. The refinement: the `orbit context` family carries model-facing markdown on stdout, and since orbit has no enforcement runtime, stderr is the primary steering mechanism, not merely informational (Principle 8)

These form the foundation — settled first, so later agents or UIs never force the underlying model to be redone.

## Risks and Controls

| Risk | Control Mechanism |
|:---|:---|
| Workspace count proliferation | `orbit done` + `orbit prune`; reactivating a done workspace via `orbit goal` also avoids spawning new ones |
| Oversized community repos | `--single-branch` + sparse-checkout; fetch additional branches on demand |
| Agent boundary violations | Conventions cover read/write scope: skills prohibit exposing `.repos/` paths, agents start in the workspace. Destructive cross-scope operations are the exception — refusal is machine-enforced, since a convention is only as strong as the agent's incentive to keep it |
| Guard built on agent-controllable state | Checks key on state the agent cannot change per call — process ancestry, physical CWD, repo contents — not logical CWD, env vars or arguments. Refusals state the fact only: explaining a protection also explains how to route around it |
| Guard scope narrower than blast radius | Each guard enumerates everything the operation destroys, not just what orbit created |
| Branch prefix drift | `branch.prefix` is project config, not per-call state: validated on write, immovable while branches still carry it, and branches left outside it are named rather than leaked |
| Rising team sharing costs | Maintain directory-as-configuration; can later add export capability |
| Workspace name conflicts | Workspace names must be single-level path segments, not containing `/`, and must not start with `.` |
| Metadata corruption | Metadata is cache; any missing data has a fallback and can be rebuilt at any time |
| Metadata concurrent writes | Owner partitions parallel workers by repo so mutations stay disjoint; append-only capture (jot) is concurrency-safe, aggregation (memo) stays serial in the owner. File locks give single-operation atomicity; unpartitioned races fall back to last-write-wins, with lost entries recovering on the next operation |
| Memo quality variance | Brief extraction rules validate format; content quality relies on skill constraints (budget, scaffold template). Not covered: a shallower session overwriting a richer card — the single-owner invariant guards concurrency, not capability asymmetry between sequential sessions |
| Knowledge decay without maintenance | `orbit repos` displays memoBehind; agents detect staleness on cold start; refresh is not forced |
| Pool repo count proliferation | No automatic cleanup yet; `orbit doctor` provides environment checks, extensible to detect unused repos |
| Prune mid-failure | Reclamation validates all-or-nothing and runs as an idempotent fixed pipeline: a step failure keeps the workspace whole, and the next invocation resumes — an interrupted run never strands a half-deleted workspace |
| Bypass habituation from a single override flag | One flag releases the data guards as one decision, so every applicable reason is reported together rather than one per run; it never releases the scope guards |

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

The advantage of manifest-first is versioned workspace compositions and more direct team sharing. The cost is a config file that carries mental overhead and drifts from the actual directories. The goal is first-class workspaces, not first-class configs.

### Why not symlinks

Symlinks are not used: Git and IDE recognition is unstable, branch isolation stays unsolved, and agent boundaries stop matching filesystem boundaries. `git worktree` gives a real directory, real Git status, real branch boundaries. That realness extends to toolchains — `go.work` and Cargo/pnpm/Gradle workspaces resolve by real relative paths and need no adaptation, which a virtual editor view or a set of granted paths cannot offer.

### Why not code indexing/RAG

Read-only retrieval cannot cover modify-and-push, so reading and writing would need two mechanisms with a gap between them. Complete source also beats fragmented embedding matches for tracing call chains and verifying signatures. The cost is token consumption, controlled by progressive loading (brief → info → source code).

### Why not a database for metadata

Files (git-config INI + markdown) have zero dependencies, are disposable, manually editable, and need no daemon. Metadata is cache, not the source of truth — database ACID guarantees are over-engineering for rebuildable data. Markdown lets agents read and write naturally without a serialization layer.

### Why knowledge is written by agents rather than auto-generated

Auto-summarization (README extraction, AST analysis) enumerates files and dependencies, but cannot judge **which roles a repo plays in a task or which entry points are worth starting from** — the two questions a memo answers. That judgment only comes from doing the work. Orbit provides the pipeline (scaffold template, capacity budget); the understanding comes from exploration. Cold start is empty, softened by the README-first-line fallback and by the memo-surfacing model, which keeps a memo-less repo flagged until a real card exists.

### Why knowledge is attached to repos rather than workspaces

Memos bind to pool repos, not to individual worktrees. Workspaces are short-lived and reclaimed when tasks finish; repos are long-lived, and knowledge should live with the long-lived entity. Understanding written in one session is then reusable in any later workspace instead of being lost on prune.

### Why conventions rather than sandboxing to isolate agents

Agents not touching `.repos/` is enforced by skill constraints, not filesystem permissions or containers: sandboxing adds runtime dependencies (container runtime, ACLs) and breaks the portability principle. Under the single-owner model — one owner plus the workers it briefs — conventions suffice, because agents get what they need through orbit commands and have no incentive to circumvent. Stronger isolation can be layered on for peer multi-agent setups.

The refinement, learned from an incident: conventions hold where failure is accidental. For irreversible cross-scope operations the incentive is not neutral — a soft boundary reads as an obstacle, and a refusal that explains itself becomes the route around it. Those few are enforced in-process, on state the agent cannot re-point. That is not sandboxing; it is choosing the check's basis.