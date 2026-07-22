import { existsSync } from "node:fs"
import { dirname } from "node:path"
import { fileURLToPath } from "node:url"
import type { Plugin } from "@opencode-ai/plugin"

// Orbit OpenCode plugin — hooks mirroring the Claude/Qoder/Codex plugins:
//   experimental.chat.system.transform  →  SessionStart (startup)
//   experimental.session.compacting     →  summary-pass guard (no injection into
//                                          the tool-forbidden summary request;
//                                          durables go via the context channel)
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
//
// Injection tiers follow the Claude/Qoder lifecycle (docs/spec-hooks.md):
// the startup block rides the whole pre-compact session — cache refreshes
// after orbit CLI commands rebuild it in FULL (parity with Claude/Qoder,
// where the injected block lives in conversation history until compaction) —
// and only a compaction switches the session to the light cruise block
// (compaction means context pressure; never re-inject full memos after one).
//
// Supports dual distribution:
//   Local:  install.sh --opencode  →  copies plugin.ts + SKILL.md to ~/.config/opencode/
//   npm:    opencode-orbit        →  config hook self-registers the bundled skill path
//
// Fail-safe by construction: if orbit is not on PATH, not in a workspace, or any
// dependency is missing, every hook is a silent no-op.

// Directory of this module — used to locate the bundled skill for npm installs.
const pluginDir = dirname(fileURLToPath(import.meta.url))

// ── Injected-block furniture (hook layer, never the orbit runtime) ──────
// `orbit context` output is shared by humans and agents; the hooks add the
// agent-only furniture around it. The XML comment bootstraps skill loading:
// the skill description's primary trigger is "an <orbit-context> hook block
// is present", but nothing in the payload itself pointed at the skill, and
// agents were observed reading the block without ever loading the skill.
// The wording is tier-specific:
//   startup — a fresh session never has the skill loaded, so the call is
//     unconditional ("before your first reply");
//   cruise  — resume/compact blocks fire mid-session, and a compaction can
//     wipe the skill CONTENT while a summary still "remembers" loading it —
//     so the condition is content-in-context, not loaded-this-session.
// XML comment syntax keeps the hint out of the data.
const STARTUP_HINT =
  "<!-- orbit workspace: invoke the orbit skill before your first reply -->"
const CRUISE_HINT =
  "<!-- orbit workspace: invoke the orbit skill (skip only if its content is already in your context) -->"

const wrapContext = (text: string, startup: boolean): string =>
  `<orbit-context>\n${startup ? STARTUP_HINT : CRUISE_HINT}\n${text}\n</orbit-context>`

// True only when a bash command actually invokes the orbit CLI: the first
// token of any command in a chain resolves to binary `orbit`/`orbit.sh`,
// with interpreter/builtin prefixes unwrapped (`bash orbit.sh status`,
// `sh ./orbit.sh`, `command orbit status`). Substring matching is wrong
// here — workspace paths conventionally contain "orbit"
// (~/coding/orbit-demo), so plain `ls`/`git` on the workspace would
// false-positive and needlessly rebuild the context cache. Conservative
// misses (env prefixes, `bash -c`, command substitution) are acceptable:
// they only skip a refresh, never corrupt state.
const invokesOrbitCli = (cmd: string): boolean =>
  cmd.split(/&&|\|\||[;|&\n]/).some((segment) => {
    const tokens = segment.trim().split(/\s+/)
    const isOrbit = (t: string | undefined): boolean => {
      const base = (t ?? "").split("/").pop() ?? ""
      return base === "orbit" || base === "orbit.sh"
    }
    if (isOrbit(tokens[0])) return true
    const first = (tokens[0] ?? "").split("/").pop() ?? ""
    if (first === "bash" || first === "sh" || first === "zsh" || first === "command") {
      return isOrbit(tokens[1])
    }
    return false
  })

// Subcommands in tiers 1–2 (read-only + idempotent workspace-write) from
// skills/CONSTRAINTS.md. Excluded: done, prune, clone, config, new.
const SAFE_SUBCOMMANDS = new Set([
  "repos", "info", "status", "context", "goal",
  "jot", "memo", "add", "switch", "sync",
  "version", "doctor", "completion",
])

const orbitPlugin = (async ({ client, $ }) => {
  // Per-session cache for injected system context. Refreshed when a bash
  // tool that invokes the orbit CLI executes (workspace state may have
  // changed). compactedSessions marks sessions that have been compacted —
  // their refreshes stay on the cruise block, since full memos must not
  // return after a compaction. compactingNow marks sessions with a
  // compaction summary pass in flight — see the compacting hook below.
  const ctxCache = new Map<string, string>()
  const compactedSessions = new Set<string>()
  const compactingNow = new Set<string>()

  // Run an orbit context command and return its raw markdown. Returns "" on
  // any failure (orbit missing / not in a workspace — the command fails
  // fast in both cases).
  const rawContext = async (startup: boolean): Promise<string> => {
    try {
      const res = startup
        ? await $`orbit context --startup`.nothrow().quiet()
        : await $`orbit context`.nothrow().quiet()
      if (res.exitCode !== 0) return ""
      return res.text().trim()
    } catch {
      return ""
    }
  }

  // Raw context wrapped for injection (tags + tier-specific skill hint).
  const buildContext = async (startup: boolean): Promise<string> => {
    const text = await rawContext(startup)
    return text ? wrapContext(text, startup) : ""
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
    // routing is blocked on anomalyco/opencode#5409); the cached block is
    // re-pushed on later transforms so it rides the whole session (the
    // system prompt is rebuilt per request — nothing persists on its own).
    // A cache miss rebuilds the session's current tier: startup normally,
    // cruise once the session has been compacted — the full startup block
    // never returns after a compaction, even on a rebuilt cache.
    "experimental.chat.system.transform": async (input, output) => {
      const sid = input.sessionID
      // Summary-pass suppression (flagged by the compacting hook below):
      // the summary request forbids tool calls, and the block's "invoke the
      // skill" hint in its system prompt primes exactly the
      // hallucinated-tool-call failure that aborts compaction ("Tool call
      // not allowed while generating summary"). The flag is NOT consumed
      // here — opencode retries the summary request on provider errors and
      // every attempt re-fires this transform — it clears on
      // session.compacted (success) or session.idle (failure/abort), so a
      // failed compaction re-enables injection from the next turn.
      // Workspace durables reach the summary through the compacting hook's
      // context channel instead.
      if (sid && compactingNow.has(sid)) return
      if (sid && ctxCache.has(sid)) {
        const cached = ctxCache.get(sid)!
        if (cached) output.system.push(cached)
        return
      }

      const ctx = await buildContext(!(sid && compactedSessions.has(sid)))

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
      // Refresh the cached block after real orbit CLI invocations (workspace
      // state may have changed). Pre-compact the refresh rebuilds the full
      // startup block — Claude/Qoder parity, where the injected block rides
      // conversation history for the whole pre-compact session. After a
      // compaction the refresh stays on the cruise block: compaction means
      // context pressure, so full memos are never re-injected after one.
      // Only update on a successful rebuild — if it fails (orbit missing,
      // CWD left the workspace) keep the previous cache so the next
      // transform still sees context rather than a permanent hole.
      if (input.tool === "bash" && input.sessionID) {
        const args = input.args as Record<string, unknown> | undefined
        const cmd = typeof args?.command === "string" ? args.command : ""
        if (invokesOrbitCli(cmd) && ctxCache.has(input.sessionID)) {
          const fresh = await buildContext(!compactedSessions.has(input.sessionID))
          if (fresh) ctxCache.set(input.sessionID, fresh)
        }
      }
    },

    // ── Compaction guard ───────────────────────────────────────────────
    // Fires before the summary pass: flag the session so the system
    // transform skips injection (above), and hand the workspace durables
    // to the summary prompt through opencode's official channel — without
    // this the summary would lose goal/state entirely, since hook-injected
    // context lives in the system prompt, not in message history. Bare
    // cruise text: no tags, no skill hint (instructions prime tool calls,
    // which are forbidden in this pass).
    "experimental.session.compacting": async (input, output) => {
      try {
        if (input.sessionID) compactingNow.add(input.sessionID)
        const text = await rawContext(false)
        if (text) output.context.push(text)
      } catch {
        // fail-safe: compaction proceeds without orbit context
      }
    },

    event: async ({ event }) => {
      try {
        // ── Compaction episode end (failure/abort path) ────────────────
        // A failed compaction never publishes session.compacted (opencode
        // only publishes it on success), so clear the summary-pass
        // suppression flag when the session goes idle — the next turn's
        // transform injects normally again.
        if (event.type === "session.idle") {
          const sessionID = (event.properties as { sessionID?: string }).sessionID
          if (sessionID) compactingNow.delete(sessionID)
          return
        }
        // ── SessionStart:compact equivalent ────────────────────────────
        // After compaction, inject the light cruise block two ways: as an
        // immediate prompt (the compacted history is gone), and into the
        // cache so subsequent transforms re-inject it. Marking the session
        // compacted also pins later cache refreshes to the cruise tier —
        // the full startup block never returns after a compaction.
        if (event.type !== "session.compacted") return
        const sessionID = (event.properties as { sessionID?: string }).sessionID
        if (!sessionID) return
        compactedSessions.add(sessionID)
        compactingNow.delete(sessionID)

        // On build failure (orbit missing / CWD left the workspace), drop the
        // cache entry rather than leave a stale startup block behind — the
        // session is now cruise-pinned, and the next transform's cache-miss
        // path rebuilds the cruise tier anyway.
        const ctx = await buildContext(false)
        if (!ctx) {
          ctxCache.delete(sessionID)
          return
        }
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

// OpenCode's plugin loader enumerates EVERY value exported by this module
// and throws "Plugin export is not a function" on anything that is not a
// plugin function — a stray `export const` here kills the whole plugin at
// load time. The helpers above must stay off the module's export surface;
// tests reach them as properties of the default-exported function (typeof
// is still "function", and the single-file install copies just this file).
export default Object.assign(orbitPlugin, {
  STARTUP_HINT,
  CRUISE_HINT,
  wrapContext,
  invokesOrbitCli,
})
