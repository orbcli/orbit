# Metadata Design

> Detailed behavior definitions for metadata core principles, format selection, global index structure, per-repo memo format, and fallback rules. Progressive loading, staleness detection, memo lifecycle, and sync-memo cascading relationship are covered in [`spec-knowledge.md`](./spec-knowledge.md).

## Core Principles

**Metadata is cache, not a source of truth.** All metadata is disposable and rebuildable:
- Lost -> fallback (read README, `git remote -v`)
- Corrupted -> delete and rebuild (`orbit memo`)
- Stale -> does not affect correctness, only affects recommendation quality
- Concurrent conflicts -> last write wins, no locks needed; a missed update will be recovered next time
- No orbit operation should fail due to missing or incorrect metadata

## Format Selection

Two formats, chosen based on "who consumes":

| File | Format | Consumer | Rationale |
|------|--------|----------|-----------|
| `.repos/.orbit` | git-config INI | orbit program | `git config --file` zero-dependency parsing |
| `<workspace>/.orbit` | git-config INI | orbit program | Same as above |
| `.repos/.<repo>.md` | markdown | agent (LLM) | Free-form text, most natural for agent read/write |

INI files have no additional suffix (consistent with git conventions: `.gitconfig`, `.gitmodules` have no suffix).
All metadata files are hidden files (`.` prefix), not interfering with normal `ls` output.

## Repo Metadata: Two-Level Structure

```
.repos/
  .orbit              <- global index (git-config format)
  .backend.md         <- backend memo (markdown)
  .frontend.md        <- frontend memo (markdown)
  frontend/           <- repo itself
  backend/            <- repo itself
```

### Global Index `.repos/.orbit`

Read by `orbit repos`, git-config format:

```ini
[repos "backend"]
    url = git@github.com:org/backend.git
    brief = Go REST API, sqlc-generated DB layer
    head = abc1234
[repos "frontend"]
    url = git@github.com:org/frontend.git
    brief = React SPA, consumes backend API
    head = def5678
```

Field descriptions:
- `url`: origin remote URL (written from `git remote get-url origin` during `orbit memo`)
- `brief`: one-line description (extracted from `.md` first line during `orbit memo`; always derived, cannot be set independently)
- `head`: HEAD commit hash of repo at time of metadata write (full hash, used for staleness detection)

Read/write methods:
```bash
# Read
git config --file .repos/.orbit --get 'repos.backend.brief'
git config --file .repos/.orbit --get 'repos.backend.url'
git config --file .repos/.orbit --get 'repos.backend.head'
git config --file .repos/.orbit --get-regexp 'repos\..*\.brief'

# Write
git config --file .repos/.orbit 'repos.backend.brief' "Go REST API"
git config --file .repos/.orbit 'repos.backend.url' "git@github.com:org/backend.git"
git config --file .repos/.orbit 'repos.backend.head' "abc1234"
```

### Per-repo Memo `.repos/.backend.md`

Output by `orbit info backend`, pure markdown, agent reads and writes freely:

```markdown
# backend

Go REST API, sqlc-generated DB layer.

## When to add (roles)
- Owns the public `/orders` and `/auth` HTTP API — add for any endpoint or auth change.
- Source of the OpenAPI contract other services generate clients from.

## How to use
- `api/` — OpenAPI definitions; edit here first, handlers follow.
- `cmd/server/main.go` — service startup + route mounting; start here to trace a request.
```

### Brief Extraction Rules

**Skill constraint (brief extraction)**: `.md` files use the same brief extraction rule as README (first effective text paragraph after heading). When the agent writes via `orbit memo <repo>`, it must ensure the first paragraph after the heading satisfies:
- Plain text, one sentence describing the repo's purpose/role
- <= 120 characters

Example:
```markdown
# backend

Go REST API, sqlc-generated DB layer, Echo router.

## When to add (roles)
...
```

Extraction rules (shared between `.md` and README):
- Skip: `#` heading lines, blank lines, badge lines (`[![`/`![`), HTML comments, HTML tags (`<div>`/`<p>`/`<img>` etc.), list lines (`* `/`- `/`1. `), horizontal rules (`---`/`***`/`===`)
- Strip: leading whitespace, leading `> ` (blockquote tagline)
- Take: first effective text paragraph
- Truncate: <= 120 characters, at word boundary

After `orbit memo <repo>` writes, this rule is automatically used to extract brief and update the index. If extraction fails (no effective text), it errors and refuses to write.

### Memo Capacity and Lifecycle

See [`spec-knowledge.md` Memo Lifecycle](./spec-knowledge.md#memo-lifecycle).

### Push Target

Not managed in metadata. `orbit clone <url> --push <fork-url>` configures push remote at the git level; worktrees inherit automatically. Agent checks via `git remote -v`. See [spec-branching](./spec-branching.md).

## Workspace Metadata: `<workspace>/.orbit`

**Agent visibility boundary:** Agents do not directly read/write `.orbit` files; they access workspace metadata through commands like `orbit context`, `orbit goal`, `orbit status`. All commands that read `.orbit` auto-rebuild when the file is missing (backfilling `created`), ensuring the disposable metadata principle holds on the read path as well.

git-config format:

```ini
[workspace]
    goal = Fix API definition and update frontend calls
    created = 1751155200
```

`created` is stored as epoch seconds (`date +%s`); `orbit status` formats it as a human-readable date for display.

goal is optional:
- `orbit new "xxx"` writes it at creation time
- `orbit goal "xxx"` sets/updates it at any time
- `orbit goal --clear` deletes it (enters free exploration mode, no fixed goal)
- When no goal exists, `orbit goal` outputs empty (no error); agent treats it as free exploration

Long-lived workspace scenarios:
- Human manually creates directory + `orbit add` (not via `orbit new`) -> `orbit goal "xxx"` sets direction
- Work direction changes -> `orbit goal "new direction"` updates at any time
- No longer needs a fixed goal -> `orbit goal --clear`

All commands that write to workspace `.orbit` (`orbit add`, `orbit done`, `orbit goal`, `orbit jot`) auto-create the file if it doesn't exist (backfilling `created`).

`orbit jot` writes to the `[jot]` section using git-config multi-value (same key, multiple values):

```ini
[jot]
	backend = entry point: cmd/server/main.go — start here to trace startup
	backend = role: owns the public /auth API — add for any login/accounts task
	frontend = entry point: src/main.tsx — app bootstrap
```

Entries are card-scoped: a role or an MVP/VIP entry point the card needs (jot only feeds the card). Deep structure (framework choice, module internals) is out of card scope and is not jotted. Every entry is a real discovery — orbit writes no system placeholders into the queue.

`orbit jot <repo> --pop` outputs all values for the specified repo key, then removes them via `git config --unset-all`. Pop is consume-on-read — entries are deleted after retrieval.

After `orbit done` writes:

```ini
[workspace]
    goal = Fix API definition and update frontend calls
    created = 1751155200
    status = done
    done-at = 1751241600
    done-date = 2026-06-29
[pr]
    url = https://github.com/org/backend/pull/42
    url = https://github.com/org/frontend/pull/43
```

`done-date` is a human-readable redundant field of `done-at` (ISO date), used only for manual inspection; program logic always uses the `done-at` epoch.

## Fallback Rules

### Brief Display Fallback (`orbit repos`, `orbit context --startup` prime roster)

Applies wherever a pool repo's one-line brief is displayed. Both surfaces share one resolver (`orbit_pool_brief` in `orbit.sh`) that returns the brief plus its source tag (`index` / `memo` / `readme` / `none`); presentation is per-surface — `orbit repos` prints steering notes on **stderr** (human terminal), while the prime roster inlines them as **stdout sections** (`no memo (…):` / `index out of sync (…):`) because hook injection carries only stdout.

Source priority:
1. Global index `repos.<name>.brief` field (cached) — source `index`
2. Per-repo `.md` first effective text paragraph after heading (real-time extraction, repair path when index and .md are out of sync) — source `memo`
   -> `orbit repos` stderr: `orbit: <repo> index out of sync: refresh it with memo <repo> --refresh`
   -> prime roster: repo listed under `index out of sync (repair via orbit memo <repo> --refresh):`
3. README fallback: extract using the same rules from repo's README (**not written to meta**, display only for current invocation) — source `readme`
   -> `orbit repos` stderr: `orbit: <repo> has no memo, using README instead`
   -> prime roster: repo listed under `no memo (write the card via orbit memo <repo>; …):`
4. None available -> brief column displays `-` (empty string in JSON) — source `none`
   -> `orbit repos` stderr: `orbit: <repo> has no memo or README`
   -> prime roster: repo listed under the same `no memo (…):` section

Case 2 prompts index repair (.md exists meaning memo was previously executed, but index lost brief due to concurrent write or corruption).
Cases 3 and 4 do not write back to index cache; stderr guides the agent to generate a proper .md file via `orbit memo <repo>`.
Brief extraction rules are in the "Brief Extraction Rules" section above (shared between `.md` and README).

### `orbit repos` Output Format

```
NAME             URL                                     BRIEF
backend          git@github.com:org/backend.git          Go REST API, sqlc-generated DB layer
frontend         git@github.com:org/frontend.git         React SPA, consumes backend API
my-svc           git@github.com:org/my-svc.git           -
```

- Column-aligned, human-readable (default)
- stderr warnings do not mix into the table

### `orbit repos --json` Output Format

```json
[
  {
    "name": "backend",
    "url": "git@github.com:org/backend.git",
    "brief": "Go REST API, sqlc-generated DB layer",
    "head": "abc1234",
    "incomplete": false,
    "memoBehind": 0
  }
]
```

Field descriptions:
- `incomplete`: boolean, `true` indicates metadata is incomplete (`.md` file missing, or url/brief/head in index is empty)
- `memoBehind`: number, how many commits the memo is behind the pool repo's current HEAD (0 = up to date)
- These two fields are informational only. The agent is only responsible for writing back memo for repos it has actually added and worked on; it does not proactively fix the status of other repos in the pool

### `orbit info <repo>` (Memo)

Source priority:
1. Per-repo `.repos/.<repo>.md` file (outputs full text directly)
2. No `.md` file -> outputs the repo's README, truncated to `memo.maxLines` (default 16) lines (**not written to meta**, display only for current invocation)
   -> stderr: `orbit: <repo> has no memo, showing README`
   -> if truncated, stderr also: `orbit: <repo> README truncated to <N> lines, no memo yet`
3. No README -> outputs hint message ("no memo available")
   -> stderr: `orbit: <repo>: use 'orbit memo <repo>' to add`

Cases 2 and 3 stderr messages similarly guide the agent to generate a .md file (consistent with `orbit repos` warnings).

## Index Synchronization (`orbit memo`)

```bash
orbit memo                        # refresh index entries for all repos
orbit memo <repo>                 # write per-repo .md from stdin (first line is brief, also refreshes index)
orbit memo <repo> --refresh       # refresh only a single repo's index entry (does not write .md)
```

`orbit memo <repo>` (default) is the agent's high-frequency operation path: reads markdown content from stdin, writes to `.repos/.<repo>.md`, and simultaneously updates the index using the brief extraction rule.

`--refresh` is a low-frequency maintenance operation that only rebuilds the index entry from the existing `.md` file and git state; used for index corruption recovery.

### `orbit memo --scaffold` Output Format

`--scaffold` outputs a pure template to stdout: the pull-decision card structure — title + brief, `## When to add (roles)` (unbounded), `## How to use` (MVP/VIP entry points, unbounded) — with content as TODO placeholders. The agent uses this as reference, explores the repo (within `explore.paths`), then writes the formal card via `cat ... | orbit memo <repo>`.

Rules:
- Output to stdout only, does not write to `.md` file, does not update index
- Does not perform any code analysis (directory scanning, language detection, etc. are done by the agent)
- Still outputs even when memo already exists (does not affect existing `.md` file)

Fields written during refresh:
- `url` <- `git -C .repos/<repo> remote get-url origin`
- `brief` <- first effective text paragraph extracted from corresponding `.<repo>.md` using extraction rules (when present), otherwise cleared
- `head` <- `git -C .repos/<repo> rev-parse HEAD` (full hash)

Repos without a per-repo `.md` -> brief remains unchanged (or empty); next `orbit repos` display falls through to README fallback.

## Staleness Detection and Progressive Loading

See [`spec-knowledge.md`](./spec-knowledge.md), covering:
- [Progressive Loading Model](./spec-knowledge.md#progressive-loading-model) (Level 0->3 + per-level fallback)
- [Staleness Detection](./spec-knowledge.md#staleness-detection) (two-layer model: memoBehind + remoteAhead)
- [Sync and Memo Cascading Relationship](./spec-knowledge.md#sync-and-memo-cascading-relationship)
- [Agent-Driven Knowledge Generation](./spec-knowledge.md#agent-driven-knowledge-generation)
