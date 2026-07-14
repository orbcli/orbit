# Directory Structure

> Root directory model, source pool layout, workspace directory conventions. Derived from [PRINCIPLES.md](../PRINCIPLES.md) Principle 1 (workspace as first-class citizen) and Principle 2 (directory structure as single source of truth).

## Root Directory Model

```text
project-root/
  .repos/
    .orbit                    # global index (git-config format)
    README.md                 # pool marker: "infrastructure, do not access directly" (auto-written on init, idempotent)
    .backend.md               # per-repo memo (markdown)
    .frontend.md
    backend/                  # source pool repo
    frontend/
    kubernetes/
  task-01/
    .orbit                    # workspace metadata
    backend/                  # branch: ws/task-01/main
    frontend/                 # branch: ws/task-01/main
  task-02/
    .orbit
    kubernetes/               # branch: ws/task-02/release-1.29
```

## Key Structural Points

- **Top level directly exposes multiple workspaces**: when users open the project root, they see their task list
- **`.repos/` is the internal source pool**: does not occupy the main interaction surface; agents do not touch it directly
- **`.repos/README.md` is a passive guardrail**: written idempotently when the pool is initialized, it warns an agent that stumbles into `.repos/` (e.g. by listing it) that the directory is infrastructure and points back to orbit commands. It is defense-in-depth, not the isolation guarantee — the guarantee is keeping `.repos/` out of the agent's writable roots. It is a plain file, so every `.repos/*/` repo scan skips it.
- **Project root does not depend on extra config files**: no manifest or registry needed to define workspace combinations
- **`.repos/` determines root ownership**: serves as a convention-based structural anchor, similar to `.git/`
- **Metadata (`.orbit`, `.md`) is cache**: disposable and rebuildable, see [spec-metadata](./spec-metadata.md)

## Naming Constraints

- Workspace name must be a **single path segment** (no `/`)
- Workspace name must not start with `.` (to avoid conflicts with hidden files)
- Repo identity defaults to remote basename; can be explicitly overridden when necessary

## Project Root Discovery

Traverses upward from CWD looking for a `.repos/` directory, with `/` as the upper bound (same as how git searches for `.git/`). Can be explicitly overridden via the `ORBIT_ROOT` environment variable.
