# Documentation

This directory contains design specifications and reference materials for Orbit.

## Naming Conventions

| Prefix | Category | Description |
|:-------|:---------|:------------|
| `spec-` | Design specification | Detailed internal design decisions and structural contracts |
| _(none)_ | Reference material | Comparisons, guides, and other supplementary information |

## Document Index

### Design Specifications

| Document | Description |
|:---------|:------------|
| [spec-branching.md](spec-branching.md) | Branch naming strategy and push conventions |
| [spec-commands.md](spec-commands.md) | Command interface design and argument conventions |
| [spec-directory.md](spec-directory.md) | Directory structure layout and anchor rules |
| [spec-knowledge.md](spec-knowledge.md) | Knowledge system: progressive loading, staleness detection, and memo lifecycle |
| [spec-lifecycle.md](spec-lifecycle.md) | Workspace lifecycle (new → add → done → prune) |
| [spec-metadata.md](spec-metadata.md) | Metadata formats (git-config INI + Markdown) |
| [spec-warnings.md](spec-warnings.md) | Registry of stderr guidance warnings (the steering channel) and their format contract |

### Reference Materials

| Document | Description |
|:---------|:------------|
| [comparison.md](comparison.md) | Comparison with workspace management and agent context tools |
| [recipes.md](recipes.md) | Common scenario cookbook |
