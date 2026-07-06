# Contributing to Orbit

Thank you for your interest in contributing to Orbit! This guide covers the development workflow, coding standards, and contribution process.

## Development Environment

### Prerequisites

| Dependency | Minimum Version | Purpose |
|:-----------|:----------------|:--------|
| Bash | 3.2+ | Runtime (macOS default compatible) |
| [bats-core](https://github.com/bats-core/bats-core) | 1.9+ | Test framework |
| [ShellCheck](https://www.shellcheck.net/) | 0.9+ | Static analysis / linting |
| Git | 2.20+ | Worktree support required |

### Setup

```bash
git clone https://github.com/orbcli/orbit.git
cd orbit

# Run tests to verify your setup
bats tests/

# Lint
shellcheck orbit.sh install.sh
```

## Code Style

Orbit follows standard Shell scripting best practices:

- **Indentation**: 2 spaces (no tabs)
- **Function naming**: `snake_case` (e.g., `find_project_root`, `ensure_path_export`)
- **Variables**: `UPPER_CASE` for constants/globals, `lower_case` for locals
- **Local variables**: Always declare with `local` inside functions
- **Quoting**: Double-quote all variable expansions (`"$var"`, not `$var`)
- **Error output**: Use `>&2` for error/diagnostic messages
- **Exit codes**: Use meaningful exit codes; `exit 1` for user errors
- **Shebang**: `#!/usr/bin/env bash`
- **Strict mode**: `set -euo pipefail` at the top of scripts
- **Printf over echo**: Prefer `printf '%s\n'` over `echo` for portability

## Testing

Tests use [bats-core](https://github.com/bats-core/bats-core) and live in `tests/`.

```bash
# Run all tests
bats tests/

# Run a specific test file
bats tests/05_workspace_lifecycle.bats

# Via Makefile
make test
```

### Writing Tests

- Test files are numbered and prefixed to enforce execution order (e.g., `01_initialization.bats`)
- Each test should be self-contained and clean up after itself
- Use the helpers in `tests/test_helper/` for common setup/teardown
- Test file names should describe the feature under test

## Pull Request Process

1. **Fork & branch** — Create a feature branch from `main`
2. **Make changes** — Keep commits focused and atomic
3. **Lint & test** — Ensure `shellcheck` and `bats` pass cleanly
4. **Submit PR** — Open a pull request with a clear description

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]
```

Types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`

Examples:

```
feat(clone): add --push fork-url support
fix(status): correct CWD detection in nested worktrees
docs: update USAGE.md for new switch semantics
test: add workspace lifecycle prune tests
```

### PR Checklist

- [ ] `shellcheck orbit.sh install.sh` passes with no warnings
- [ ] `bats tests/` passes
- [ ] New features include corresponding tests
- [ ] Documentation updated if user-facing behavior changes

## Issues

- **Bug reports**: Include your OS, Bash version (`bash --version`), and steps to reproduce
- **Feature requests**: Describe the use case and how it relates to Orbit's [design principles](PRINCIPLES.md)
- **Questions**: Check [USAGE.md](USAGE.md) and existing issues first

## Design Guidance

Before proposing significant changes, review:

- [PRINCIPLES.md](PRINCIPLES.md) — Core design principles and non-goals
- [ROADMAP.md](ROADMAP.md) — Current priorities and planned work
- [docs/spec-commands.md](docs/spec-commands.md) — Command design conventions

Orbit values simplicity, Git-nativeness, and minimal dependencies. Proposals that align with these principles are most likely to be accepted.

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.
