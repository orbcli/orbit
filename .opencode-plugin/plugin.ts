import { existsSync } from "node:fs"
import { dirname } from "node:path"
import { fileURLToPath } from "node:url"
import type { Plugin } from "@opencode-ai/plugin"

// Orbit OpenCode plugin — three hooks mirroring the Claude/Qoder plugin:
//   experimental.chat.system.transform  →  SessionStart  (inject workspace context)
//   permission.ask                     →  PreToolUse    (auto-approve safe orbit commands)
//   event(session.idle)                →  Stop          (nudge to write memos before finishing)
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

// Tracks sessions that received a memo-debt nudge to avoid re-sending.
const nudgedSessions = new Set<string>()

export default (async ({ client, $ }) => {
  // Per-session cache for injected system context. Invalidated when a bash
  // tool that runs an orbit command executes (workspace state may have changed).
  const ctxCache = new Map<string, string>()

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
    // inside an orbit workspace from its first reply. Branches on cold start
    // (no repos → prime) vs resume (repos present → brief nudge).
    "experimental.chat.system.transform": async (input, output) => {
      const sid = input.sessionID
      if (sid && ctxCache.has(sid)) {
        const cached = ctxCache.get(sid)!
        if (cached) output.system.push(cached)
        return
      }

      try {
        const pathRes = await $`orbit context path`.nothrow().quiet()
        if (pathRes.exitCode !== 0) {
          if (sid) ctxCache.set(sid, "")
          return
        }
        const ws = pathRes.text().trim()
        if (!ws) {
          if (sid) ctxCache.set(sid, "")
          return
        }

        let ctx = `Detected an orbit workspace (${ws}) — treat this as an "orbit start" / "orbit启动" session.\nYou MUST invoke the orbit skill (via the Skill tool) as your first action, before replying — then apply Orbit conventions for the whole session.\n\n`

        const statusRes = await $`orbit status --json`.nothrow().quiet()
        if (statusRes.text().includes('"worktrees":[{')) {
          const goalRes = await $`orbit context goal`.nothrow().quiet()
          ctx += "Resuming — repos already in this workspace. Continue the prior task; do not re-survey the repos.\n"
          const goal = goalRes.text().trim()
          if (goal) ctx += `goal: ${goal}\n`
          ctx += "Detail on demand: orbit status (branches / dirty state) · orbit context (full repo memos) · orbit info <repo> (one repo) · orbit context --prime (residual jots from last session).\n"

          const gapsRes = await $`orbit context gaps`.nothrow().quiet()
          const gaps = gapsRes.text().trim()
          if (gaps) ctx += `Orbit memo debt: no real memo yet for ${gaps}. Explore, jot, then write a memo for these before done.\n`
        } else {
          const primeRes = await $`orbit context --prime`.nothrow().quiet()
          ctx += primeRes.text()
        }

        if (sid) ctxCache.set(sid, ctx)
        output.system.push(ctx)
      } catch {
        // orbit not installed or workspace detection failed — no-op
      }
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

    // ── Stop equivalent ──────────────────────────────────────────────────
    // On session.idle, checks for repos with no real memo (only [seed]
    // placeholders) and sends a one-time nudge per repo to write memos before
    // finishing. Throttled via git-config flags in the workspace .orbit file,
    // same as the Claude Stop hook.
    "tool.execute.after": async (input) => {
      // Invalidate the system-context cache when an orbit bash command runs,
      // so the next LLM call sees fresh workspace state.
      if (input.tool === "bash" && input.sessionID) {
        const args = input.args as Record<string, unknown> | undefined
        const cmd = typeof args?.command === "string" ? args.command : ""
        if (cmd.includes("orbit")) ctxCache.delete(input.sessionID)
      }
    },

    event: async ({ event }) => {
      try {
        if (event.type !== "session.idle") return
        const sessionID = (event.properties as { sessionID?: string }).sessionID
        if (!sessionID || nudgedSessions.has(sessionID)) return

        const pathRes = await $`orbit context path`.nothrow().quiet()
        if (pathRes.exitCode !== 0) return
        const ws = pathRes.text().trim()
        if (!ws) return

        const gapsRes = await $`orbit context gaps --json`.nothrow().quiet()
        const repos = JSON.parse(gapsRes.text().trim() || "[]") as string[]

        // Collect gap repos not yet nudged (throttle: once per repo).
        const pending: string[] = []
        for (const repo of repos) {
          if (!repo) continue
          const seenRes = await $`git config --file ${ws}/.orbit --get nudge.${repo}.seen`.nothrow().quiet()
          if (seenRes.text().trim()) continue
          pending.push(repo)
        }
        if (pending.length === 0) return

        // Mark so we don't nag every turn.
        for (const repo of pending) {
          await $`git config --file ${ws}/.orbit nudge.${repo}.seen 1`.nothrow().quiet()
        }
        nudgedSessions.add(sessionID)

        const list = pending.join(", ")
        const msg =
          `Before you finish: these repos still have no real memo (only a [seed] placeholder) — ${list}. ` +
          `For each, explore entry points/structure/build, capture findings with 'orbit jot <repo> "...", ` +
          `then write the memo via 'orbit memo <repo>' (drop the [seed] line — it is an instruction, not memo content). ` +
          `One-time reminder per repo.`

        await client.session.prompt({
          path: { id: sessionID },
          body: { parts: [{ type: "text", text: msg }] },
        })
      } catch {
        // fail-safe: no nudge on error
      }
    },
  }
}) satisfies Plugin
