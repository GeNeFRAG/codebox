/**
 * ─── CodeBox guard — Pi extension ───────────────────────────────────────
 *
 * Pi ships no permission popups and no plan mode by design (see pi's
 * docs/usage.md), so the two things CodeBox guards for the other agents
 * have no equivalent here. This extension supplies them at the harness
 * layer, one `tool_call` hook ahead of execution:
 *
 *   1. Path protection — refuses `write`/`edit`, and the obvious
 *      file-clobbering shapes of `bash`, against the credential and
 *      generated-config files inside this container. The motivating case
 *      is `.env`: docker-compose.yml mounts it at /opt/opencode/.env AND
 *      the repo copy sits in the workspace, so 16 KB of gateway keys,
 *      Jira tokens and Grafana keys are one `edit` call away from being
 *      rewritten by a confused model. Covering only the file tools was
 *      not enough — the first model tested against this guard responded
 *      to the block by reaching for `cp` in bash.
 *
 *   2. Docker self-destruct — a second net in front of
 *      lib/guard-bin/docker. The PATH shim is still the enforcement
 *      layer (it sits in the execution path of every shell pi spawns);
 *      this hook exists to catch what the shim cannot see and to fail
 *      *before* the call runs:
 *        - `/usr/local/bin/docker …`, the shim's own documented bypass,
 *          which a model reaches for the moment the shim says no;
 *        - the reason text, which lands in the transcript as a tool
 *          block instead of as stderr the model has to re-read.
 *
 * ── Why it shells out to the shim instead of re-implementing it ──
 * The decision rules in lib/guard-bin/docker are subtle (Compose
 * container-number vs. project label, codebox.role=mcp exemptions,
 * inspect-miss-means-allow) and they were arrived at by getting them
 * wrong first. A TypeScript copy would drift from the bash original, and
 * the two would disagree exactly when it matters. So this hook runs the
 * shim itself in its dry-run mode (`CODEBOX_GUARD_DRYRUN=1`, which
 * prints `ALLOW` / `BLOCK  <reason>` and executes nothing) and forwards
 * its verdict. One set of rules, one file to audit.
 *
 * ── Failure policy ──
 * Path protection fails CLOSED for `write`/`edit`: an unreadable or odd
 * path is blocked. The docker probe fails OPEN: if the shim is missing,
 * times out, or the command is too shell-clever to parse, the call
 * proceeds — because the PATH shim still stands in the actual execution
 * path, and failing closed here would break `docker run` for every MCP
 * sibling container.
 *
 * The bash scan is best-effort by construction. It understands
 * redirections and the destination arguments of the usual suspects
 * (tee/sed -i/mv/cp/rm/dd/truncate/…), which is what models actually
 * emit; it does not understand `eval`, command substitution, or a
 * hand-rolled python one-liner, and it is not trying to. Treat it as
 * removing the easy path, not as a sandbox — if a real boundary is
 * needed, run pi against a container that cannot see the file at all.
 *
 * Env:
 *   CODEBOX_PI_GUARD=false          — don't load at all (lib/config.sh)
 *   CODEBOX_PI_GUARD_PATHS=a:b/     — extra protected files (trailing / = dir)
 *   CODEBOX_ALLOW_IN_CONTAINER=true — skip the docker probe (same knob
 *                                     the shim and codebox.sh honour)
 *   CODEBOX_GUARD_BIN=<path>        — override shim location
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { basename, resolve, sep } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const GUARD_SHIM = process.env.CODEBOX_GUARD_BIN || "/opt/opencode/lib/guard-bin/docker";
const PROBE_TIMEOUT_MS = 15_000;

/** Exact files that must not be rewritten by a tool call. */
const PROTECTED_FILES = new Set([
	"/opt/opencode/.env",
	"/root/.git-credentials",
	"/root/.gitconfig",
	"/root/.gitconfig-work",
	"/root/.tmux.conf",
]);

/**
 * Directory subtrees that must not be rewritten. These are either
 * read-only bind mounts (where a write fails anyway, but with a confusing
 * EROFS instead of a reason) or generated state that lib/config.sh
 * rewrites on every boot — an edit there looks like it worked and is
 * silently gone after the next restart.
 */
const PROTECTED_DIRS = [
	"/root/.ssh",
	"/root/.pi/agent",
	"/root/.claude",
	"/root/.config/opencode",
	"/root/.config/atl",
	"/root/.config/github-copilot",
	"/certs",
	"/opt/opencode",
	"/run",
];

/**
 * `.env` is matched by basename, not substring: the substring test in
 * pi's own protected-paths.ts example also blocks `.env.example`, which
 * is a tracked file in this repo that the agent has every reason to edit.
 */
const DOTENV_ALLOWED = new Set([".env.example", ".env.sample", ".env.template", ".env.dist"]);

/** Wrappers that prefix a real command without changing what it is. */
const WRAPPERS = new Set(["sudo", "doas", "env", "command", "nohup", "time", "nice", "stdbuf", "exec"]);
/** Shells whose `-c` argument is itself a command line worth descending into. */
const SHELLS = new Set(["bash", "sh", "zsh", "dash", "ash", "busybox"]);

const ENV_ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;

/**
 * Commands whose arguments name files they overwrite, and where those
 * arguments are: `all` non-flag operands, or only the `last` one (the
 * destination of a copy/move).
 */
const FILE_MUTATORS = new Map<string, "all" | "last">([
	["tee", "all"],
	["truncate", "all"],
	["rm", "all"],
	["shred", "all"],
	["unlink", "all"],
	["mv", "last"],
	["cp", "last"],
	["install", "last"],
	["ln", "last"],
]);

/** `>` `>>` `2>` `&>` … optionally glued to their target. */
const REDIRECT = /^(?:[0-9]*|&)(>>?)(.*)$/;

function extraProtectedPaths(): { files: string[]; dirs: string[] } {
	const raw = process.env.CODEBOX_PI_GUARD_PATHS;
	const files: string[] = [];
	const dirs: string[] = [];
	for (const entry of (raw ?? "").split(":")) {
		const trimmed = entry.trim();
		if (!trimmed) continue;
		if (trimmed.endsWith("/")) dirs.push(trimmed.replace(/\/+$/, ""));
		else files.push(trimmed);
	}
	return { files, dirs };
}

/**
 * Resolve a tool-supplied path the way the built-in tools do: strip the
 * stray leading `@` some models emit, expand `~`, and make it absolute
 * against the session cwd. Without this, `.env` and `/workspace/.env`
 * would be two different strings and only one of them would be caught.
 */
function resolveToolPath(raw: string, cwd: string): string {
	let p = raw.trim();
	if (p.startsWith("@")) p = p.slice(1);
	if (p === "~") p = process.env.HOME || "/root";
	else if (p.startsWith("~/")) p = `${process.env.HOME || "/root"}/${p.slice(2)}`;
	return resolve(cwd, p);
}

function isInside(path: string, dir: string): boolean {
	return path === dir || path.startsWith(dir.endsWith(sep) ? dir : dir + sep);
}

/** Returns a human reason when the path is protected, else undefined. */
function protectedReason(absolute: string): string | undefined {
	const extra = extraProtectedPaths();
	const name = basename(absolute);

	if ((name === ".env" || name.startsWith(".env.")) && !DOTENV_ALLOWED.has(name)) {
		return `${name} holds this container's credentials (gateway key, Jira/Confluence tokens, Grafana key)`;
	}
	if (PROTECTED_FILES.has(absolute) || extra.files.includes(absolute)) {
		return "it is a credential or host-supplied config file mounted into this container";
	}
	for (const dir of [...PROTECTED_DIRS, ...extra.dirs]) {
		if (isInside(absolute, dir)) {
			return `${dir}/ is either a read-only mount or state that lib/config.sh regenerates on every boot, so an edit here is silently lost on the next restart`;
		}
	}
	// Git internals. Component match, so .gitignore/.github/.gitconfig-work
	// (all legitimately editable) do not trip it.
	if (absolute.split(sep).includes(".git")) {
		return "it is inside a .git directory — use git commands rather than rewriting repository internals";
	}
	return undefined;
}

// ─── Docker command extraction ──────────────────────────────────────────
// Enough shell awareness to find `docker` invocations in a command line
// and hand their argv to the shim. Deliberately not a shell parser: what
// it misses (command substitution, eval, aliases) still meets the PATH
// shim at execution time.

/** Split a command line into segments of tokens, honouring quotes. */
function tokenizeSegments(command: string): string[][] {
	const segments: string[][] = [];
	let tokens: string[] = [];
	let current = "";
	let started = false;
	let quote: '"' | "'" | null = null;

	const endToken = () => {
		if (started) {
			tokens.push(current);
			current = "";
			started = false;
		}
	};
	const endSegment = () => {
		endToken();
		if (tokens.length) segments.push(tokens);
		tokens = [];
	};

	for (let i = 0; i < command.length; i++) {
		const c = command[i];
		if (quote) {
			if (c === quote) quote = null;
			else if (c === "\\" && quote === '"' && i + 1 < command.length) current += command[++i];
			else current += c;
			continue;
		}
		if (c === "'" || c === '"') {
			quote = c;
			started = true;
			continue;
		}
		if (c === "\\" && i + 1 < command.length) {
			current += command[++i];
			started = true;
			continue;
		}
		if (c === " " || c === "\t" || c === "\r") {
			endToken();
			continue;
		}
		if (c === "\n" || c === ";" || c === "&" || c === "|" || c === "(" || c === ")") {
			endSegment();
			continue;
		}
		current += c;
		started = true;
	}
	endSegment();
	return segments;
}

/** Index of the program in a segment, past env assignments and wrappers. */
function programIndex(segment: string[]): number {
	let i = 0;
	while (i < segment.length && (ENV_ASSIGNMENT.test(segment[i]) || WRAPPERS.has(basename(segment[i])))) {
		i++;
	}
	return i;
}

/** Every `docker` invocation in a command line, as argv without argv[0]. */
function dockerInvocations(command: string, depth = 0): string[][] {
	if (depth > 3) return [];
	const found: string[][] = [];

	for (const segment of tokenizeSegments(command)) {
		const i = programIndex(segment);
		if (i >= segment.length) continue;

		const program = basename(segment[i]);
		if (program === "docker") {
			found.push(segment.slice(i + 1));
			continue;
		}
		// `bash -c "docker stop x"` — descend into the script argument.
		if (SHELLS.has(program)) {
			const flag = segment.indexOf("-c", i + 1);
			if (flag !== -1 && segment[flag + 1]) {
				found.push(...dockerInvocations(segment[flag + 1], depth + 1));
			}
		}
	}
	return found;
}

/** Paths a command line would create, truncate, or overwrite. */
function bashWriteTargets(command: string, depth = 0): string[] {
	if (depth > 3) return [];
	const targets: string[] = [];

	for (const segment of tokenizeSegments(command)) {
		// Redirections can appear anywhere in a segment, including before
		// the program name (`> .env cat`), so scan the whole thing.
		for (let i = 0; i < segment.length; i++) {
			const match = REDIRECT.exec(segment[i]);
			if (!match) continue;
			// `2>&1` duplicates a descriptor; it names no file.
			const glued = match[2].startsWith("&") ? "" : match[2];
			if (glued) targets.push(glued);
			else if (segment[i + 1] && !segment[i + 1].startsWith("&")) targets.push(segment[++i]);
		}

		const start = programIndex(segment);
		if (start >= segment.length) continue;
		const program = basename(segment[start]);
		const rest = segment.slice(start + 1);
		const operands = rest.filter((token) => !token.startsWith("-") && !REDIRECT.test(token));

		const mutator = FILE_MUTATORS.get(program);
		if (mutator === "all") targets.push(...operands);
		else if (mutator === "last" && operands.length > 1) targets.push(operands[operands.length - 1]);

		// In-place editors: the first operand is the script, the rest are files.
		if ((program === "sed" || program === "perl") && rest.some((t) => t.startsWith("-i"))) {
			targets.push(...operands.slice(1));
		}
		if (program === "dd") {
			for (const token of rest) if (token.startsWith("of=")) targets.push(token.slice(3));
		}
		if (SHELLS.has(program)) {
			const flag = rest.indexOf("-c");
			if (flag !== -1 && rest[flag + 1]) targets.push(...bashWriteTargets(rest[flag + 1], depth + 1));
		}
	}
	return targets;
}

type Verdict = { blocked: true; reason: string } | { blocked: false } | undefined;

/**
 * Ask the shim what it would do. `CODEBOX_ALLOW_IN_CONTAINER=false` is
 * forced in the probe environment: the shim honours that variable *before*
 * anything else, so probing with it set to true would exec the real
 * Docker CLI — i.e. actually stop the container we are trying to protect.
 * (The shim short-circuits dry-run first for the same reason; belt and
 * braces, because this is not a mistake you get to make twice.)
 */
async function probeShim(args: string[], signal?: AbortSignal): Promise<Verdict> {
	try {
		const { stdout } = await execFileAsync(GUARD_SHIM, args, {
			env: { ...process.env, CODEBOX_GUARD_DRYRUN: "1", CODEBOX_ALLOW_IN_CONTAINER: "false" },
			timeout: PROBE_TIMEOUT_MS,
			maxBuffer: 1 << 20,
			signal,
		});
		const verdict = stdout.trim();
		if (verdict.startsWith("BLOCK")) {
			return { blocked: true, reason: verdict.slice("BLOCK".length).trim() };
		}
		if (verdict.startsWith("ALLOW")) return { blocked: false };
		return undefined;
	} catch {
		return undefined; // missing shim, timeout, abort → defer to the PATH shim
	}
}

export default function (pi: ExtensionAPI) {
	let shimWarned = false;

	/** Shared refusal text for a protected path, whatever tool reached it. */
	const refuse = (absolute: string, reason: string): string =>
		`CodeBox protects ${absolute}: ${reason}. ` +
		`Do not work around this with another tool — change the file on the host and restart the ` +
		`container (\`./codebox.sh restart <service>\`), or set CODEBOX_PI_GUARD=false to disable this guard.`;

	pi.on("tool_call", async (event, ctx) => {
		// ── 1. Path protection (fails closed) ──
		if (event.toolName === "write" || event.toolName === "edit") {
			const raw = (event.input as { path?: unknown }).path;
			if (typeof raw !== "string" || !raw.trim()) {
				return { block: true, reason: `${event.toolName} called without a usable path` };
			}
			const absolute = resolveToolPath(raw, ctx.cwd);
			const reason = protectedReason(absolute);
			if (reason) {
				if (ctx.hasUI) ctx.ui.notify(`Blocked ${event.toolName} → ${absolute}`, "warning");
				return { block: true, reason: refuse(absolute, reason) };
			}
			return undefined;
		}

		if (event.toolName !== "bash") return undefined;
		const command = (event.input as { command?: unknown }).command;
		if (typeof command !== "string") return undefined;

		// ── 2. The same protection for the bash shapes that clobber files ──
		for (const target of bashWriteTargets(command)) {
			// Anything the shell would still have to expand (globs, $VAR,
			// substitutions) is not a path we can judge; skip rather than guess.
			if (/[$`*?]/.test(target)) continue;
			const absolute = resolveToolPath(target, ctx.cwd);
			const reason = protectedReason(absolute);
			if (reason) {
				if (ctx.hasUI) ctx.ui.notify(`Blocked bash write → ${absolute}`, "warning");
				return { block: true, reason: refuse(absolute, reason) };
			}
		}

		// ── 3. Docker self-destruct (fails open) ──
		if (process.env.CODEBOX_ALLOW_IN_CONTAINER === "true") return undefined;
		if (!command.includes("docker")) return undefined;

		const invocations = dockerInvocations(command);
		if (!invocations.length) return undefined;

		for (const args of invocations) {
			const verdict = await probeShim(args, ctx.signal);
			if (verdict === undefined) {
				if (!shimWarned && ctx.hasUI) {
					shimWarned = true;
					ctx.ui.notify(`docker guard probe unavailable (${GUARD_SHIM}) — relying on the PATH shim`, "warning");
				}
				continue;
			}
			if (verdict.blocked) {
				if (ctx.hasUI) ctx.ui.notify(`Blocked docker ${args[0] ?? ""}`.trim(), "warning");
				return {
					block: true,
					reason:
						`Refusing \`docker ${args.join(" ")}\` inside a CodeBox container — ${verdict.reason}. ` +
						`This container shares the host Docker socket, so that command would take down the ` +
						`session running it. Run it in a terminal on the host instead. ` +
						`Bypass in here only if you mean it: CODEBOX_ALLOW_IN_CONTAINER=true docker …`,
				};
			}
		}
		return undefined;
	});
}
