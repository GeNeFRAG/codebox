#!/usr/bin/env node
/**
 * MCP websearch server using Bing (replaces mcp-duckduckgo which gets CAPTCHA-blocked).
 * Implements: search, search_and_crawl, research tools with same interface.
 */

const https = require("https");
const readline = require("readline");

const UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

function httpsGet(url, headers = {}) {
  return new Promise((resolve, reject) => {
    const opts = new URL(url);
    const req = https.get(
      {
        hostname: opts.hostname,
        path: opts.pathname + opts.search,
        headers: { "User-Agent": UA, "Accept-Language": "en-US,en;q=0.9", ...headers },
        timeout: 20000,
      },
      (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          return httpsGet(res.headers.location, headers).then(resolve).catch(reject);
        }
        let data = "";
        res.on("data", (c) => (data += c));
        res.on("end", () => resolve(data));
      }
    );
    req.on("error", reject);
    req.on("timeout", () => { req.destroy(); reject(new Error("timeout")); });
  });
}

function stripHtml(s) {
  return s.replace(/<[^>]+>/g, "").replace(/&amp;/g, "&").replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ").trim();
}

async function bingSearch(query, limit = 10) {
  const url = `https://www.bing.com/search?q=${encodeURIComponent(query)}&mkt=en-US&setlang=en-US&count=${limit}`;
  const html = await httpsGet(url);

  const results = [];
  // Match each organic result block
  const blockRe = /<li[^>]*class="[^"]*b_algo[^"]*"[^>]*>([\s\S]*?)<\/li>/g;
  let block;
  while ((block = blockRe.exec(html)) !== null && results.length < limit) {
    const content = block[1];
    // Title + URL
    const titleMatch = content.match(/<h2[^>]*><a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/);
    // Snippet
    const snippetMatch = content.match(/class="b_caption">[\s\S]*?<p[^>]*>([\s\S]*?)<\/p>/);
    // Cite (real URL)
    const citeMatch = content.match(/<cite[^>]*>([\s\S]*?)<\/cite>/);

    if (titleMatch) {
      const href = titleMatch[1];
      const title = stripHtml(titleMatch[2]);
      const snippet = snippetMatch ? stripHtml(snippetMatch[1]) : "";
      const displayUrl = citeMatch ? stripHtml(citeMatch[1]) : href;
      // Resolve Bing redirect to real URL
      const realUrl = href.startsWith("https://www.bing.com/ck/") ? displayUrl : href;
      if (title) results.push({ title, url: realUrl, snippet });
    }
  }
  return results;
}

async function fetchPage(url, maxLen = 3000) {
  try {
    const html = await httpsGet(url);
    const text = html
      .replace(/<script[\s\S]*?<\/script>/gi, "")
      .replace(/<style[\s\S]*?<\/style>/gi, "")
      .replace(/<[^>]+>/g, " ")
      .replace(/\s{2,}/g, " ")
      .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
      .replace(/&nbsp;/g, " ").replace(/&quot;/g, '"').trim();
    return text.slice(0, maxLen);
  } catch (e) {
    return `[fetch failed: ${e.message}]`;
  }
}

async function doSearch(args) {
  const results = await bingSearch(args.query || args.q, args.limit || 10);
  if (!results.length) return "## Found 0 results\n\n";
  const lines = [`## Found ${results.length} results\n`];
  for (const r of results) {
    lines.push(`### ${r.title}`);
    lines.push(`**URL:** ${r.url}`);
    if (r.snippet) lines.push(r.snippet);
    lines.push("");
  }
  return lines.join("\n");
}

async function doSearchAndCrawl(args) {
  const count = args.count || 5;
  const maxLen = args.maxContentLength || 3000;
  const results = await bingSearch(args.query || args.q, count);
  if (!results.length) return "## Found 0 results\n\n";
  const lines = [`## Search & Crawl: ${args.query}\n`];
  await Promise.all(
    results.map(async (r) => {
      const content = await fetchPage(r.url, maxLen);
      lines.push(`### ${r.title}`);
      lines.push(`**URL:** ${r.url}`);
      if (r.snippet) lines.push(`**Snippet:** ${r.snippet}`);
      lines.push("\n**Content:**\n" + content);
      lines.push("");
    })
  );
  return lines.join("\n");
}

async function doResearch(args) {
  const count = args.count || 5;
  const maxLen = args.maxContentLength || 3000;
  const question = args.question || args.query || args.q;
  const results = await bingSearch(question, count);
  if (!results.length) return `# Research Results for: ${question}\n\nAnalyzed 0 sources.\n`;

  const lines = [`# Research Results for: ${question}\n`, `Analyzed ${results.length} sources:\n`];
  const fetched = await Promise.all(
    results.map(async (r, i) => {
      const content = await fetchPage(r.url, maxLen);
      return { ...r, content, index: i + 1 };
    })
  );
  for (const r of fetched) {
    lines.push(`## Source ${r.index}: ${r.title}`);
    lines.push(`**URL:** ${r.url}`);
    if (r.snippet) lines.push(`**Snippet:** ${r.snippet}`);
    lines.push("\n**Content:**\n" + r.content);
    lines.push("");
  }
  return lines.join("\n");
}

const TOOLS = [
  {
    name: "search",
    description: "Search the web using Bing. Returns titles, URLs, and snippets.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Search query" },
        limit: { type: "number", description: "Max results (default 10, max 20)" },
      },
      required: ["query"],
    },
  },
  {
    name: "search_and_crawl",
    description: "Search the web and crawl full content from each result page.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Search query" },
        count: { type: "number", description: "Number of results to crawl (default 5, max 10)" },
        maxContentLength: { type: "number", description: "Max chars per page (default 3000)" },
      },
      required: ["query"],
    },
  },
  {
    name: "research",
    description: "Research a question by searching and analyzing sources.",
    inputSchema: {
      type: "object",
      properties: {
        question: { type: "string", description: "Research question" },
        count: { type: "number", description: "Number of sources (default 5, max 10)" },
        maxContentLength: { type: "number", description: "Max chars per page (default 3000)" },
      },
      required: ["question"],
    },
  },
];

async function handleRequest(msg) {
  const { method, id, params } = msg;
  const ok = (result) => ({ jsonrpc: "2.0", id, result });
  const err = (code, message) => ({ jsonrpc: "2.0", id, error: { code, message } });

  try {
    if (method === "initialize") {
      return ok({
        protocolVersion: params?.protocolVersion || "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "websearch", version: "1.0.0" },
      });
    }
    if (method === "notifications/initialized" || method === "ping") return null;
    if (method === "tools/list") return ok({ tools: TOOLS });
    if (method === "tools/call") {
      const { name, arguments: args } = params;
      let text;
      if (name === "search") text = await doSearch(args);
      else if (name === "search_and_crawl") text = await doSearchAndCrawl(args);
      else if (name === "research") text = await doResearch(args);
      else return err(-32601, `Unknown tool: ${name}`);
      return ok({ content: [{ type: "text", text }] });
    }
    return err(-32601, `Unknown method: ${method}`);
  } catch (e) {
    return ok({ content: [{ type: "text", text: `Search failed: ${e.message}` }], isError: true });
  }
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", async (line) => {
  if (!line.trim()) return;
  try {
    const msg = JSON.parse(line);
    const response = await handleRequest(msg);
    if (response) process.stdout.write(JSON.stringify(response) + "\n");
  } catch (e) {
    process.stderr.write(`Parse error: ${e.message}\n`);
  }
});

process.stderr.write("websearch MCP server v1.0.0 (Bing backend) starting on stdio\n");
