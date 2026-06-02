#!/usr/bin/env node
/**
 * CodeBox host-exec MCP server
 * Runs on the host machine so the container's Claude Code can execute host commands (atl, gh, brew, etc.)
 *
 * Start:  ./codebox.sh host-exec start
 * Stop:   ./codebox.sh host-exec stop
 * Port:   HOST_EXEC_PORT (default 7744)
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { randomUUID } from "crypto";
import { exec } from "child_process";
import { promisify } from "util";
import http from "http";

const execAsync = promisify(exec);
const PORT = parseInt(process.env.HOST_EXEC_PORT ?? "7744", 10);

const transports = new Map();

function makeServer() {
  const server = new McpServer({ name: "host-exec", version: "1.0.0" });
  server.tool(
    "run_command",
    "Run a shell command on the host machine (has full host PATH including /opt/homebrew/bin)",
    {
      command: { type: "string", description: "Shell command to execute on the host" },
      timeout_ms: { type: "number", description: "Timeout ms (default 30000)" },
    },
    async ({ command, timeout_ms = 30000 }) => {
      try {
        const { stdout, stderr } = await execAsync(command, {
          shell: process.env.SHELL ?? "/bin/bash",
          timeout: timeout_ms,
          maxBuffer: 10 * 1024 * 1024,
          env: { ...process.env },
        });
        const text = [stdout, stderr].filter(Boolean).join("\n").trim() || "(no output)";
        return { content: [{ type: "text", text }] };
      } catch (err) {
        const text = [err.stdout, err.stderr, err.message].filter(Boolean).join("\n").trim();
        return { content: [{ type: "text", text }], isError: true };
      }
    },
  );
  return server;
}

const httpServer = http.createServer(async (req, res) => {
  if (!req.url.startsWith("/mcp")) {
    res.writeHead(404).end("Not found");
    return;
  }

  let body;
  if (req.method === "POST") {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    try { body = JSON.parse(Buffer.concat(chunks).toString()); } catch { /* ignore */ }
  }

  const sessionId = req.headers["mcp-session-id"];

  if (req.method === "POST" && !sessionId) {
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: randomUUID,
      onsessioninitialized: (sid) => transports.set(sid, transport),
    });
    await makeServer().connect(transport);
    await transport.handleRequest(req, res, body);
    return;
  }

  const transport = transports.get(sessionId);
  if (!transport) { res.writeHead(404).end("Session not found"); return; }
  await transport.handleRequest(req, res, body);
  if (req.method === "DELETE") transports.delete(sessionId);
});

httpServer.listen(PORT, "0.0.0.0", () => {
  console.log(`host-exec MCP server listening on http://0.0.0.0:${PORT}/mcp`);
  console.log(`Container connects via http://host.docker.internal:${PORT}/mcp`);
});
