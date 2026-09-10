/**
 * ─── CodeBox MCP bridge — Pi extension ──────────────────────────────────
 *
 * Pi has no MCP client and no plans for one: "it intentionally does not
 * include built-in MCP … you can build or install those workflows as
 * extensions" (pi docs/usage.md). CodeBox runs ten MCP servers for
 * OpenCode and Claude Code; before this extension, `CODEBOX_APP=pi` got
 * none of them. Skills only replaced the *prompt* half of that gap —
 * this replaces the tool half.
 *
 * Nothing about the server fleet is duplicated here. lib/config.sh
 * assembles the same templates/mcp-servers/*.json fragments it already
 * assembles for Claude Code, applies the same CODEBOX_MCP_<NAME> gating
 * and the same envsubst pass, and drops the result at
 * /root/.pi/agent/mcp-servers.json. This file only speaks the protocol.
 * Adding a server therefore stays a one-fragment change and it shows up
 * in all three agents.
 *
 * ── Why tool discovery is cached ──
 * MCP has no way to learn a server's tools without starting it, and
 * starting all of them costs real time: half are `npx`/node processes and
 * half are sibling containers spawned through bin/mcp-run (a first-run
 * `docker pull` can take minutes). Blocking startup on that is not an
 * option, so:
 *   - tools are registered synchronously from a disk cache keyed by a
 *     hash of each server's own config, so a normal boot registers
 *     everything before the first prompt and spawns nothing;
 *   - servers whose cache entry is missing or stale are discovered in
 *     the background at session_start and registered as they arrive
 *     (pi.registerTool works mid-session and refreshes the tool set);
 *   - a server process is started on the first actual tools/call and
 *     kept for the rest of the session. Discovery closes its client
 *     again afterwards: this container has a 2.5G memory cap and idling
 *     ten servers to hold ten tool lists is a poor trade.
 *
 * ── Context cost ──
 * Every registered tool's schema is sent on every request. The full fleet
 * is 100+ tools; mcp-atlassian and the GitHub servers dominate. That is
 * the same bill Claude Code already pays, which is what "parity" means
 * here, but it is a real one — the footer status shows the live count so
 * it is visible rather than mysterious. Trim with CODEBOX_MCP_<NAME>=false
 * (all agents) or CODEBOX_PI_MCP_SERVERS (pi only). Note mcp-atlassian
 * overlaps the `atl` skill, which is far cheaper for the same job.
 *
 * Env:
 *   CODEBOX_PI_MCP=false            — don't load at all (lib/config.sh)
 *   CODEBOX_PI_MCP_SERVERS=a,b      — narrow to these servers (pi only)
 *   CODEBOX_PI_MCP_TIMEOUT=120000   — per-request timeout in ms
 *   CODEBOX_PI_MCP_CONFIG / _CACHE  — override file locations
 */

import type { ImageContent, TextContent } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { type ChildProcess, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, renameSync, writeFileSync } from "node:fs";

/**
 * Follow PI_CODING_AGENT_DIR rather than hardcoding ~/.pi/agent.
 * lib/config.sh exports that variable specifically so every pi invocation
 * agrees on where its config lives, and it also exports the two paths
 * below directly — this fallback is for the case where the extension is
 * loaded by a pi started outside entrypoint.sh.
 */
const AGENT_DIR = process.env.PI_CODING_AGENT_DIR || `${process.env.HOME || "/root"}/.pi/agent`;
const CONFIG_FILE = process.env.CODEBOX_PI_MCP_CONFIG || `${AGENT_DIR}/mcp-servers.json`;
const CACHE_FILE = process.env.CODEBOX_PI_MCP_CACHE || `${AGENT_DIR}/mcp-tools-cache.json`;
const TIMEOUT_MS = Number(process.env.CODEBOX_PI_MCP_TIMEOUT) || 120_000;

/** The protocol revision every server in the fleet is known to accept. */
const PROTOCOL_VERSION = "2024-11-05";
/** LLM tool-name limit shared by the OpenAI and Anthropic wire formats. */
const MAX_TOOL_NAME = 64;

interface ServerSpec {
	name: string;
	command: string;
	args: string[];
	env: Record<string, string>;
	/** Hash of the above — the cache key, so config edits invalidate it. */
	hash: string;
}

interface McpTool {
	name: string;
	description?: string;
	inputSchema?: Record<string, unknown>;
}

type CacheFile = Record<string, { hash: string; tools: McpTool[] }>;

// ─── Config and cache ───────────────────────────────────────────────────

function readJson<T>(path: string): T | undefined {
	try {
		return JSON.parse(readFileSync(path, "utf8")) as T;
	} catch {
		return undefined;
	}
}

function loadServers(): ServerSpec[] {
	const raw = readJson<{ mcpServers?: Record<string, Record<string, unknown>> }>(CONFIG_FILE);
	if (!raw?.mcpServers) return [];

	const allow = (process.env.CODEBOX_PI_MCP_SERVERS ?? "")
		.split(/[,\s]+/)
		.map((s) => s.trim())
		.filter(Boolean);

	const specs: ServerSpec[] = [];
	for (const [name, entry] of Object.entries(raw.mcpServers)) {
		// Only stdio servers: an HTTP/SSE server would need a different
		// transport, and CodeBox does not ship one.
		const type = typeof entry.type === "string" ? entry.type : "stdio";
		if (type !== "stdio") continue;
		if (typeof entry.command !== "string" || !entry.command) continue;
		if (allow.length && !allow.includes(name)) continue;

		const args = Array.isArray(entry.args) ? entry.args.map(String) : [];
		const env: Record<string, string> = {};
		if (entry.env && typeof entry.env === "object") {
			for (const [k, v] of Object.entries(entry.env as Record<string, unknown>)) {
				if (v !== undefined && v !== null) env[k] = String(v);
			}
		}
		const hash = createHash("sha1")
			.update(JSON.stringify({ command: entry.command, args, env }))
			.digest("hex")
			.slice(0, 16);
		specs.push({ name, command: entry.command, args, env, hash });
	}
	return specs.sort((a, b) => a.name.localeCompare(b.name));
}

function loadCache(): CacheFile {
	return readJson<CacheFile>(CACHE_FILE) ?? {};
}

/**
 * Write via temp file + rename. A half-written cache would be parsed as
 * "no cache" on the next boot, which is recoverable, but a torn file that
 * happens to parse would register a truncated tool set — worse, and
 * invisible.
 */
function saveCache(cache: CacheFile): void {
	try {
		const tmp = `${CACHE_FILE}.tmp`;
		writeFileSync(tmp, `${JSON.stringify(cache, null, 2)}\n`, { mode: 0o600 });
		renameSync(tmp, CACHE_FILE);
	} catch {
		// A read-only or full filesystem costs us the fast path, nothing else.
	}
}

// ─── MCP stdio client ───────────────────────────────────────────────────

interface Pending {
	resolve: (value: unknown) => void;
	reject: (error: Error) => void;
	timer: NodeJS.Timeout;
}

/**
 * Minimal JSON-RPC 2.0 client over a child process's stdio, which is all
 * the MCP stdio transport is: one JSON object per line, `\n`-delimited.
 */
class McpClient {
	private child?: ChildProcess;
	private buffer = "";
	private nextId = 1;
	private pending = new Map<number, Pending>();
	private stderrTail: string[] = [];
	private ready?: Promise<void>;

	constructor(private readonly spec: ServerSpec) {}

	/** Idempotent: one spawn + handshake per client, awaited by all callers. */
	ensureStarted(): Promise<void> {
		this.ready ??= this.start().catch((error) => {
			// Let the next caller retry from scratch rather than caching a
			// failure for the whole session — `docker pull` timing out once
			// should not disable a server until restart.
			this.ready = undefined;
			this.teardown();
			throw error;
		});
		return this.ready;
	}

	private async start(): Promise<void> {
		const child = spawn(this.spec.command, this.spec.args, {
			env: { ...process.env, ...this.spec.env },
			stdio: ["pipe", "pipe", "pipe"],
		});
		this.child = child;

		child.stdout?.setEncoding("utf8");
		child.stdout?.on("data", (chunk: string) => this.onStdout(chunk));
		child.stderr?.setEncoding("utf8");
		child.stderr?.on("data", (chunk: string) => {
			// Servers use stderr for logging; keep only enough to explain a
			// failed start, and never let a chatty server grow unbounded.
			this.stderrTail.push(chunk);
			if (this.stderrTail.length > 20) this.stderrTail.shift();
		});
		child.on("error", (error) => this.failAll(new Error(`${this.spec.name}: spawn failed: ${error.message}`)));
		child.on("exit", (code, signal) => {
			this.ready = undefined;
			this.failAll(new Error(`${this.spec.name}: exited (${signal ?? code})${this.stderrSummary()}`));
		});

		await this.request("initialize", {
			protocolVersion: PROTOCOL_VERSION,
			// No capabilities declared, so no server should ask us to sample
			// or to list roots. onStdout answers anyway, in case one does.
			capabilities: {},
			clientInfo: { name: "codebox-pi", version: "1" },
		});
		this.notify("notifications/initialized");
	}

	private onStdout(chunk: string): void {
		this.buffer += chunk;
		let newline = this.buffer.indexOf("\n");
		while (newline !== -1) {
			const line = this.buffer.slice(0, newline).trim();
			this.buffer = this.buffer.slice(newline + 1);
			newline = this.buffer.indexOf("\n");
			if (!line) continue;

			let message: Record<string, unknown>;
			try {
				message = JSON.parse(line);
			} catch {
				continue; // not JSON-RPC — some servers print banners to stdout
			}

			// Server-initiated request: refuse politely so it does not hang.
			if (typeof message.method === "string" && message.id !== undefined) {
				this.send({
					jsonrpc: "2.0",
					id: message.id,
					error: { code: -32601, message: `${message.method} is not supported by this client` },
				});
				continue;
			}
			if (typeof message.id !== "number") continue; // notification

			const pending = this.pending.get(message.id);
			if (!pending) continue;
			this.pending.delete(message.id);
			clearTimeout(pending.timer);
			if (message.error) {
				const error = message.error as { message?: string; code?: number };
				pending.reject(new Error(error.message ?? `JSON-RPC error ${error.code ?? "?"}`));
			} else {
				pending.resolve(message.result);
			}
		}
	}

	private send(message: unknown): void {
		this.child?.stdin?.write(`${JSON.stringify(message)}\n`);
	}

	private notify(method: string, params?: unknown): void {
		this.send({ jsonrpc: "2.0", method, params });
	}

	private request(method: string, params?: unknown, signal?: AbortSignal): Promise<unknown> {
		if (!this.child || this.child.exitCode !== null) {
			return Promise.reject(new Error(`${this.spec.name}: server is not running`));
		}
		// Checked explicitly, not just wired to "abort": addEventListener never
		// fires on a signal that is already aborted, and ensureStarted() above
		// can take seconds (npx cold start, docker pull) — long enough for Esc
		// to land before the request is even sent.
		if (signal?.aborted) {
			return Promise.reject(new Error(`${this.spec.name}: ${method} cancelled`));
		}
		const id = this.nextId++;
		return new Promise((resolve, reject) => {
			const timer = setTimeout(() => {
				this.pending.delete(id);
				reject(new Error(`${this.spec.name}: ${method} timed out after ${TIMEOUT_MS}ms${this.stderrSummary()}`));
			}, TIMEOUT_MS);
			this.pending.set(id, { resolve, reject, timer });
			signal?.addEventListener(
				"abort",
				() => {
					if (!this.pending.delete(id)) return;
					clearTimeout(timer);
					reject(new Error(`${this.spec.name}: ${method} cancelled`));
				},
				{ once: true },
			);
			this.send({ jsonrpc: "2.0", id, method, params });
		});
	}

	async listTools(): Promise<McpTool[]> {
		await this.ensureStarted();
		const tools: McpTool[] = [];
		let cursor: string | undefined;
		do {
			const result = (await this.request("tools/list", cursor ? { cursor } : {})) as {
				tools?: McpTool[];
				nextCursor?: string;
			};
			for (const tool of result?.tools ?? []) {
				if (tool && typeof tool.name === "string") tools.push(tool);
			}
			cursor = result?.nextCursor;
		} while (cursor && tools.length < 500);
		return tools;
	}

	async callTool(name: string, args: unknown, signal?: AbortSignal): Promise<unknown> {
		await this.ensureStarted();
		return this.request("tools/call", { name, arguments: args ?? {} }, signal);
	}


	private stderrSummary(): string {
		const tail = this.stderrTail.join("").trim().split("\n").slice(-3).join(" | ");
		return tail ? ` — stderr: ${tail.slice(0, 400)}` : "";
	}

	private failAll(error: Error): void {
		for (const [, pending] of this.pending) {
			clearTimeout(pending.timer);
			pending.reject(error);
		}
		this.pending.clear();
	}

	private teardown(): void {
		const child = this.child;
		this.child = undefined;
		if (!child || child.exitCode !== null) return;
		child.kill("SIGTERM");
		// Servers that ignore SIGTERM would otherwise outlive the session and,
		// for the docker-socket ones, hold a container open.
		const hard = setTimeout(() => child.kill("SIGKILL"), 2000);
		hard.unref();
	}

	close(): void {
		this.ready = undefined;
		this.failAll(new Error(`${this.spec.name}: client closed`));
		this.teardown();
	}
}

// ─── Tool registration ──────────────────────────────────────────────────

/**
 * `mcp__<server>__<tool>`, the same namespace Claude Code uses, so the
 * allowlists in its settings.json and any muscle memory carry over.
 * Sanitised to the characters both wire formats accept, and truncated
 * with a hash tail rather than blindly, because two long tool names on
 * one server can share a 64-character prefix.
 */
function toolName(server: string, tool: string): string {
	const raw = `mcp__${server}__${tool}`.replace(/[^A-Za-z0-9_-]/g, "_");
	if (raw.length <= MAX_TOOL_NAME) return raw;
	const suffix = `_${createHash("sha1").update(raw).digest("hex").slice(0, 6)}`;
	return raw.slice(0, MAX_TOOL_NAME - suffix.length) + suffix;
}

/**
 * MCP `inputSchema` is already JSON Schema, and pi hands `parameters`
 * straight to the provider without typebox validation, so it can be used
 * as-is. Two fixes are still needed: `$schema` is noise some strict
 * endpoints reject, and Bedrock requires object schemas to carry a
 * `properties` key even when the tool takes no arguments.
 */
function toParameters(schema: McpTool["inputSchema"]): Record<string, unknown> {
	if (!schema || typeof schema !== "object" || Array.isArray(schema)) {
		return { type: "object", properties: {} };
	}
	const { $schema: _ignored, ...rest } = schema as Record<string, unknown>;
	return { type: "object", properties: {}, ...rest };
}

/** MCP content blocks → pi's `(TextContent | ImageContent)[]`. */
function toPiContent(result: unknown): Array<TextContent | ImageContent> {
	const blocks = (result as { content?: unknown[] })?.content;
	const out: Array<TextContent | ImageContent> = [];
	for (const block of Array.isArray(blocks) ? blocks : []) {
		if (!block || typeof block !== "object") continue;
		const item = block as Record<string, unknown>;
		if (item.type === "text" && typeof item.text === "string") {
			out.push({ type: "text", text: item.text });
		} else if (item.type === "image" && typeof item.data === "string") {
			// pi's ImageContent is {type,data,mimeType} — identical to MCP's.
			out.push({ type: "image", data: item.data, mimeType: String(item.mimeType ?? "image/png") });
		} else if (item.type === "resource" && item.resource && typeof item.resource === "object") {
			const resource = item.resource as Record<string, unknown>;
			const text = typeof resource.text === "string" ? resource.text : `[binary resource ${resource.uri ?? ""}]`;
			out.push({ type: "text", text });
		} else {
			out.push({ type: "text", text: JSON.stringify(item) });
		}
	}
	if (!out.length) {
		// structuredContent-only replies are legal and would otherwise reach
		// the model as an empty result.
		const structured = (result as { structuredContent?: unknown })?.structuredContent;
		out.push({ type: "text", text: structured === undefined ? "(no output)" : JSON.stringify(structured, null, 2) });
	}
	return out;
}

export default function (pi: ExtensionAPI) {
	const servers = loadServers();
	if (!servers.length) return;

	const clients = new Map<string, McpClient>();
	const registered = new Map<string, number>();
	let cache = loadCache();

	const clientFor = (spec: ServerSpec): McpClient => {
		let client = clients.get(spec.name);
		if (!client) {
			client = new McpClient(spec);
			clients.set(spec.name, client);
		}
		return client;
	};

	const register = (spec: ServerSpec, tools: McpTool[]): void => {
		for (const tool of tools) {
			pi.registerTool({
				name: toolName(spec.name, tool.name),
				label: `${spec.name}:${tool.name}`,
				description: tool.description ?? `MCP tool "${tool.name}" on server "${spec.name}"`,
				parameters: toParameters(tool.inputSchema),
				// No promptSnippet on purpose: pi would add a line per tool to
				// the system prompt's "Available tools" section, and 100+ lines
				// of that buys nothing the schemas do not already say.
				async execute(_toolCallId, params, signal) {
					const result = await clientFor(spec).callTool(tool.name, params, signal ?? undefined);
					// MCP reports tool-level failure in-band; pi only marks a
					// result as an error if execute throws.
					if ((result as { isError?: boolean })?.isError) {
						const text = toPiContent(result)
							.map((c) => (c.type === "text" ? String(c.text) : `[${String(c.type)}]`))
							.join("\n");
						throw new Error(text || `${spec.name}:${tool.name} failed`);
					}
					return { content: toPiContent(result), details: {} };
				},
			});
		}
		registered.set(spec.name, tools.length);
	};

	const showStatus = (ctx: ExtensionContext): void => {
		if (!ctx.hasUI) return;
		const tools = [...registered.values()].reduce((a, b) => a + b, 0);
		if (!tools) return;
		ctx.ui.setStatus("codebox-mcp", `mcp ${registered.size} servers / ${tools} tools`);
	};

	// Register everything already known, before the first prompt and without
	// starting a single server.
	const stale = servers.filter((spec) => {
		const entry = cache[spec.name];
		if (!entry || entry.hash !== spec.hash) return true;
		register(spec, entry.tools);
		return false;
	});

	pi.on("session_start", async (_event, ctx) => {
		showStatus(ctx);
		if (!stale.length) return;

		// Sequential: ten concurrent spawns (several of them `docker run`)
		// would spike memory against the container's 2.5G cap at exactly the
		// moment the user is trying to type.
		const discover = async () => {
			const failures: string[] = [];
			for (const spec of stale.splice(0)) {
				const client = clientFor(spec);
				try {
					const tools = await client.listTools();
					register(spec, tools);
					cache = { ...cache, [spec.name]: { hash: spec.hash, tools } };
				} catch (error) {
					failures.push(`${spec.name}: ${error instanceof Error ? error.message : String(error)}`);
				} finally {
					// Discovery does not imply use — give the RAM back.
					client.close();
					clients.delete(spec.name);
				}
			}
			// Drop entries for servers that are no longer configured, so a
			// disabled server's tools cannot come back from cache.
			const live = new Set(servers.map((s) => s.name));
			saveCache(Object.fromEntries(Object.entries(cache).filter(([name]) => live.has(name))));
			showStatus(ctx);
			if (failures.length && ctx.hasUI) {
				ctx.ui.notify(`MCP discovery failed for ${failures.length} server(s): ${failures.join("; ")}`, "warning");
			}
		};

		// Interactive: don't block the TUI on it. A human takes seconds to
		// type a first prompt and the tools land inside one.
		//
		// Everything else (-p, --mode json, --mode rpc): await it. pi awaits
		// session_start handlers, so this delays startup by one discovery
		// pass — but a print-mode run can finish before a background pass
		// returns, and then the model is simply told it has no MCP tools.
		// Measured: a cold pass over the four local servers costs ~1s; the
		// cache means only the first run after a config change pays it.
		if (ctx.mode === "tui") void discover();
		else await discover();
	});

	pi.on("session_shutdown", async () => {
		for (const client of clients.values()) client.close();
		clients.clear();
	});
}
