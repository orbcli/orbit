# Recipes

Step-by-step guides for common scenarios. Each recipe assumes Orbit is already installed (see README).

Recipes are grouped by the two things Orbit is for: **multi-repo development** (working across repos as one workspace) and **agent knowledge & context** (turning source into knowledge an agent can read, verify, and carry forward).

**Human vs agent.** The human provides the goal and does one-time setup (`orbit clone`). Inside the workspace, the agent handles the rest: discovering repos, assembling the workspace, developing, and committing. Recipes show the full flow; steps inside the workspace are the agent's job.

# Multi-repo development

## Multi-Repo Feature Development

> Scenario: A feature spans both backend and frontend repositories, requiring simultaneous changes to the API definition and the frontend calls.

```bash
# (human) First time: add repos to the pool (only needed once)
orbit clone git@github.com:org/backend.git
orbit clone git@github.com:org/frontend.git

# (human) Create a workspace with the goal
orbit new "Avatar upload: add backend endpoint, add frontend upload component"
cd task-01/
# --- from here, the agent takes over ---

# (agent) Discovers which repos it needs, adds them
orbit add backend
orbit add frontend

# (agent) Develops in each repo
cd backend/
git checkout -b feature/avatar-upload
# Code, test, commit...
git push origin feature/avatar-upload

cd ../frontend/
git checkout -b feature/avatar-upload
# Code, test, commit...
git push origin feature/avatar-upload

# (agent) Marks as done
cd ..
orbit done --pr https://github.com/org/backend/pull/42
orbit done --pr https://github.com/org/frontend/pull/43

# (human) Reclaim after PRs are merged
orbit prune task-01
```

## Cross-Repo Multi-Module Development (`go.work` and friends)

> Scenario: You're changing a Go service and a library it imports — two separate repos. You want `go build` and `gopls` to treat them as one module graph (cross-module jump-to-definition, refactors, no `replace` hacks), instead of cutting a release just to test a one-line library change.

Because an Orbit workspace is a **real directory tree** of real worktrees, a `go.work` at the workspace root resolves across the repos by relative path — the Go toolchain treats them as one. Orbit does nothing Go-specific; this falls out of using the real filesystem.

```bash
orbit new "Add retry to lib, wire it into service" --name retry-work
cd retry-work/
orbit add service
orbit add mylib

# Drop a go.work at the WORKSPACE ROOT (parent of both worktrees).
# It sits outside every repo, so no repo's git ever sees it — zero pollution, no .gitignore needed.
go work init ./service ./mylib
# (or write it by hand:)
#   cat > go.work <<'EOF'
#   go 1.23
#   use (
#     ./service
#     ./mylib
#   )
#   EOF

# Now the toolchain treats both modules as one:
cd service/
go build ./...            # resolves ./mylib locally, no replace directive, no release
# gopls: cross-module jump-to-definition, autocomplete, and refactors all work

# Edit mylib and immediately see it resolve in service:
cd ../mylib/
# change an exported function...
cd ../service/
go test ./...            # picks up the local mylib change instantly
```

Key points:
- The `go.work` (and the `go.work.sum` the toolchain generates next to it) lives at the **workspace root**, a parent of both worktrees — so it's naturally outside every repo's git and never gets committed by accident (no `.gitignore` entry required)
- This works because the workspace is a genuine on-disk tree with real relative paths — an editor's multi-root view or a "granted directory" list can't offer that
- **Orbit does not manage `go.work`** — you (or the agent) create it; Orbit just provides the real layout that makes it work with zero adaptation
- The same pattern applies to any toolchain that resolves multi-module builds by real on-disk layout: **Cargo workspaces** (`[workspace] members = [...]`), **pnpm/yarn workspaces**, **Gradle/Maven multi-project**

Same pattern, other ecosystems — the workspace file sits at the workspace root (parent of all worktrees), never committed into any repo:

```toml
# Cargo.toml at workspace root (Rust)
[workspace]
members = ["service", "mylib"]
resolver = "2"
# → cargo build in service/ resolves mylib locally, no [patch] needed
```

```yaml
# pnpm-workspace.yaml at workspace root (JS/TS)
packages:
  - 'service'
  - 'mylib'
# → pnpm install links mylib into service/node_modules; tsc/eslint resolve across packages
```

```groovy
// settings.gradle at workspace root (Java/Kotlin)
rootProject.name = 'myproject'
include 'service', 'mylib'
// → gradle build in service/ resolves mylib as a project dependency, no publish needed
```

## Cross-Repo Bugfix

> Scenario: A production bug requires fixing both backend and shared-lib simultaneously — urgent hotfix.

```bash
# (human) Create workspace with the bug description
orbit new "Fix order amount calculation precision loss" --name hotfix-amount
cd hotfix-amount/
# --- agent takes over ---

# (agent) Adds the relevant repos, locates root cause
orbit add backend
orbit add shared-lib

cd shared-lib/
grep -rn "decimal\|float" lib/money/
# Found the issue, fix it, commit

# (agent) Fixes the caller
cd ../backend/
# Update dependency version, fix the call...

# (agent) Marks done with PRs
cd ..
orbit done --pr https://github.com/org/shared-lib/pull/15
orbit done --pr https://github.com/org/backend/pull/88
```

## Fork Contribution Workflow

> Scenario: Submit a PR to an open-source project — fetch from upstream, push to your fork.

```bash
# (human) Specify the fork's push URL at clone time (one-time)
orbit clone git@github.com:grpc/grpc-go.git --push git@github.com:me/grpc-go.git

# (human) Create workspace
orbit new "Fix grpc-go connection pool leak"
cd task-01/
# --- agent takes over ---

# (agent) Adds the repo, fixes the bug
orbit add grpc-go

cd grpc-go/
git checkout -b fix/conn-pool-leak
# Fix, test, commit

# (agent) Pushes to fork
git push origin fix/conn-pool-leak

# (human) Submit PR on GitHub from me/grpc-go to grpc/grpc-go

cd ..
# (agent or human)
orbit done --pr https://github.com/grpc/grpc-go/pull/7890
```

## Parallel Agent Development

> Scenario: Multiple agents work on different tasks simultaneously, each isolated in their own workspace.

```bash
# (human) Create multiple workspaces
orbit new "Refactor user authentication module" --name auth-refactor
orbit new "Add order export feature" --name order-export
orbit new "Upgrade Go to 1.23" --name go-upgrade

# (human) Launch agents in separate terminals
# Terminal 1:
cd auth-refactor/ && claude "orbit start"

# Terminal 2:
cd order-export/ && claude "orbit start"

# Terminal 3:
cd go-upgrade/ && claude "orbit start"

# (agents) Each agent independently:
# - Discovers and adds the repos it needs (orbit add)
# - Develops, commits, pushes in its own workspace
# - Marks done with PRs
# The same backend repo can exist in three workspaces simultaneously on different branches
```

## Scoped Mode Branch Isolation

> Scenario: Multiple workspaces touch the same repo. Use scoped mode to prevent branch name collisions.

```bash
orbit new "Refactor auth middleware" --name auth
orbit new "Fix rate limiter bug" --name ratelimit

# Both workspaces need the backend repo
cd auth/ && orbit add backend && cd ..
cd ratelimit/ && orbit add backend && cd ..

# Workspace 1: use scoped mode to create an isolated branch
cd auth/backend/
orbit switch -c refactor-auth
# → Creates ws/auth/refactor-auth, upstream → origin/refactor-auth
# Work, commit...
git push
# → Pushes to origin/refactor-auth (no ws/ prefix on remote)

# Workspace 2: independently create its own branch
cd ../../ratelimit/backend/
orbit switch -c fix-rate-limiter
# → Creates ws/ratelimit/fix-rate-limiter, upstream → origin/fix-rate-limiter
git push
# → Pushes to origin/fix-rate-limiter

# Switch to an existing remote branch (e.g., a colleague's WIP)
orbit switch review-branch
# → Fetches origin/review-branch, creates ws/ratelimit/review-branch tracking it
```

Key points:
- Scoped mode adds a `ws/<workspace>/` prefix to local branches, preventing collisions when multiple workspaces use the same repo
- Remote branch names stay clean — no prefix is pushed
- `git push` works without specifying a target (upstream is pre-configured)
- Use scoped mode when branches might overlap; use raw mode (default `git checkout -b`) when they won't

# Agent knowledge & context

## Dependency Source Verification (Single-Repo Project)

> Scenario: Your project has only one repository, but you need the agent to verify against dependency source code to avoid hallucinations.

```bash
# (human) Add both your project and the dependency library to repos
orbit clone git@github.com:my/project.git
orbit clone git@github.com:kubernetes/client-go.git

# (human) Create workspace
orbit new "Upgrade informer to client-go v0.28 new API"
cd task-01/
# --- agent takes over ---

# (agent) Adds project (to modify) and dependency (to verify against)
orbit add project
orbit add client-go --ref v0.28.0    # pin to the version you depend on

# (agent) Verifies directly in the client-go directory
cd client-go/
grep -rn "DialContext\|Deprecated" .
# Confirm API signatures, deprecation status, replacement options

# (agent) Modifies code based on verification results
cd ../project/
# Modify code, ensuring compatibility
```

Key points:
- The dependency doesn't need modification — it serves only as reference material for the agent
- Use `--ref` to pin a version tag, ensuring the agent verifies against the version you actually depend on
- The agent can grep, read source, and inspect test cases — far more accurate than docs or training data

## Let the Agent Autonomously Explore Dependencies

> Scenario: You give the agent a goal and let it decide which library source code it needs to reference.

```bash
# (human) Pre-clone commonly used dependencies to repos
orbit clone git@github.com:gin-gonic/gin.git
orbit clone git@github.com:go-redis/redis.git
orbit clone git@github.com:jackc/pgx.git

# (human) Seed memos so the agent can assess relevance quickly
cat <<'EOF' | orbit memo gin
HTTP framework: routing, middleware, binding/validation.
EOF

cat <<'EOF' | orbit memo redis
Go Redis client, supports cluster, pipeline, pub/sub.
EOF

cat <<'EOF' | orbit memo pgx
PostgreSQL driver, native protocol implementation, supports COPY, prepared statements.
EOF

# (human) Create workspace — provide only the goal
orbit new "Optimize order query endpoint caching strategy" --exec 'claude "orbit start"'
# --- agent takes over from here ---

# (agent) Autonomously:
# 1. orbit repos to view available repos and their briefs
# 2. orbit info redis to view detailed memo, assess whether it's needed
# 3. orbit add redis to add it to the workspace
# 4. Verify pipeline/cache related APIs in redis source code
# 5. If it discovers it also needs pgx's connection pool implementation, autonomously orbit add pgx
```

Key points:
- You don't need to know in advance which libraries the agent will use
- `orbit repos` briefs let the agent do first-round filtering with minimal tokens
- The agent can `orbit add` at any time, pulling in more knowledge on demand
- Memos persist across sessions — what one agent writes today, another agent reads tomorrow

## Community Repo Version Debugging

> Scenario: Compare behavior between two Kubernetes releases to debug a performance regression introduced in 1.30.

```bash
# Clone the community repo once
orbit clone git@github.com:kubernetes/kubernetes.git

# Workspace A: pin to the known-good release
orbit new "Investigate scheduler perf regression" --name perf-debug
cd perf-debug/
orbit add kubernetes --ref release-1.29

cd kubernetes/
grep -rn "SchedulingQueue\|activeQ" pkg/scheduler/
# Baseline: understand the 1.29 scheduling queue behavior
cd ../..

# Workspace B: pin to the suspected-bad release
orbit new "Compare scheduler changes in 1.30" --name perf-compare
cd perf-compare/
orbit add kubernetes --ref release-1.30

cd kubernetes/
grep -rn "SchedulingQueue\|activeQ" pkg/scheduler/
# Diff against 1.29: identify what changed

cd ../..
# Both workspaces coexist — same repo, different versions, fully isolated
```

Key points:
- The same pool repo serves both workspaces — no duplicate clones
- `--ref` pins each workspace to a specific release branch or tag
- You can grep, read, and diff across versions in parallel without branch-switching conflicts

## Agent Cold-Start Memo Writing

> Scenario: A repo was cloned but has no memo yet. Walk through the scaffold → explore → write cycle.

```bash
orbit clone git@github.com:org/payments.git

orbit new "Add refund webhook handler"
cd task-01/
orbit add payments

# Check existing memo state
orbit info payments
# → "(no memo available)" — needs a memo

# Generate the scaffold template
orbit memo payments --scaffold
# Outputs section structure with TODO placeholders (not written to file)

# Explore the repo to fill in real content
cd payments/
ls cmd/ internal/ pkg/
head -20 cmd/server/main.go
grep -rn "func.*Handler" internal/handler/
cat go.mod | head -10

# Write the memo based on what you found
cat <<'EOF' | orbit memo payments
# payments

Stripe-integrated payment service, handles charges, refunds, and webhooks.

## When to add (roles)
- Owns all Stripe integration — add for any charge, refund, or webhook change.
- Exposes `pkg/client/` as the SDK other services call to initiate payments.

## How to use
- `internal/handler/webhook.go` — Stripe webhook receiver; start here for webhook work.
- `internal/service/refund.go` — refund logic; the entry point for refund changes.
- `internal/gateway/stripe.go` — the single Stripe wrapper all API calls route through.
EOF

# Verify: memo is now visible
orbit info payments
# → Shows the full memo content
```

Key points:
- `orbit memo --scaffold` gives you the card structure (roles + how to use) without writing anything — use it as a reference
- Explore the repo first (within `explore.paths`), then write the card — don't guess or copy README content verbatim
- A good card answers two questions: when/why to add the repo (its roles) and how to use it (the MVP/VIP entry points) — well within orbit's card budget (`memo.maxLines`, which orbit reports at aggregation)
- Future sessions (yours or a teammate's) will see this card via `orbit info` or `orbit context`

## Accumulate Toolchain Feedback in a Knowledge Repo

> Scenario: As you work, you keep learning things about your **development toolchain** — the agent skills, linters, compilers, and CI/CD pipelines that make the work faster but aren't part of any repo you're editing. A pitfall in your CI config, a linter rule that keeps biting, a better way to drive a skill: this feedback is cross-cutting, so it has no natural home in the project repo at hand. It also grows over time and needs periodic review. Per-repo `memo` is the wrong home (memo is a bounded, small pull-decision card for a single repo, and `jot` only feeds that card). Keep a dedicated knowledge repo for the toolchain and write to it with normal git.

```bash
# A dedicated toolchain-knowledge repo — skill notes, CI pitfalls, linter/compiler
# gotchas, workflow decisions — lives in the pool
orbit clone git@github.com:org/toolchain-blueprint.git

# While working in some project repo you hit a toolchain pitfall (e.g. a CI quirk,
# a skill workflow gap). Add the knowledge repo alongside it and record via branch + PR:
orbit add toolchain-blueprint
cd toolchain-blueprint/
orbit switch -c pitfall/ci-cache-key-collision
# append the pitfall / feedback to ci/… or skills/… or docs/…
git commit -am "pitfall: CI cache key collides across matrix jobs"
git push          # open a PR into the knowledge repo — reviewable, traceable

# Later, on your own schedule, run an agent whose only job is to CONSOLIDATE
orbit new "Consolidate accumulated toolchain notes into one coherent set" --name blueprint-sweep
cd blueprint-sweep/
orbit add toolchain-blueprint
# the agent reads the whole ci/ + skills/ + docs/ set at once and rewrites it into a
# deduplicated, balanced summary
```

**For an individual** — you *are* the toolchain owner. There's no platform team to hand this to, so your agent routes toolchain pitfalls into the log repo as it works, and you run the consolidation sweep yourself whenever the pile grows (weekly, before a release, whenever).

**For a team** — a dedicated toolchain owner runs the same sweep on a daily cadence; everyone else's agents just keep routing feedback into the shared log repo via PR. The individual capture loop is byte-for-byte identical — only *who* aggregates changes. No server, no platform: the git repo is the coordination surface.

Key points:
- **The subject is the toolchain, not the project** — skills, linters, compilers, CI/CD are what speed up development but live outside the repo you're editing, so their feedback has no per-repo home. A dedicated Git repo gives that cross-cutting knowledge a place to accumulate
- This does **not** belong in `memo`: memo is a bounded, small per-repo pull-decision card for "when to add this repo + how to use it" — it can't hold large accumulating narrative, and `jot` (append-only capture that folds into memo) is the wrong tool at this scale
- Writing via **branch + PR** makes each note reviewable and traceable (git history + code review), unlike an agent's ephemeral memory
- **Consolidate in periodic batches, not incrementally**: an agent that reviews the whole accumulated set in one pass produces a balanced synthesis instead of drifting toward whatever was reported most recently
- This is the "any Git repo is a workspace member" pattern applied to knowledge — the agent reads *and writes* the knowledge repo exactly like code

## Knowledge / Notes Repo as a Workspace Member

> Scenario: Your notes or docs live in a Git repo — an Obsidian vault, a spec/PRD repo. Treat it like any other repo: the agent reads and writes it in place.

```bash
# One-time: clone the knowledge repo into the pool
orbit clone git@github.com:me/my-vault.git

orbit new "Draft the Q3 architecture proposal from the design discussion"
cd task-01/
orbit add my-vault
orbit add backend        # pull in the code the proposal needs to reference

# The agent reads code in backend/ and writes notes in my-vault/ —
# same workspace, same commit/push flow, no distinction between them
cd my-vault/
# agent drafts/edits markdown, commits, pushes — exactly like a code repo
```

Key points:
- Orbit's pool and workspace don't distinguish code repos from knowledge repos — any Git repo can be added, read, edited, committed, and pushed
- Mixing a docs/notes repo with code repos in one workspace lets the agent cross-reference source while it writes — e.g. verify an API in `backend/` while drafting a design note in the vault
- The same progressive-loading and memo mechanics apply: a notes repo gets a brief and a memo just like code

## Team Knowledge Accumulation

> Scenario: Set up shared team repos + memos so new members' agents can get up to speed quickly.

```bash
# Team lead or first developer: set up repos and write memos
orbit clone git@github.com:org/backend.git
orbit clone git@github.com:org/frontend.git
orbit clone git@github.com:org/infra.git

cat <<'EOF' | orbit memo backend
# backend

Go REST API serving an online marketplace.

## When to add (roles)
- Owns the marketplace HTTP API — add for any endpoint, handler, or business-logic change.
- Owns the data layer (sqlc-generated) and goose migrations — add for schema work.

## How to use
- `cmd/server/main.go` — server startup + route mounting; start here to trace a request.
- `internal/handler/` — HTTP handlers; the entry point for adding or changing endpoints.
- `internal/repo/` — sqlc data access; pair with `migrations/` (goose) for schema changes.
EOF

# After new members join, they clone the same set of repos (or receive an export)
# Their agents can run orbit repos to see all repositories and briefs
# orbit info backend shows the repo's roles and entry points
# New members skip cold-start exploration and know when to add each repo and where to start
```
