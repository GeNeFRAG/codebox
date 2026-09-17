# proxy/

Contains two HTTP proxies:

1. **gateway-auth-proxy.mjs** — Rotating token management for all three agents (OpenCode, Claude Code, Pi)
2. **prefill-proxy.mjs** — Assistant message stripping for OpenCode only

Both can run simultaneously for OpenCode (chain: OpenCode → prefill → gateway-auth → upstream).

---

## Gateway Auth Proxy

Manages rotating bearer tokens from `rbi-sl-token` helper (or similar) for LLM Gateway authentication.

### What it does

- **Token acquisition**: Invokes helper command to get fresh JWT tokens
- **Caching**: Stores tokens in memory with TTL derived from JWT `exp` field
- **Auth retry**: Detects 401/403 responses, refreshes token, retries request once
- **Fallback**: Uses static `LLM_API_KEY` if helper unavailable
- **Universal**: Works for all three agents (OpenCode, Claude Code, Pi)

### Configuration

Add to `.env`:
```bash
CODEBOX_GATEWAY_AUTH_PROXY=true
CODEBOX_GATEWAY_AUTH_HELPER=rbi-sl-token  # default
CODEBOX_GATEWAY_AUTH_CACHE_TTL=3300       # 55 min, default
CODEBOX_GATEWAY_AUTH_PORT=18081           # default
```

See full documentation: [docs/gateway-auth-proxy.md](../docs/gateway-auth-proxy.md)

### Architecture

- Listens on `http://127.0.0.1:18081` inside the container
- Replaces `Authorization` header with token from helper or static key
- Does NOT modify request/response bodies
- Connection pooling (keep-alive, maxSockets=16)
- Request timeout: 120s (configurable via `CODEBOX_GATEWAY_AUTH_TIMEOUT`)

---

## Prefill Proxy

## What it does

Sits between OpenCode and the upstream LLM gateway (`LLM_BASE_URL`). Its sole job is to strip `assistant`-role prefill messages from request bodies before forwarding them upstream. Some LLM gateways reject requests that contain an assistant turn as the last message; this proxy makes OpenCode's prefill feature transparent to those gateways.

- Listens on `http://127.0.0.1:18080` inside the container.
- OpenCode's config (`opencode.json`) points at this address instead of `LLM_BASE_URL` when the proxy is active.
- **Disabled by default** (`OPENCODE_PREFILL_PROXY=false`). Set `OPENCODE_PREFILL_PROXY=true` to enable.
- Disabled automatically if the LLM gateway health check fails at startup (falls back to direct connection).
- Not used by Claude Code.

## Why it defaults to off

The gateway bug it worked around is fixed. Verified 2026-08 against `genai-sbox.rbi.tech`: a trailing
`assistant` message is accepted with HTTP 200 on `claude-opus-5`, `claude-opus-4-8`, `claude-opus-4-6`,
`claude-sonnet-5`, and `claude-haiku-4-5` — including streaming, tool calls, and multiple consecutive
trailing assistant messages. Across 319 real chat completions in production the strip path fired
**zero** times (`stripped=0`).

Leaving it on is not free: `OPENCODE_PROXY_TIMEOUT` (default 120s) is enforced by the proxy itself, and
legitimate responses do exceed it — the slowest observed *successful* completion was 172s. Those
requests were destroyed mid-stream and surfaced to OpenCode as `socket hang up`.

Re-enable only if you point CodeBox at a gateway that still rejects prefill. Note the strip is lossy:
the trailing assistant content is deleted, not merged, so the model answers a different prompt than
was sent.

## Enabling

## Lifecycle

Started by `lib/proxy.sh:_start_proxy` (phase 10 of the boot flow). Killed on SIGTERM/SIGINT via the `_cleanup` trap registered in `entrypoint.sh`.

## Disabling

Set `OPENCODE_PREFILL_PROXY=true` in `.env`, then `./codebox.sh restart <svc>`. With it off, OpenCode connects directly to `LLM_BASE_URL`.
