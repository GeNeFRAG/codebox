#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# verify-pi-extensions.sh — exercise the Pi extensions in lib/pi-ext/
# ═══════════════════════════════════════════════════════════════════
# Must run INSIDE a CodeBox container: it loads the extensions through
# the same jiti loader pi uses, and the docker cases need the guard shim
# and the mounted docker socket.
#
#   ./scripts/verify-pi-extensions.sh            # everything
#   SKIP_MCP=1 ./scripts/verify-pi-extensions.sh # guard only (no spawns)
#
# Exit 0 = all cases pass. The guard cases are assertions about what must
# and must not be blocked; the "[must pass]" ones are the regressions that
# matter most — a guard that blocks .gitignore or `docker run` is worse
# than no guard, because it gets switched off.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
EXT_DIR="${REPO}/lib/pi-ext"
PI_PKG="/usr/local/lib/node_modules/@earendil-works/pi-coding-agent"
JITI="${PI_PKG}/node_modules/jiti/lib/jiti.mjs"

fail() { echo "✗ $1"; exit 1; }

[ -d "${EXT_DIR}" ] || fail "no ${EXT_DIR} — run this inside the container, from the repo"
[ -r "${JITI}" ] || fail "pi's jiti loader not found at ${JITI} (is this a CodeBox container?)"
command -v node >/dev/null || fail "node not on PATH"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ─── 1. Guard: what must and must not be blocked ────────────────────
echo "→ codebox-guard.ts"

DOCKER_CASES=1
if ! docker ps >/dev/null 2>&1; then
    echo "  ⚠ docker socket unavailable — skipping docker verdict cases"
    DOCKER_CASES=0
fi

cat > "${WORK}/guard.mjs" <<EOF
import { createJiti } from "${JITI}";
import { readFileSync } from "node:fs";

const jiti = createJiti(import.meta.url, { moduleCache: false });
const factory = await jiti.import("${EXT_DIR}/codebox-guard.ts", { default: true });

let handler;
factory({ on: (_event, h) => { handler = h; } });
if (!handler) { console.log("  ✗ extension registered no tool_call handler"); process.exit(1); }

const ctx = { cwd: "/workspace", hasUI: false, ui: { notify: () => {} }, signal: undefined };
const dockerCases = ${DOCKER_CASES} === 1;
let fails = 0;
let cases = 0;

async function check(label, event, expectBlock) {
  cases++;
  const result = await handler(event, ctx);
  const blocked = Boolean(result && result.block);
  if (blocked !== expectBlock) {
    fails++;
    console.log(\`  ✗ \${label} — expected \${expectBlock ? "BLOCK" : "PASS"}, got \${blocked ? "BLOCK" : "PASS"}\`);
  }
}

const write = (path) => ({ toolName: "write", input: { path, content: "x" } });
const edit = (path) => ({ toolName: "edit", input: { path, edits: [] } });
const bash = (command) => ({ toolName: "bash", input: { command } });

// Protected paths via the file tools.
await check(".env relative", write(".env"), true);
await check(".env absolute", write("/workspace/.env"), true);
await check(".env @-prefixed", write("@/workspace/.env"), true);
await check(".env.local", edit(".env.local"), true);
await check("mounted /opt/opencode/.env", write("/opt/opencode/.env"), true);
await check("/root/.ssh/id_rsa", write("/root/.ssh/id_rsa"), true);
await check("generated pi settings", edit("/root/.pi/agent/settings.json"), true);
await check("read-only /opt/opencode", edit("/opt/opencode/lib/config.sh"), true);
await check(".git/config", write(".git/config"), true);
await check("no path given", { toolName: "write", input: {} }, true);
await check(".env.example [must pass]", edit(".env.example"), false);
await check(".gitignore [must pass]", edit(".gitignore"), false);
await check(".github/workflows [must pass]", edit(".github/workflows/ci.yml"), false);
await check("repo lib/config.sh [must pass]", edit("lib/config.sh"), false);
await check("docker-compose.yml [must pass]", edit("docker-compose.yml"), false);

// Protected paths via bash. Models reach for these the moment write is refused.
await check("bash redirect", bash("echo HACKED=1 > .env"), true);
await check("bash append", bash("echo x >> /workspace/.env"), true);
await check("bash tee", bash("echo x | tee .env"), true);
await check("bash sed -i", bash("sed -i 's/a/b/' .env"), true);
await check("bash cp destination", bash("cp /tmp/x /workspace/.env"), true);
await check("bash mv destination", bash("mv /tmp/x .env"), true);
await check("bash rm", bash("rm -f .env"), true);
await check("bash dd of=", bash("dd if=/dev/zero of=/workspace/.env"), true);
await check("bash -c nested redirect", bash('bash -c "echo x > .env"'), true);
await check("redirect before program", bash("> .env cat /tmp/x"), true);
await check("bash into /root/.ssh", bash("echo k > /root/.ssh/authorized_keys"), true);
await check("cat .env [must pass]", bash("cat .env"), false);
await check("grep .env [must pass]", bash("grep SECRET .env"), false);
await check("2>&1 is not a file [must pass]", bash("ls /tmp 2>&1 | head"), false);
await check("write .env.example [must pass]", bash("echo x > .env.example"), false);
await check("unrelated file [must pass]", bash("echo x > /tmp/scratch.txt"), false);
await check("copy .env elsewhere [must pass]", bash("cp .env /tmp/copy"), false);
await check("unexpanded \\\$VAR target [must pass]", bash("echo x > \\\$TARGET"), false);

// Docker verdicts, delegated to lib/guard-bin/docker in dry-run mode.
if (dockerCases) {
  const self = readFileSync("/etc/hostname", "utf8").trim();
  await check("docker stop self", bash(\`docker stop \${self}\`), true);
  await check("absolute-path bypass", bash(\`/usr/local/bin/docker rm -f \${self}\`), true);
  await check("sudo + env prefix", bash(\`FOO=1 sudo docker kill \${self}\`), true);
  await check("chained after cd", bash(\`cd /tmp && docker stop \${self}\`), true);
  await check("nested bash -c", bash(\`bash -c "docker stop \${self}"\`), true);
  await check("docker compose down", bash("docker compose down"), true);
  await check("host-wide prune", bash("docker system prune -af"), true);
  await check("docker ps [must pass]", bash("docker ps -a"), false);
  await check("docker run [must pass]", bash("docker run -i --rm alpine true"), false);
  await check("mcp-run reap [must pass]", bash("docker rm -f mcp-time"), false);
  await check("docker in prose [must pass]", bash("grep -rn docker README.md"), false);
}
console.log(\`  cases=\${cases}\`);
process.exit(fails ? 1 : 0);
EOF

# The case count is checked, not just the exit status. An unquoted heredoc
# treats backticks as command substitution, so one unescaped backtick can
# silently drop JS lines and leave a harness that asserts nothing and exits
# 0 — which is exactly how this script first "passed".
guard_out="${WORK}/guard.out"
node "${WORK}/guard.mjs" > "${guard_out}" 2>&1; guard_rc=$?
grep -v '^  cases=' "${guard_out}" || true
cases="$(sed -n 's/^  cases=//p' "${guard_out}")"
[ "${guard_rc}" -eq 0 ] || fail "guard extension has incorrect verdicts (see above)"
[ "${cases:-0}" -ge 40 ] || fail "guard harness ran only ${cases:-0} cases — the heredoc lost lines"
echo "  ✓ guard verdicts correct (${cases} cases)"

# The dry-run probe must never execute, even with the bypass set — the
# guard extension probes `docker stop <self>` on every bash call that
# mentions docker, so a regression here stops the container.
if [ "${DOCKER_CASES}" -eq 1 ]; then
    out="$(CODEBOX_ALLOW_IN_CONTAINER=true CODEBOX_GUARD_DRYRUN=1 \
        "${REPO}/lib/guard-bin/docker" stop "$(cat /etc/hostname)" 2>&1)"
    case "${out}" in
        ALLOW*) echo "  ✓ dry-run + CODEBOX_ALLOW_IN_CONTAINER does not execute" ;;
        *) fail "guard shim dry-run did not short-circuit the bypass (got: ${out})" ;;
    esac
fi

# ─── 2. MCP bridge: assemble, discover, call ────────────────────────
if [ "${SKIP_MCP:-0}" = "1" ]; then
    echo "→ codebox-mcp.ts (skipped: SKIP_MCP=1)"
    echo "✓ Pi extensions verified (guard only)"
    exit 0
fi

echo "→ codebox-mcp.ts"
command -v jq >/dev/null || fail "jq not on PATH"

# Only the two servers baked into the image, so this needs no network and
# spawns no containers.
jq -n '{mcpServers: {
    time: {type: "stdio", command: "mcp-time-server", args: []},
    memory: {type: "stdio", command: "mcp-server-memory", args: [],
             env: {MEMORY_FILE_PATH: "'"${WORK}"'/memory.json"}}
}}' > "${WORK}/mcp-servers.json"

cat > "${WORK}/mcp.mjs" <<EOF
import { createJiti } from "${JITI}";
import { existsSync, readFileSync } from "node:fs";

process.env.CODEBOX_PI_MCP_CONFIG = "${WORK}/mcp-servers.json";
process.env.CODEBOX_PI_MCP_CACHE = "${WORK}/mcp-tools-cache.json";
process.env.CODEBOX_PI_MCP_TIMEOUT = "60000";

const jiti = createJiti(import.meta.url, { moduleCache: false });
const load = async () => {
  const factory = await jiti.import("${EXT_DIR}/codebox-mcp.ts", { default: true });
  const tools = new Map();
  const handlers = new Map();
  factory({ registerTool: (t) => tools.set(t.name, t), on: (e, h) => handlers.set(e, h) });
  return { tools, handlers };
};
const ctx = { hasUI: false, cwd: "/workspace", ui: { setStatus: () => {}, notify: () => {} } };
let fails = 0;
const assert = (ok, label) => { if (!ok) { fails++; console.log(\`  ✗ \${label}\`); } };

// Cold: no cache, so session_start discovers in the background.
const cold = await load();
assert(cold.tools.size === 0, "cold load registered tools without a cache");
await cold.handlers.get("session_start")({}, ctx);
for (let i = 0; i < 120 && !existsSync(process.env.CODEBOX_PI_MCP_CACHE); i++) {
  await new Promise((r) => setTimeout(r, 500));
}
await new Promise((r) => setTimeout(r, 300));
assert(cold.tools.size > 0, "discovery registered no tools");
assert(cold.tools.has("mcp__time__get_current_time"), "expected mcp__time__get_current_time");

for (const [name, tool] of cold.tools) {
  assert(/^[A-Za-z0-9_-]{1,64}\$/.test(name), \`tool name not wire-safe: \${name}\`);
  assert(tool.parameters?.type === "object", \`tool schema not an object: \${name}\`);
  assert(tool.parameters?.properties !== undefined, \`tool schema has no properties: \${name}\`);
  assert(!("\\\$schema" in tool.parameters), \`tool schema kept \\\$schema: \${name}\`);
}

// A real call over the wire.
const result = await cold.tools.get("mcp__time__get_current_time").execute("t1", {});
assert(Array.isArray(result?.content) && result.content[0]?.type === "text", "tool call returned no text content");

// Protocol errors must throw, so pi flags the result as an error.
let threw = false;
try {
  await cold.tools.get("mcp__memory__delete_entities").execute("t2", { entityNames: "not-an-array" });
} catch { threw = true; }
assert(threw, "an MCP protocol error did not throw");

// Cancellation must win even when the signal aborted before the request.
const aborted = AbortSignal.abort();
let cancelled = false;
try {
  await cold.tools.get("mcp__time__get_current_time").execute("t3", {}, aborted);
} catch { cancelled = true; }
assert(cancelled, "an already-aborted signal was ignored");

await cold.handlers.get("session_shutdown")({}, ctx);

// Warm: the cache alone must register the same tools, spawning nothing.
const warm = await load();
assert(warm.tools.size === cold.tools.size, "cache did not restore the full tool set");
const cache = JSON.parse(readFileSync(process.env.CODEBOX_PI_MCP_CACHE, "utf8"));
assert(Object.keys(cache).length === 2, "cache does not cover both servers");

// A changed server config must invalidate its cache entry.
process.env.CODEBOX_PI_MCP_CONFIG = "${WORK}/mcp-servers-changed.json";
const changed = await load();
assert(changed.tools.size < warm.tools.size, "a changed server config reused its stale cache");

// Path derivation: with neither override set, the config must be found
// relative to PI_CODING_AGENT_DIR. Hardcoding ~/.pi/agent here once cost
// a silent "no MCP tools" in every relocated config dir.
delete process.env.CODEBOX_PI_MCP_CONFIG;
delete process.env.CODEBOX_PI_MCP_CACHE;
process.env.PI_CODING_AGENT_DIR = "${WORK}";
const derived = await load();
assert(derived.tools.size === warm.tools.size, "config not found via PI_CODING_AGENT_DIR");

console.log(\`  \u2713 \${cold.tools.size} tools discovered, called, cached and restored\`);
process.exit(fails ? 1 : 0);
EOF

jq '.mcpServers.time.args = ["--changed"]' "${WORK}/mcp-servers.json" > "${WORK}/mcp-servers-changed.json"

mcp_out="${WORK}/mcp.out"
node "${WORK}/mcp.mjs" > "${mcp_out}" 2>&1; mcp_rc=$?
cat "${mcp_out}"
[ "${mcp_rc}" -eq 0 ] || fail "MCP bridge extension failed (see above)"
grep -q "cached and restored" "${mcp_out}" \
    || fail "MCP harness did not run to completion — the heredoc lost lines"

echo "✓ Pi extensions verified"
