# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-07-06

### Added

- Core commands: `clone`, `repos`, `info`, `memo`, `sync`
- Workspace lifecycle: `new`, `add`, `switch`, `done`, `prune`
- Workspace reactivation: setting a goal on a done workspace clears its completion record and PR history; `orbit add` on a done workspace warns it is prune-eligible
- Status and context: `status`, `goal`, `context`
- Configuration: `config`, `doctor`, `completion`
- Knowledge system: `memo` (read/write), `jot` (quick notes)
- Claude Code and Qoder skill definitions
- `install.sh` with `--claude` / `--qoder` (alias `--qodercli`) / `--zsh` / `--bash` support
- bats test suite (177 tests across 20 files)
