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
const PROXY_TIMEOUT = parseInt(process.env.PROXY_TIMEOUT || "120", 10) * 1000; // seconds → ms
const LOG_LEVEL = (process.env.PROXY_LOG_LEVEL || "info").toLowerCase(); // debug | info | warn | error

if (!UPSTREAM_URL) {
  console.error("[prefill-proxy] UPSTREAM_URL is required");
  process.exit(1);
}

const upstream = new URL(UPSTREAM_URL);

/* ── Connection pooling (keep-alive agents) ────────────────────────── */

const httpAgent = new http.Agent({
  keepAlive: true,
  keepAliveMsecs: 30_000,
  maxSockets: 16,          // max parallel upstream connections
  maxFreeSockets: 8,       // idle connections kept alive for reuse
  scheduling: "fifo",      // reuse the most-recently-freed socket
});

const httpsAgent = new https.Agent({
  keepAlive: true,
  keepAliveMsecs: 30_000,
  maxSockets: 16,
  maxFreeSockets: 8,
  scheduling: "fifo",
});

const transport = upstream.protocol === "https:" ? https : http;
const agent = upstream.protocol === "https:" ? httpsAgent : httpAgent;

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

/* ── Upstream connection tracking ───────────────────────────────────── */

/**
 * Log whether the upstream request reused a pooled socket or opened a new one,
 * and measure the TCP + TLS handshake time for new connections.
 */
function trackUpstreamConnect(proxyReq, id) {
  proxyReq.on("socket", (socket) => {
    if (socket._hadConnect) {
      // Reused keep-alive socket — no handshake cost
      log.info(`[${id}] Socket reused (keep-alive)`);
      return;
    }
    // Mark so we don't log again on reuse
    socket._hadConnect = true;
    const socketStart = performance.now();

    socket.on("connect", () => {
      const tcpMs = (performance.now() - socketStart).toFixed(1);
      log.info(`[${id}] TCP connected in ${tcpMs}ms`);
    });

    socket.on("secureConnect", () => {
      const tlsMs = (performance.now() - socketStart).toFixed(1);
      log.info(`[${id}] TLS handshake completed in ${tlsMs}ms`);
    });
  });
}

/* ── Shared upstream handlers ──────────────────────────────────────── */

/**
 * Per-request context to prevent double-decrementing activeRequests.
 * Multiple error paths (proxyRes error, proxyReq error, timeout) can fire
 * for the same request; only the first one should decrement the counter.
 */
function makeRequestCtx() {
  return { settled: false };
}
function settle(ctx) {
  if (ctx.settled) return false;
  ctx.settled = true;
  activeRequests--;
  return true;
}

function handleUpstreamResponse(proxyRes, res, id, startTime, ctx) {
  const elapsed = ((performance.now() - startTime) / 1000).toFixed(2);
  const status = proxyRes.statusCode;
  const level = status >= 500 ? "error" : status >= 400 ? "warn" : "info";
  log[level](
    `[${id}] <-- ${status} ${http.STATUS_CODES[status]} (${elapsed}s ttfb)`
  );
  log.debug(`[${id}] Response headers: ${JSON.stringify(proxyRes.headers)}`);

  res.writeHead(proxyRes.statusCode, proxyRes.headers);
  proxyRes.pipe(res);

  proxyRes.on("end", () => {
    settle(ctx);
    const total = ((performance.now() - startTime) / 1000).toFixed(2);
    log.info(`[${id}] Completed in ${total}s (active=${activeRequests})`);
  });
  proxyRes.on("error", () => {
    settle(ctx);
  });
}

function handleTimeout(proxyReq, res, id) {
  const timeoutSec = PROXY_TIMEOUT / 1000;
  log.error(`[${id}] Upstream timeout after ${timeoutSec}s`);
  proxyReq.destroy(new Error(`Upstream timeout (${timeoutSec}s)`));
  // If headers were already sent (mid-stream timeout), destroy the client
  // connection so OpenCode gets a socket error instead of silently waiting.
  if (res.headersSent && !res.writableEnded) {
    log.error(`[${id}] Destroying client connection (headers already sent — mid-stream timeout)`);
    res.destroy();
  }
}

function handleProxyError(err, res, id, startTime, ctx) {
  settle(ctx);
  totalErrors++;
  const elapsed = ((performance.now() - startTime) / 1000).toFixed(2);
  log.error(`[${id}] Upstream error after ${elapsed}s: ${err.message}`);
  if (!res.headersSent) {
    res.writeHead(502, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { message: `Proxy error: ${err.message}` } }));
  } else if (!res.writableEnded) {
    // Mid-stream error: headers already sent, can't send a clean error response.
    // Destroy the socket so the client gets a connection reset instead of hanging.
    log.error(`[${id}] Destroying client connection (mid-stream upstream error)`);
    res.destroy();
  }
}

function handleClientDisconnect(proxyReq, id, ctx) {
  if (!proxyReq.destroyed) {
    log.warn(`[${id}] Client disconnected, aborting upstream request`);
    settle(ctx);
    proxyReq.destroy();
  }
}

/* ── Server ────────────────────────────────────────────────────────── */

const server = http.createServer((req, res) => {
  const id = reqId();
  const startTime = performance.now();
  totalRequests++;
  activeRequests++;

  log.info(`[${id}] --> ${req.method} ${req.url} (active=${activeRequests})`);
  log.debug(`[${id}] Request headers: ${JSON.stringify(req.headers)}`);

  const isChatCompletion =
    req.url?.includes("/chat/completions") && req.method === "POST";

  // Build upstream URL once
  const targetUrl = new URL(req.url, UPSTREAM_URL);
  log.debug(`[${id}] Forwarding to ${targetUrl.toString()}`);

  // Forward headers, updating host; signal keep-alive to upstream
  const fwdHeaders = { ...req.headers, host: upstream.host, connection: "keep-alive" };

  // Shared upstream request options
  const reqOpts = {
    method: req.method,
    headers: fwdHeaders,
    agent,
    rejectUnauthorized: true,
    timeout: PROXY_TIMEOUT,
  };

  /**
   * Fast path: non-chat-completion requests are piped straight through
   * with zero buffering — saves memory and reduces TTFB.
   */
  if (!isChatCompletion) {
    log.debug(`[${id}] Passthrough (not chat/completions)`);

    const ctx = makeRequestCtx();
    const proxyReq = transport.request(
      targetUrl,
      reqOpts,
      (proxyRes) => handleUpstreamResponse(proxyRes, res, id, startTime, ctx)
    );

    proxyReq.on("timeout", () => handleTimeout(proxyReq, res, id));
    proxyReq.on("error", (err) => handleProxyError(err, res, id, startTime, ctx));
    res.on("close", () => handleClientDisconnect(proxyReq, id, ctx));

    trackUpstreamConnect(proxyReq, id);
    req.pipe(proxyReq);
    return;
  }

  /**
   * Chat completion path: buffer body → strip assistant messages → forward.
   *
   * Buffering is required to parse and modify the JSON body. Since the
   * client is on localhost, the buffering cost is negligible (<1ms).
   * The response path remains fully streaming (pipe).
   */
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", () => {
    let rawBody = Buffer.concat(chunks);
    let modified = false;

    try {
      const body = JSON.parse(rawBody.toString());
      log.info(`[${id}] Chat completion: ${summariseRequest(body)}`);

      // Only re-serialize if we actually strip messages (avoids
      // the JSON.stringify cost for requests that need no changes)
      const msgs = body.messages;
      if (msgs?.length && msgs[msgs.length - 1].role === "assistant") {
        stripTrailingAssistantMessages(body, id);
        rawBody = Buffer.from(JSON.stringify(body));
        modified = true;
      }
    } catch (e) {
      log.error(`[${id}] Failed to parse request body: ${e.message}`);
    }

    if (modified) fwdHeaders["content-length"] = rawBody.length;

    log.info(`[${id}] Body: ${(rawBody.length / 1024).toFixed(1)}KB${modified ? " (modified)" : ""}`);

    const ctx = makeRequestCtx();
    const proxyReq = transport.request(
      targetUrl,
      reqOpts,
      (proxyRes) => handleUpstreamResponse(proxyRes, res, id, startTime, ctx)
    );

    proxyReq.on("timeout", () => handleTimeout(proxyReq, res, id));
    proxyReq.on("error", (err) => handleProxyError(err, res, id, startTime, ctx));
    res.on("close", () => handleClientDisconnect(proxyReq, id, ctx));

    trackUpstreamConnect(proxyReq, id);
    proxyReq.end(rawBody);

    const proxyOverhead = ((performance.now() - startTime) / 1000).toFixed(3);
    log.info(`[${id}] Forwarded to upstream in ${proxyOverhead}s`);
  });
});

/* ── Startup ───────────────────────────────────────────────────────── */

// Disable Nagle's algorithm for lower latency on small packets
server.on("connection", (socket) => socket.setNoDelay(true));

// Keep client connections alive to avoid TCP handshake overhead
server.keepAliveTimeout = 60_000; // 60s idle before closing
server.headersTimeout = 65_000;   // must be > keepAliveTimeout

server.listen(PROXY_PORT, "127.0.0.1", () => {
  log.info(`Listening on http://127.0.0.1:${PROXY_PORT} -> ${UPSTREAM_URL}`);
  log.info(`Log level: ${LOG_LEVEL} (set PROXY_LOG_LEVEL=debug for verbose output)`);
  log.info(`Upstream timeout: ${PROXY_TIMEOUT / 1000}s (set PROXY_TIMEOUT=<seconds> to change)`);
  log.info(`Keep-alive: upstream pool maxSockets=16 maxFreeSockets=8`);
});

/* ── Periodic stats (every 5 min while active) ─────────────────────── */

setInterval(() => {
  if (totalRequests > 0) {
    const poolStats = agent.freeSockets
      ? Object.values(agent.freeSockets).reduce((n, a) => n + a.length, 0)
      : 0;
    log.info(
      `Stats: total_requests=${totalRequests} active=${activeRequests} stripped=${totalStripped} errors=${totalErrors} pool_idle=${poolStats}`
    );
  }
}, 5 * 60 * 1000).unref();
