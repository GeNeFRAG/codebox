#!/usr/bin/env node
/**
 * Prefill Proxy — Strips trailing assistant messages from OpenAI-compatible
 * chat completion requests before forwarding to the upstream API.
 *
 * Workaround for: "This model does not support assistant message prefill.
 * The conversation must end with a user message."
 *
 * Claude 4.6 models dropped assistant prefill support, but OpenCode still
 * sends trailing assistant messages. This proxy intercepts and fixes them.
 *
 * Usage: UPSTREAM_URL=https://api.example.com node prefill-proxy.mjs
 * Listens on: http://localhost:${PROXY_PORT:-18080}
 */

import http from "node:http";
import https from "node:https";
import crypto from "node:crypto";

/* ── Configuration ─────────────────────────────────────────────────── */

const UPSTREAM_URL = process.env.UPSTREAM_URL;
const PROXY_PORT = parseInt(process.env.PROXY_PORT || "18080", 10);
const LOG_LEVEL = (process.env.PROXY_LOG_LEVEL || "info").toLowerCase(); // debug | info | warn | error

if (!UPSTREAM_URL) {
  console.error("[prefill-proxy] UPSTREAM_URL is required");
  process.exit(1);
}

const upstream = new URL(UPSTREAM_URL);

/* ── Logging ───────────────────────────────────────────────────────── */

const LEVELS = { debug: 0, info: 1, warn: 2, error: 3 };
const activeLevel = LEVELS[LOG_LEVEL] ?? LEVELS.info;

function ts() {
  return new Date().toISOString();
}

/** Short 6-char hex request ID for correlating log lines */
function reqId() {
  return crypto.randomBytes(3).toString("hex");
}

const log = {
  debug: (...args) =>
    activeLevel <= LEVELS.debug && console.log(`${ts()} DEBUG [prefill-proxy]`, ...args),
  info: (...args) =>
    activeLevel <= LEVELS.info && console.log(`${ts()}  INFO [prefill-proxy]`, ...args),
  warn: (...args) =>
    activeLevel <= LEVELS.warn && console.warn(`${ts()}  WARN [prefill-proxy]`, ...args),
  error: (...args) =>
    activeLevel <= LEVELS.error && console.error(`${ts()} ERROR [prefill-proxy]`, ...args),
};

/* ── Request stats ─────────────────────────────────────────────────── */

let totalRequests = 0;
let activeRequests = 0;
let totalStripped = 0;
let totalErrors = 0;

/* ── Helpers ───────────────────────────────────────────────────────── */

function stripTrailingAssistantMessages(body, id) {
  if (!body || !body.messages || !Array.isArray(body.messages)) return body;

  const messages = body.messages;
  let strippedCount = 0;

  while (
    messages.length > 0 &&
    messages[messages.length - 1].role === "assistant"
  ) {
    const removed = messages.pop();
    strippedCount++;
    log.info(
      `[${id}] Stripped trailing assistant message (${(removed.content || "").length} chars): "${(removed.content || "").slice(0, 100)}${(removed.content || "").length > 100 ? "…" : ""}"`
    );
  }

  if (strippedCount > 0) {
    totalStripped += strippedCount;
    log.info(`[${id}] Removed ${strippedCount} assistant prefill message(s), ${messages.length} messages remain`);
  }

  return body;
}

/** Summarise a chat-completion request body for logging */
function summariseRequest(body) {
  const parts = [];
  if (body.model) parts.push(`model=${body.model}`);
  if (body.messages) {
    const roles = {};
    for (const m of body.messages) roles[m.role] = (roles[m.role] || 0) + 1;
    parts.push(`msgs=${body.messages.length}(${Object.entries(roles).map(([r, c]) => `${r}:${c}`).join(",")})`);
  }
  if (body.stream !== undefined) parts.push(`stream=${body.stream}`);
  if (body.max_tokens) parts.push(`max_tokens=${body.max_tokens}`);
  if (body.temperature !== undefined) parts.push(`temp=${body.temperature}`);
  return parts.join(" ");
}

/* ── Server ────────────────────────────────────────────────────────── */

const server = http.createServer(async (req, res) => {
  const id = reqId();
  const startTime = performance.now();
  totalRequests++;
  activeRequests++;

  log.info(`[${id}] --> ${req.method} ${req.url} (active=${activeRequests})`);
  log.debug(`[${id}] Request headers: ${JSON.stringify(req.headers)}`);

  // Collect request body
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  let rawBody = Buffer.concat(chunks);

  const isChatCompletion =
    req.url?.includes("/chat/completions") && req.method === "POST";

  if (isChatCompletion) {
    try {
      const body = JSON.parse(rawBody.toString());
      log.info(`[${id}] Chat completion: ${summariseRequest(body)}`);
      const fixed = stripTrailingAssistantMessages(body, id);
      rawBody = Buffer.from(JSON.stringify(fixed));
    } catch (e) {
      log.error(`[${id}] Failed to parse request body: ${e.message}`);
    }
  } else {
    log.debug(`[${id}] Passthrough (not chat/completions)`);
  }

  // Build upstream URL: upstream base + request path
  const targetUrl = new URL(req.url, UPSTREAM_URL);
  log.debug(`[${id}] Forwarding to ${targetUrl.toString()}`);

  // Forward headers, updating host and content-length
  const headers = { ...req.headers };
  headers.host = upstream.host;
  headers["content-length"] = rawBody.length;

  const transport = upstream.protocol === "https:" ? https : http;

  const proxyReq = transport.request(
    targetUrl,
    {
      method: req.method,
      headers,
      // Respect NODE_EXTRA_CA_CERTS / system CAs
      rejectUnauthorized: true,
      // 5 min timeout — LLM responses can be slow but shouldn't hang forever
      timeout: 300_000,
    },
    (proxyRes) => {
      const elapsed = ((performance.now() - startTime) / 1000).toFixed(2);
      const status = proxyRes.statusCode;
      const level = status >= 500 ? "error" : status >= 400 ? "warn" : "info";
      log[level](
        `[${id}] <-- ${status} ${http.STATUS_CODES[status]} (${elapsed}s ttfb)`
      );
      log.debug(`[${id}] Response headers: ${JSON.stringify(proxyRes.headers)}`);

      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);

      // Log when the full response finishes streaming
      proxyRes.on("end", () => {
        activeRequests--;
        const total = ((performance.now() - startTime) / 1000).toFixed(2);
        log.info(`[${id}] Completed in ${total}s (active=${activeRequests})`);
      });
    }
  );

  proxyReq.on("timeout", () => {
    log.error(`[${id}] Upstream timeout after 300s`);
    proxyReq.destroy(new Error("Upstream timeout (300s)"));
  });

  proxyReq.on("error", (err) => {
    activeRequests--;
    totalErrors++;
    const elapsed = ((performance.now() - startTime) / 1000).toFixed(2);
    log.error(`[${id}] Upstream error after ${elapsed}s: ${err.message}`);
    if (!res.headersSent) {
      res.writeHead(502, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: { message: `Proxy error: ${err.message}` } }));
    }
  });

  // Abort upstream request if client disconnects mid-stream
  res.on("close", () => {
    if (!proxyReq.destroyed) {
      log.warn(`[${id}] Client disconnected, aborting upstream request`);
      proxyReq.destroy();
    }
  });

  proxyReq.write(rawBody);
  proxyReq.end();
});

/* ── Startup ───────────────────────────────────────────────────────── */

server.listen(PROXY_PORT, "127.0.0.1", () => {
  log.info(`Listening on http://127.0.0.1:${PROXY_PORT} -> ${UPSTREAM_URL}`);
  log.info(`Log level: ${LOG_LEVEL} (set PROXY_LOG_LEVEL=debug for verbose output)`);
});

/* ── Periodic stats (every 5 min while active) ─────────────────────── */

setInterval(() => {
  if (totalRequests > 0) {
    log.info(
      `Stats: total_requests=${totalRequests} active=${activeRequests} stripped=${totalStripped} errors=${totalErrors}`
    );
  }
}, 5 * 60 * 1000).unref();
