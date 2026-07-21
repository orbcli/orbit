import { existsSync } from "node:fs"
import { dirname } from "node:path"
import { fileURLToPath } from "node:url"
import type { Plugin } from "@opencode-ai/plugin"

// Orbit OpenCode plugin — hooks mirroring the Claude/Qoder/Codex plugins:
//   experimental.chat.system.transform  →  SessionStart (startup)
//   event(session.compacted)            →  SessionStart:compact
//   permission.ask                      →  PreToolUse   (auto-approve safe orbit commands)
//
// TODO(opencode resume routing): OpenCode has no SessionStart source — resume
// (`--continue`/`--session`) is a UI navigation that fires no event and does
// not re-run transform, so this plugin cannot distinguish a resumed session
// from a fresh one. Until upstream lands a SessionStart hook
// (anomalyco/opencode#5409), the first transform of every session injects
// the full startup block (`orbit context --startup`); the skill is the
// documented fallback for resume (agent runs bare `orbit context` itself).
// Cache refreshes and post-compaction injections always use the light cruise
// block — never re-inject the full startup block mid-session (token discipline).
//
// Supports dual distribution:
//   Local:  install.sh --opencode  →  copies plugin.ts + SKILL.md to ~/.config/opencode/
//   npm:    opencode-orbit        →  config hook self-registers the bundled skill path
//
// Fail-safe by construction: if orbit is not on PATH, not in a workspace, or any
// dependency is missing, every hook is a silent no-op.

// Directory of this module — used to locate the bundled skill for npm installs.
const pluginDir = dirname(fileURLToPath(import.meta.url))

// Subcommands in tiers 1–2 (read-only + idempotent workspace-write) from
// skills/CONSTRAINTS.md. Excluded: done, prune, clone, config, new.
const SAFE_SUBCOMMANDS = new Set([
  "repos", "info", "status", "context", "goal",
  "jot", "memo", "add", "switch", "sync",
  "version", "doctor", "completion",
])

export default (async ({ client, $ }) => {
  // Per-session cache for injected system context. Invalidated when a bash
  // tool that runs an orbit command executes (workspace state may have changed).
  const ctxCache = new Map<string, string>()

  // Run an orbit context command and wrap its markdown in <orbit-context>
  // tags so the agent can tell hook-injected context from self-invoked output.
  // Returns "" on any failure (orbit missing / not in a workspace — the
  // command fails fast in both cases).
  const buildContext = async (startup: boolean): Promise<string> => {
    try {
      const res = startup
        ? await $`orbit context --startup`.nothrow().quiet()
        : await $`orbit context`.nothrow().quiet()
      if (res.exitCode !== 0) return ""
      const text = res.text().trim()
      if (!text) return ""
      return `<orbit-context>\n${text}\n</orbit-context>`
    } catch {
      return ""
    }
  }

  return {
    // ── Config ────────────────────────────────────────────────────────────
    // Registers the bundled skill path when installed as an npm package.
    // For local installs (install.sh) the skill is already in the standard
    // search path (~/.config/opencode/skills/), so this is a no-op.
    config: (cfg) => {
      const bundled = pluginDir + "/skills"
      if (existsSync(bundled + "/orbit/SKILL.md")) {
        if (!cfg.skills) cfg.skills = {}
        if (!cfg.skills.paths) cfg.skills.paths = []
        cfg.skills.paths.push(bundled)
      }
    },

    // ── SessionStart equivalent ──────────────────────────────────────────
    // Appends workspace context to the system prompt so the agent knows it is
    // inside an orbit workspace from its first reply. The first transform of
    // every session injects the full startup block (see TODO above — resume
    // routing is blocked on anomalyco/opencode#5409); refreshes after cache
    // invalidation always use the light cruise block — never re-inject the
    // full startup block mid-session (token discipline).
    "experimental.chat.system.transform": async (input, output) => {
      const sid = input.sessionID
      if (sid && ctxCache.has(sid)) {
        const cached = ctxCache.get(sid)!
        if (cached) output.system.push(cached)
        return
      }

      const ctx = await buildContext(true)

      if (sid) ctxCache.set(sid, ctx)
      if (ctx) output.system.push(ctx)
    },

    // ── PreToolUse/Bash equivalent ──────────────────────────────────────
    // Auto-approves single, un-chained orbit invocations whose subcommand is
    // in the two safe tiers. Destructive/externally-visible subcommands
    // (done, prune, clone, config, new) and sync --force still prompt.
    "permission.ask": async (input, output) => {
      try {
        if (input.type !== "bash") return

        // Extract the command from permission metadata (defensive — exact
        // field name may vary across OpenCode versions).
        const meta = input.metadata as Record<string, unknown> | undefined
        const cmd =
          (typeof meta?.command === "string" && meta.command) ||
          (typeof meta?.args === "object" && meta?.args
            ? String((meta.args as Record<string, unknown>)?.command ?? "")
            : "") ||
          (typeof input.pattern === "string" ? input.pattern : "")
        if (!cmd) return

        // Refuse anything with shell chaining/redirection/substitution.
        if (/[;&|`$()><\n]/.test(cmd)) return

        const parts = cmd.trim().split(/\s+/)
        const binary = (parts[0] ?? "").split("/").pop() ?? ""
        if (binary !== "orbit" && binary !== "orbit.sh") return

        const sub = parts[1] ?? ""
        if (!SAFE_SUBCOMMANDS.has(sub)) return

        // sync --force does git reset --hard on the pool repo — still prompt.
        if (sub === "sync" && cmd.includes("--force")) return

        output.status = "allow"
      } catch {
        // fail-safe: normal confirmation preserved
      }
    },

    "tool.execute.after": async (input) => {
      // Invalidate the system-context cache when an orbit bash command runs,
      // rebuilding it with the LIGHT cruise block (never the full startup
      // block — mid-session refreshes must not re-inject full memos).
      // Only update on a successful rebuild — if the rebuild fails (orbit
      // missing, CWD left the workspace) keep the previous cache so the
      // next transform still sees context rather than a permanent hole.
      if (input.tool === "bash" && input.sessionID) {
        const args = input.args as Record<string, unknown> | undefined
        const cmd = typeof args?.command === "string" ? args.command : ""
        if (cmd.includes("orbit") && ctxCache.has(input.sessionID)) {
          const fresh = await buildContext(false)
          if (fresh) ctxCache.set(input.sessionID, fresh)
        }
      }
    },

    event: async ({ event }) => {
      try {
        // ── SessionStart:compact equivalent ────────────────────────────
        // After compaction, inject the light cruise block two ways: as an
        // immediate prompt (the compacted history is gone), and into the
        // cache so subsequent transforms re-inject the light block rather
        // than the full startup block compaction was meant to avoid.
        if (event.type !== "session.compacted") return
        const sessionID = (event.properties as { sessionID?: string }).sessionID
        if (!sessionID) return

        const ctx = await buildContext(false)
        if (!ctx) return
        ctxCache.set(sessionID, ctx)
        await client.session.prompt({
          path: { id: sessionID },
          body: { parts: [{ type: "text", text: ctx }] },
        })
      } catch {
        // fail-safe: no injection on error
      }
    },
  }
}) satisfies Plugin
