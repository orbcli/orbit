import assert from "node:assert/strict"
import { test } from "node:test"
import orbitPlugin from "./plugin.ts"

// Helpers are attached to the default-exported plugin function — OpenCode's
// loader forbids non-plugin module exports ("Plugin export is not a
// function"), so plugin.ts cannot export them directly.
const { CRUISE_HINT, STARTUP_HINT, allowsOrbitCommand, invokesOrbitCli, wrapContext } = orbitPlugin

test("invokesOrbitCli: real orbit invocations", () => {
  assert.equal(invokesOrbitCli("orbit status"), true)
  assert.equal(invokesOrbitCli("orbit"), true)
  assert.equal(invokesOrbitCli("orbit.sh prune --dry-run"), true)
  assert.equal(invokesOrbitCli("/usr/local/bin/orbit context --startup"), true)
  assert.equal(invokesOrbitCli("./orbit.sh status"), true)
})

test("invokesOrbitCli: chained commands", () => {
  assert.equal(invokesOrbitCli("cd ws && orbit status"), true)
  assert.equal(invokesOrbitCli("git st; orbit jot x msg"), true)
  assert.equal(invokesOrbitCli("orbit status | cat"), true)
  assert.equal(invokesOrbitCli("false || orbit doctor"), true)
  assert.equal(invokesOrbitCli("sleep 1 & orbit version"), true)
})

test("invokesOrbitCli: workspace paths containing 'orbit' are not invocations", () => {
  // The original bug: substring matching treated any command touching an
  // orbit-* path as an orbit invocation and downgraded the injected context
  // block after the first `ls` of the session.
  assert.equal(invokesOrbitCli("ls /home/user/coding/orbit-demo"), false)
  assert.equal(invokesOrbitCli("git -C /home/user/coding/orbit-demo/orbit status"), false)
  assert.equal(invokesOrbitCli("cat /home/user/coding/orbit-demo/orbit.sh"), false)
  assert.equal(invokesOrbitCli("cd /home/user/coding/orbit-demo && ls"), false)
})

test("invokesOrbitCli: orbit as argument is not an invocation", () => {
  assert.equal(invokesOrbitCli("echo orbit"), false)
  assert.equal(invokesOrbitCli("echo orbit status"), false)
  assert.equal(invokesOrbitCli("orbitx status"), false)
  assert.equal(invokesOrbitCli(""), false)
})

test("invokesOrbitCli: interpreter/builtin prefixes", () => {
  assert.equal(invokesOrbitCli("bash orbit.sh status"), true)
  assert.equal(invokesOrbitCli("sh ./orbit.sh sync"), true)
  assert.equal(invokesOrbitCli("zsh /opt/orbit/orbit.sh repos"), true)
  assert.equal(invokesOrbitCli("command orbit status"), true)
  // orbit as an argument of another script is not an invocation
  assert.equal(invokesOrbitCli("bash deploy.sh orbit"), false)
  assert.equal(invokesOrbitCli("sh /tmp/build.sh"), false)
})

test("invokesOrbitCli: documented conservative misses", () => {
  // Env prefixes, `bash -c`, and command substitution are not detected —
  // they only skip a cache refresh, never corrupt state.
  assert.equal(invokesOrbitCli("ORBIT_REF=main orbit version"), false)
  assert.equal(invokesOrbitCli('bash -c "orbit status"'), false)
  assert.equal(invokesOrbitCli("echo $(orbit context goal)"), false)
})

test("hints are single well-formed XML comments", () => {
  for (const hint of [STARTUP_HINT, CRUISE_HINT]) {
    assert.match(hint, /^<!--[\s\S]*-->$/)
    // XML comments must not contain a double hyphen in their body.
    assert.equal(hint.slice(4, -3).includes("--"), false)
  }
})

test("startup hint is unconditional — a fresh session never has the skill", () => {
  assert.match(STARTUP_HINT, /before your first reply/)
  assert.equal(STARTUP_HINT.includes("skip"), false)
})

test("cruise hint keys on content-in-context, not loaded-this-session", () => {
  // A compaction can wipe the skill content while a summary still
  // "remembers" loading it — skipping on session history would misfire.
  assert.match(CRUISE_HINT, /skip only if its content is already in your context/)
  assert.equal(CRUISE_HINT.includes("already loaded this session"), false)
})

test("wrapContext: tier-specific hint inside the tags, content untouched", () => {
  const body = "path: /ws/orbit-demo\ngoal: ship it"
  assert.equal(wrapContext(body, true), `<orbit-context>\n${STARTUP_HINT}\n${body}\n</orbit-context>`)
  assert.equal(wrapContext(body, false), `<orbit-context>\n${CRUISE_HINT}\n${body}\n</orbit-context>`)
})

test("allowsOrbitCommand: safe tiers auto-approved", () => {
  assert.equal(allowsOrbitCommand("orbit status"), true)
  assert.equal(allowsOrbitCommand("orbit memo backend"), true)
  assert.equal(allowsOrbitCommand("orbit.sh jot backend \"discovery\""), true)
  assert.equal(allowsOrbitCommand("/usr/local/bin/orbit context --startup"), true)
})

test("allowsOrbitCommand: destructive / externally-visible tiers still prompt", () => {
  for (const sub of ["done", "prune", "clone", "config", "new"]) {
    assert.equal(allowsOrbitCommand(`orbit ${sub}`), false)
  }
})

test("allowsOrbitCommand: non-orbit binary and chained commands prompt", () => {
  assert.equal(allowsOrbitCommand("git status"), false)
  assert.equal(allowsOrbitCommand("orbitx status"), false)
  assert.equal(allowsOrbitCommand("orbit status && echo done"), false)
  assert.equal(allowsOrbitCommand("echo $(orbit status)"), false)
})

test("allowsOrbitCommand: sync --force prompts, matched token-exactly", () => {
  assert.equal(allowsOrbitCommand("orbit sync --force"), false)
  assert.equal(allowsOrbitCommand("orbit sync backend --force"), false)
  // Substring lookalikes must NOT trip the guard (the old cmd.includes bug).
  assert.equal(allowsOrbitCommand("orbit sync --forceful"), true)
  // A whitespace-delimited --force word conservatively trips it even inside
  // quotes (naive tokenization — fail-safe direction, same as the shell hook).
  assert.equal(allowsOrbitCommand('orbit sync --repo "a --force b"'), false)
})

test("allowsOrbitCommand: shell-equivalent --force spellings all prompt", () => {
  // bash hands every one of these to orbit as the same `--force`, so a guard
  // that only matches the bare spelling is a guard with a bypass.
  assert.equal(allowsOrbitCommand("orbit sync '--force'"), false)
  assert.equal(allowsOrbitCommand('orbit sync "--force"'), false)
  assert.equal(allowsOrbitCommand("orbit sync --force''"), false)
  assert.equal(allowsOrbitCommand("orbit sync \\-\\-force"), false)
  assert.equal(allowsOrbitCommand("orbit sync backend '--force'"), false)
})

test("allowsOrbitCommand: sync --branch prompts (pool-wide state, root-only)", () => {
  assert.equal(allowsOrbitCommand("orbit sync --branch dev"), false)
  assert.equal(allowsOrbitCommand("orbit sync backend --branch dev"), false)
  assert.equal(allowsOrbitCommand("orbit sync '--branch' dev"), false)
  // Lookalike must not trip it.
  assert.equal(allowsOrbitCommand("orbit sync --branches"), true)
})
