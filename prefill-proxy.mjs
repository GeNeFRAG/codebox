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

const UPSTREAM_URL = process.env.UPSTREAM_URL;
const PROXY_PORT = parseInt(process.env.PROXY_PORT || "18080", 10);

if (!UPSTREAM_URL) {
  console.error("[prefill-proxy] UPSTREAM_URL is required");
  process.exit(1);
}

const upstream = new URL(UPSTREAM_URL);

function stripTrailingAssistantMessages(body) {
  if (!body || !body.messages || !Array.isArray(body.messages)) return body;

  const messages = body.messages;
  // Remove trailing assistant messages (prefill)
  while (
    messages.length > 0 &&
    messages[messages.length - 1].role === "assistant"
  ) {
    const removed = messages.pop();
    console.log(
      `[prefill-proxy] Stripped trailing assistant message: "${(removed.content || "").slice(0, 80)}..."`
    );
  }

  return body;
}

const server = http.createServer(async (req, res) => {
  // Collect request body
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  let rawBody = Buffer.concat(chunks);

  const isChatCompletion =
    req.url?.includes("/chat/completions") && req.method === "POST";

  if (isChatCompletion) {
    try {
      const body = JSON.parse(rawBody.toString());
      const fixed = stripTrailingAssistantMessages(body);
      rawBody = Buffer.from(JSON.stringify(fixed));
    } catch (e) {
      console.error("[prefill-proxy] Failed to parse request body:", e.message);
    }
  }

  // Build upstream URL: upstream base + request path
  const targetUrl = new URL(req.url, UPSTREAM_URL);

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
    },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
    }
  );

  proxyReq.on("error", (err) => {
    console.error("[prefill-proxy] Upstream error:", err.message);
    if (!res.headersSent) {
      res.writeHead(502, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: { message: `Proxy error: ${err.message}` } }));
    }
  });

  proxyReq.write(rawBody);
  proxyReq.end();
});

server.listen(PROXY_PORT, "127.0.0.1", () => {
  console.log(
    `[prefill-proxy] Listening on http://127.0.0.1:${PROXY_PORT} -> ${UPSTREAM_URL}`
  );
});
