# Security Policy

## Supported Versions

Orbit is currently pre-1.0. Security fixes are applied to the latest released
version only. Please upgrade to the most recent release before reporting an
issue.

| Version | Supported |
|:--------|:----------|
| Latest release (`0.1.x`) | ✅ |
| Older releases | ❌ |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, report them privately via GitHub's built-in
[Private vulnerability reporting](https://github.com/orbcli/orbit/security/advisories/new).
This keeps the details confidential until a fix is available.

When reporting, please include as much of the following as possible:

- A description of the vulnerability and its impact
- Steps to reproduce (a minimal proof of concept is ideal)
- Affected version(s) and your environment (OS, Bash version — `bash --version`, Git version)
- Any suggested remediation, if you have one

## Response Process

- **Acknowledgement** — We aim to acknowledge new reports within 5 business days.
- **Assessment** — We will investigate, confirm the issue, and determine affected versions.
- **Fix & disclosure** — We will develop a fix, release it, and publish a security
  advisory crediting the reporter (unless you prefer to remain anonymous).

We ask that you give us a reasonable window to address the issue before any
public disclosure.

## Scope

Orbit is a local, Git-native CLI tool: it clones repositories, manages Git
worktrees, and runs commands on your machine. There is no server, network
service, or hosted component. Reports are most relevant when they concern:

- **Command / argument injection** — untrusted input (repo names, URLs, goals,
  refs, memo/jot content) being interpreted as shell commands.
- **Path traversal** — operations escaping the intended `.repos/` pool or
  workspace directory.
- **Unsafe file handling** — following symlinks or overwriting files outside
  the workspace during clone, add, sync, or prune.
- **Privilege or trust boundary issues** in `install.sh` or the bundled agent
  hooks (auto-approve `PreToolUse`, `SessionStart`).

### Out of scope

- Vulnerabilities in third-party dependencies (Git, Bash, bats, ShellCheck) —
  report those upstream.
- Issues that require the attacker to already have local shell access with the
  same privileges as the user running Orbit.
- Risks inherent to running AI coding agents against arbitrary source code that
  are not introduced by Orbit itself.

## Security Best Practices for Users

- Only add repositories from sources you trust to your `.repos/` pool — Orbit
  clones and reads real source that agents may act on.
- Review the auto-approve command allowlist before enabling it. See
  [`skills/CONSTRAINTS.md`](skills/CONSTRAINTS.md#permission-and-auto-execution-policy)
  for the exact set of subcommands and the rationale.
- When bootstrapping via `curl … | bash`, inspect the script first if you have
  any concerns about the source.

Thank you for helping keep Orbit and its users safe.
