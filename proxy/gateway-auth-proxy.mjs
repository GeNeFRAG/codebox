#!/usr/bin/env node
/**
 * Gateway Auth Proxy — Manages rotating bearer tokens from rbi-sl-token helper
 * for LLM Gateway authentication.
 *
 * Transparently refreshes tokens on expiry, retries on auth failure, and falls
 * back to static LLM_API_KEY when the helper is unavailable. Used by all three
 * CodeBox agents (OpenCode, Claude Code, Pi).
 *
 * Usage:
 *   UPSTREAM_URL=https://gateway.example.com \
 *   HELPER_CMD=rbi-sl-token \
 *   node gateway-auth-proxy.mjs
 *
 * Listens on: http://localhost:${GATEWAY_AUTH_PORT:-18081}
 */

import http from "node:http";
import https from "node:https";
import crypto from "node:crypto";
import { spawn } from "node:child_process";

/* ── Configuration ─────────────────────────────────────────────────── */

const UPSTREAM_URL = process.env.UPSTREAM_URL;
const GATEWAY_AUTH_PORT = parseInt(process.env.CODEBOX_GATEWAY_AUTH_PORT || "18081", 10);
const GATEWAY_AUTH_TIMEOUT = parseInt(process.env.CODEBOX_GATEWAY_AUTH_TIMEOUT || "120", 10) * 1000;
const LOG_LEVEL = (process.env.CODEBOX_GATEWAY_AUTH_LOG_LEVEL || "info").toLowerCase();
const HELPER_CMD = process.env.CODEBOX_GATEWAY_AUTH_HELPER || "rbi-sl-token";
const CACHE_TTL = parseInt(process.env.CODEBOX_GATEWAY_AUTH_CACHE_TTL || "3300", 10);
const STATIC_KEY = process.env.LLM_API_KEY || "";

if (!UPSTREAM_URL) {
  console.error("[gateway-auth-proxy] UPSTREAM_URL is required");
  process.exit(1);
}

const upstream = new URL(UPSTREAM_URL);

/* ── Connection pooling ────────────────────────────────────────────── */

const httpAgent = new http.Agent({
  keepAlive: true,
  keepAliveMsecs: 30_000,
  maxSockets: 16,
  maxFreeSockets: 8,
  scheduling: "fifo",
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

function reqId() {
  return crypto.randomBytes(3).toString("hex");
}

const log = {
  debug: (...args) =>
    activeLevel <= LEVELS.debug && console.log(`${ts()} DEBUG [gateway-auth-proxy]`, ...args),
  info: (...args) =>
    activeLevel <= LEVELS.info && console.log(`${ts()}  INFO [gateway-auth-proxy]`, ...args),
  warn: (...args) =>
    activeLevel <= LEVELS.warn && console.warn(`${ts()}  WARN [gateway-auth-proxy]`, ...args),
  error: (...args) =>
    activeLevel <= LEVELS.error && console.error(`${ts()} ERROR [gateway-auth-proxy]`, ...args),
};

/* ── Token management ──────────────────────────────────────────────── */

let cachedToken = null;
let cachedHeaders = {};
let tokenExpiry = 0;
let helperAvailable = null; // null = unchecked, true = available, false = unavailable
let totalTokenRefreshes = 0;
let totalHelperErrors = 0;

/**
 * Parse JWT to extract expiry timestamp.
 * Returns expiry (seconds since epoch) or null if parsing fails.
 */
function parseJwtExpiry(token) {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return null;

    const payload = JSON.parse(Buffer.from(parts[1], "base64").toString("utf8"));
    return payload.exp || null;
  } catch (e) {
    log.debug(`Failed to parse JWT: ${e.message}`);
    return null;
  }
}

/**
 * Invoke the token helper and return the bearer token with optional headers.
 * Helper can return:
 *   - Plain token: "eyJhbGci..."
 *   - JSON: {"token": "eyJhbGci...", "headers": {"X-Custom": "value"}}
 * Returns { token: string, expiry: number, headers: object } or { error: string }.
 */
async function invokeHelper() {
  return new Promise((resolve) => {
    const proc = spawn(HELPER_CMD, [], {
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 10000, // 10s timeout for helper
    });

    let stdout = "";
    let stderr = "";

    proc.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });

    proc.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    proc.on("error", (err) => {
      resolve({ error: `Failed to spawn ${HELPER_CMD}: ${err.message}` });
    });

    proc.on("close", (code) => {
      if (code !== 0) {
        resolve({ error: `${HELPER_CMD} exited with code ${code}: ${stderr.trim()}` });
        return;
      }

      const output = stdout.trim();
      if (!output) {
        resolve({ error: `${HELPER_CMD} returned empty output` });
        return;
      }

      // Try parsing as JSON first (supports {"token": "...", "headers": {...}})
      let token, headers = {};
      try {
        const parsed = JSON.parse(output);
        if (!parsed.token) {
          resolve({ error: `JSON output missing "token" field` });
          return;
        }
        // Strip any "Bearer " prefix to avoid double-wrapping
        token = parsed.token.replace(/^Bearer\s+/i, "");

        // Filter safe headers (exclude sensitive/proxy-controlled headers)
        if (parsed.headers && typeof parsed.headers === "object") {
          const unsafeHeaders = [
            "authorization",
            "host",
            "content-length",
            "content-type",
            "transfer-encoding",
            "connection",
            "proxy-authorization",
            "proxy-authenticate",
            "te",
            "trailer",
            "upgrade",
            "cookie",
            "set-cookie",
            "cookie2",
            "set-cookie2",
          ];

          for (const [key, value] of Object.entries(parsed.headers)) {
            const lowerKey = key.toLowerCase();
            if (!unsafeHeaders.includes(lowerKey) && typeof value === "string") {
              headers[lowerKey] = value;
              log.debug(`Preserving helper header: ${key}`);
            } else if (unsafeHeaders.includes(lowerKey)) {
              log.debug(`Filtering unsafe header: ${key}`);
            }
          }
        }
      } catch (e) {
        // Not JSON, treat as plain token (backward compatible)
        // Strip any "Bearer " prefix the helper may have included to avoid double-wrapping
        token = output.replace(/^Bearer\s+/i, "");
        log.debug("Helper returned plain token (not JSON)");
      }

      // Extract expiry from JWT, or use configured TTL
      const exp = parseJwtExpiry(token);
      const expiry = exp || Math.floor(Date.now() / 1000) + CACHE_TTL;

      log.debug(`Token acquired, expires at ${new Date(expiry * 1000).toISOString()}`);
      resolve({ token, expiry, headers });
    });
  });
}

/**
 * Get a valid bearer token and headers (from cache or by invoking helper).
 * Falls back to static key if helper unavailable.
 * Returns { token: "Bearer <token>", headers: {...} } or { token: null, headers: {} }.
 */
async function getToken(forceRefresh = false) {
  const now = Math.floor(Date.now() / 1000);

  // Check cache first (unless forcing refresh)
  if (!forceRefresh && cachedToken && tokenExpiry > now + 60) {
    // 60s safety margin
    log.debug(`Using cached token (expires in ${tokenExpiry - now}s)`);
    return { token: `Bearer ${cachedToken}`, headers: cachedHeaders };
  }

  // Check helper availability on first call (cached permanently until container restart).
  // If the helper becomes available after container boot (e.g., manual install after startup),
  // it won't be detected until restart. This is by design to avoid repeated helper invocations
  // on every request when the helper is persistently unavailable.
  if (helperAvailable === null) {
    log.info(`Checking helper availability: ${HELPER_CMD}`);
    const result = await invokeHelper();

    if (result.error) {
      helperAvailable = false;
      totalHelperErrors++;
      log.warn(`Helper unavailable: ${result.error}`);
      log.warn("Helper availability is cached — restart container if helper becomes available");

      if (STATIC_KEY) {
        log.info("Falling back to static LLM_API_KEY");
        return { token: `Bearer ${STATIC_KEY}`, headers: {} };
      } else {
        log.error("No static key available — authentication will fail");
        return { token: null, headers: {} };
      }
    }

    helperAvailable = true;
    cachedToken = result.token;
    cachedHeaders = result.headers || {};
    tokenExpiry = result.expiry;
    totalTokenRefreshes++;
    log.info(`Helper available, token cached (expires ${new Date(tokenExpiry * 1000).toISOString()})`);
    return { token: `Bearer ${cachedToken}`, headers: cachedHeaders };
  }

  // Helper previously determined unavailable — use static key.
  // forceRefresh re-probes the helper to handle the case where it became
  // available after a transient failure (e.g., bridge was starting up).
  if (helperAvailable === false) {
    if (!forceRefresh) {
      if (STATIC_KEY) {
        return { token: `Bearer ${STATIC_KEY}`, headers: {} };
      } else {
        return { token: null, headers: {} };
      }
    }
    // forceRefresh=true: re-probe before giving up
    log.info("Re-probing helper after previous failure (forced refresh)");
    helperAvailable = null; // reset so the probe block below runs
  }

  // Refresh token from helper
  log.info("Refreshing token from helper");
  const result = await invokeHelper();

  if (result.error) {
    totalHelperErrors++;
    log.error(`Token refresh failed: ${result.error}`);

    // Helper failed — mark as unavailable and fall back
    helperAvailable = false;
    if (STATIC_KEY) {
      log.warn("Helper now unavailable, falling back to static key");
      return { token: `Bearer ${STATIC_KEY}`, headers: {} };
    } else {
      return { token: null, headers: {} };
    }
  }

  cachedToken = result.token;
  cachedHeaders = result.headers || {};
  tokenExpiry = result.expiry;
  totalTokenRefreshes++;
  log.info(`Token refreshed (expires ${new Date(tokenExpiry * 1000).toISOString()})`);
  return { token: `Bearer ${cachedToken}`, headers: cachedHeaders };
}

/* ── Request stats ─────────────────────────────────────────────────── */

let totalRequests = 0;
let activeRequests = 0;
let totalAuthRetries = 0;
let totalErrors = 0;

/* ── Request context ───────────────────────────────────────────────── */

function makeRequestCtx() {
  return { settled: false, retried: false };
}

function settle(ctx) {
  if (ctx.settled) return false;
  ctx.settled = true;
  activeRequests--;
  return true;
}

/* ── Upstream handlers ─────────────────────────────────────────────── */

function handleUpstreamResponse(proxyRes, res, id, startTime, ctx, reqOpts, rawBody, targetUrl) {
  const elapsed = ((performance.now() - startTime) / 1000).toFixed(2);
  const status = proxyRes.statusCode;
  const level = status >= 500 ? "error" : status >= 400 ? "warn" : "info";
  log[level](`[${id}] <-- ${status} ${http.STATUS_CODES[status]} (${elapsed}s ttfb)`);

  // Handle auth failure: refresh token and retry once
  if ((status === 401 || status === 403) && !ctx.retried) {
    ctx.retried = true;
    totalAuthRetries++;
    log.warn(`[${id}] Auth failure (${status}), refreshing token and retrying`);

    // Consume error response to free the socket
    proxyRes.resume();

    // Refresh token and retry
    getToken(true).then(({ token: newToken, headers: newHelperHeaders }) => {
      if (!newToken) {
        log.error(`[${id}] Token refresh failed, no authentication source available`);
        settle(ctx);
        if (!res.headersSent) {
          // 502 Bad Gateway = permanent configuration issue (no helper + no static key)
          // This is not a transient failure - requires restart to fix
          res.writeHead(502, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: { message: "Authentication unavailable" } }));
        }
        return;
      }

      log.info(`[${id}] Retrying with refreshed token`);
      // Clone reqOpts to avoid mutating the original, merge new helper headers
      const retryOpts = { ...reqOpts, headers: { ...reqOpts.headers, ...newHelperHeaders, authorization: newToken } };

      const retryReq = transport.request(targetUrl, retryOpts, (retryRes) => {
        const retryElapsed = ((performance.now() - startTime) / 1000).toFixed(2);
        log.info(`[${id}] <-- ${retryRes.statusCode} (retry, ${retryElapsed}s total)`);
        res.writeHead(retryRes.statusCode, retryRes.headers);
        retryRes.pipe(res);
        retryRes.on("end", () => settle(ctx));
        retryRes.on("error", () => settle(ctx));
      });

      retryReq.on("timeout", () => {
        log.error(`[${id}] Retry timeout`);
        settle(ctx);
        retryReq.destroy();
      });

      retryReq.on("error", (err) => {
        settle(ctx);
        totalErrors++;
        log.error(`[${id}] Retry error: ${err.message}`);
        if (!res.headersSent) {
          res.writeHead(502, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: { message: `Proxy error: ${err.message}` } }));
        }
      });

      retryReq.end(rawBody);
    });

    return;
  }

  // Not an auth failure or already retried — forward response
  res.writeHead(proxyRes.statusCode, proxyRes.headers);
  proxyRes.pipe(res);

  proxyRes.on("end", () => {
    settle(ctx);
    const total = ((performance.now() - startTime) / 1000).toFixed(2);
    log.info(`[${id}] Completed in ${total}s (active=${activeRequests})`);
  });

  proxyRes.on("error", () => settle(ctx));
}

function handleTimeout(proxyReq, res, id) {
  const timeoutSec = GATEWAY_AUTH_TIMEOUT / 1000;
  log.error(`[${id}] Upstream timeout after ${timeoutSec}s`);
  proxyReq.destroy(new Error(`Upstream timeout (${timeoutSec}s)`));
  if (res.headersSent && !res.writableEnded) {
    log.error(`[${id}] Destroying client connection (mid-stream timeout)`);
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
    log.error(`[${id}] Destroying client connection (mid-stream error)`);
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

const server = http.createServer(async (req, res) => {
  const id = reqId();
  const startTime = performance.now();
  totalRequests++;
  activeRequests++;

  log.info(`[${id}] --> ${req.method} ${req.url} (active=${activeRequests})`);
  log.debug(`[${id}] Request headers: ${JSON.stringify(req.headers)}`);

  // Get bearer token and helper headers (from cache, helper, or static key)
  const { token, headers: helperHeaders } = await getToken();
  if (!token) {
    log.error(`[${id}] No token available`);
    activeRequests--;
    res.writeHead(503, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { message: "Authentication unavailable" } }));
    return;
  }

  // Build target URL
  const targetUrl = new URL(req.url, UPSTREAM_URL);
  log.debug(`[${id}] Forwarding to ${targetUrl.toString()}`);

  // Forward headers, merging helper headers and replacing Authorization
  const fwdHeaders = { ...req.headers, ...helperHeaders, host: upstream.host, connection: "keep-alive" };
  fwdHeaders.authorization = token;

  // Request options
  const reqOpts = {
    method: req.method,
    headers: fwdHeaders,
    agent,
    rejectUnauthorized: true,
    timeout: GATEWAY_AUTH_TIMEOUT,
  };

  // Buffer request body (needed for retry on auth failure)
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("error", (err) => {
    log.error(`[${id}] Client request error: ${err.message}`);
    activeRequests--;
  });
  req.on("end", () => {
    const rawBody = Buffer.concat(chunks);
    log.debug(`[${id}] Body: ${(rawBody.length / 1024).toFixed(1)}KB`);

    const ctx = makeRequestCtx();
    const proxyReq = transport.request(targetUrl, reqOpts, (proxyRes) =>
      handleUpstreamResponse(proxyRes, res, id, startTime, ctx, reqOpts, rawBody, targetUrl)
    );

    proxyReq.on("timeout", () => handleTimeout(proxyReq, res, id));
    proxyReq.on("error", (err) => handleProxyError(err, res, id, startTime, ctx));
    res.on("close", () => handleClientDisconnect(proxyReq, id, ctx));

    proxyReq.end(rawBody);
  });
});

/* ── Startup ───────────────────────────────────────────────────────── */

server.on("connection", (socket) => socket.setNoDelay(true));
server.keepAliveTimeout = 60_000;
server.headersTimeout = 65_000;

server.listen(GATEWAY_AUTH_PORT, "127.0.0.1", () => {
  log.info(`Listening on http://127.0.0.1:${GATEWAY_AUTH_PORT} -> ${UPSTREAM_URL}`);
  log.info(`Token helper: ${HELPER_CMD}`);
  log.info(`Cache TTL: ${CACHE_TTL}s (overridden by JWT exp if present)`);
  log.info(`Static key fallback: ${STATIC_KEY ? "enabled" : "disabled"}`);
  log.info(`Log level: ${LOG_LEVEL}`);
  log.info(`Upstream timeout: ${GATEWAY_AUTH_TIMEOUT / 1000}s`);
});

/* ── Periodic stats ────────────────────────────────────────────────── */

setInterval(() => {
  if (totalRequests > 0) {
    const poolStats = agent.freeSockets
      ? Object.values(agent.freeSockets).reduce((n, a) => n + a.length, 0)
      : 0;
    const tokenStatus = helperAvailable
      ? "helper"
      : helperAvailable === false
      ? "static-key"
      : "unchecked";
    log.info(
      `Stats: total=${totalRequests} active=${activeRequests} token_refreshes=${totalTokenRefreshes} auth_retries=${totalAuthRetries} helper_errors=${totalHelperErrors} token_source=${tokenStatus} pool_idle=${poolStats}`
    );
  }
}, 5 * 60 * 1000).unref();
