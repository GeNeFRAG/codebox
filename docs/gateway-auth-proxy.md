# Gateway Auth Proxy

## Overview

The gateway-auth proxy manages rotating bearer tokens for LLM Gateway authentication. It sits between all three CodeBox agents (OpenCode, Claude Code, Pi) and the upstream LLM gateway, transparently handling token acquisition, caching, and refresh.

Unlike the prefill proxy (which is OpenCode-only and modifies request bodies), the gateway-auth proxy:
- **Shared by all agents** — OpenCode, Claude Code, and Pi all benefit
- **Only manages authentication** — replaces `Authorization` headers, doesn't modify bodies
- **Separate concern** — can coexist with the prefill proxy

## Architecture

```
┌──────────┐      ┌─────────┐      ┌──────────────┐      ┌──────────┐
│ OpenCode │─────>│ Prefill │─────>│ Gateway-Auth │─────>│ Upstream │
└──────────┘      │  Proxy  │      │    Proxy     │      │ Gateway  │
                  │ :18080  │      │   :18081     │      └──────────┘
                  └─────────┘      └──────────────┘
                       │                   ^
                       └───────────────────┘
                     (when both enabled)

┌────────────┐                    ┌──────────────┐      ┌──────────┐
│ Claude Code│───────────────────>│ Gateway-Auth │─────>│ Upstream │
└────────────┘                    │    Proxy     │      │ Gateway  │
                                  │   :18081     │      └──────────┘
                                  └──────────────┘

┌────┐                            ┌──────────────┐      ┌──────────┐
│ Pi │───────────────────────────>│ Gateway-Auth │─────>│ Upstream │
└────┘                            │    Proxy     │      │ Gateway  │
                                  │   :18081     │      └──────────┘
                                  └──────────────┘
```

**When both proxies are enabled:**
- OpenCode → prefill proxy (18080) → gateway-auth proxy (18081) → LLM Gateway
- Prefill strips assistant messages, gateway-auth manages tokens

**Gateway-auth only:**
- All agents → gateway-auth proxy (18081) → LLM Gateway

**Neither enabled:**
- All agents → LLM Gateway (direct)

## How It Works

### Token Management

1. **Helper Invocation**: On first request (or when cache expires), proxy spawns `rbi-sl-token` helper
2. **JWT Parsing**: Extracts `exp` field from JWT to set accurate cache TTL
3. **Caching**: Stores token in memory (not on disk) until expiry
4. **Refresh on Auth Failure**: Detects 401/403 responses, refreshes token, retries request once
5. **Fallback**: If helper unavailable, falls back to static `LLM_API_KEY`

### Request Flow

For every incoming request:

1. Check if cached token is still valid (exp > now + 60s safety margin)
2. If cache miss or expired:
   - Invoke helper to get fresh token
   - Parse JWT expiry, update cache
3. Replace incoming `Authorization` header with cached/fresh token
4. Forward request to upstream gateway
5. If response is 401/403 and not yet retried:
   - Force token refresh
   - Retry request with new token

## Configuration

Add to `.env`:

```bash
# Enable gateway-auth proxy (default: false)
CODEBOX_GATEWAY_AUTH_PROXY=true

# Token helper command (default: rbi-sl-token)
# Must be on PATH or an absolute path
CODEBOX_GATEWAY_AUTH_HELPER=rbi-sl-token

# Token cache TTL in seconds (default: 3300 = 55 min)
# Overridden by JWT exp field if present
CODEBOX_GATEWAY_AUTH_CACHE_TTL=3300

# Proxy port (default: 18081)
CODEBOX_GATEWAY_AUTH_PORT=18081

# Request timeout (default: 120 seconds)
CODEBOX_GATEWAY_AUTH_TIMEOUT=120

# Log level: debug | info | warn | error (default: info)
CODEBOX_GATEWAY_AUTH_LOG_LEVEL=info
```

Then restart:
```bash
./codebox.sh restart codebox
```

## Helper Requirements

The token helper must:
- Be executable and on `PATH` (or use absolute path in `CODEBOX_GATEWAY_AUTH_HELPER`)
- Exit 0 on success, non-zero on failure
- Return token on stdout (see Output Formats below)
- Complete within 10 seconds

### Output Formats

The helper can return either:

**1. Plain token (backward compatible):**
```bash
$ rbi-sl-token
eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiZXhwIjoxNzM2MjY3NDAwfQ.signature
$ echo $?
0
```

**2. JSON with token and optional headers:**
```bash
$ rbi-sl-token
{"token":"eyJhbGci...","headers":{"X-Request-ID":"abc123","X-Correlation-ID":"xyz789"}}
$ echo $?
0
```

When JSON output is used:
- The `token` field is required and must contain the JWT bearer token
- The `headers` field is optional and can contain additional HTTP headers to forward
- Only **safe headers** are preserved (see Security section below)
- The `Authorization` header is always overridden with the token from the `token` field

The proxy parses the JWT to extract `exp` (expiry timestamp). If parsing fails, it uses `CODEBOX_GATEWAY_AUTH_CACHE_TTL` as the TTL.

## Fallback Behavior

Helper availability is checked **once** on the first request:
1. If the helper succeeds, it's marked available and used for all subsequent requests
2. If the helper fails (not found, exits non-zero, times out):
   - Proxy logs warning: `Helper unavailable: <error>`
   - Helper is marked unavailable for the lifetime of the proxy
   - Falls back to static `LLM_API_KEY` for all subsequent requests
   - If no static key either, requests fail with **502 Bad Gateway** (permanent configuration issue, not a transient failure)

**Important**: Helper availability state is cached permanently. If the helper becomes available after proxy startup, it won't be used until the proxy is restarted.

This means:
- You can enable the proxy even if the helper isn't installed yet (uses static key)
- Gateway-auth proxy degrades gracefully to current behavior
- Agents never block waiting for a broken helper
- Helper installation/fixes require a container restart to take effect

## Integration with Model Discovery

When `CODEBOX_GATEWAY_AUTH_PROXY=true`, CodeBox starts the proxy **before** agent config generation. Model discovery (`_discover_gateway_models()` in `lib/config.sh`) then routes through the live local proxy rather than hitting `LLM_BASE_URL` with `LLM_API_KEY`. The proxy injects the helper token, so discovery works for gateways that reject the static key. If the proxy is disabled or not live, discovery retains its direct static-key path.

## macOS RBI Bridge

On macOS with Docker Desktop, CodeBox can automatically set up a bridge to the host-installed `rbi-sl-token` helper. See `docs/rbi-bridge-macos.md` for details.

## Coexistence with Prefill Proxy

Both proxies can run simultaneously (OpenCode only):

**Config:**
```bash
CODEBOX_GATEWAY_AUTH_PROXY=true
OPENCODE_PREFILL_PROXY=true
```

**Request flow:**
```
OpenCode → prefill (18080) → gateway-auth (18081) → LLM Gateway
           └─ strips assistant   └─ injects token
              messages
```

The prefill proxy automatically detects when `LLM_GATEWAY_AUTH_URL` is set and forwards to gateway-auth instead of `LLM_BASE_URL`.

## Monitoring

### Startup Logs

**Success:**
```
→ Starting gateway-auth proxy on 127.0.0.1:18081 → https://gateway.example.com...
  ✓ Token helper found: rbi-sl-token
  ✓ Gateway-auth proxy running (PID 1234)
```

**Helper unavailable:**
```
→ Starting gateway-auth proxy on 127.0.0.1:18081 → https://gateway.example.com...
  ✗ Token helper not found: rbi-sl-token
  ⚠ Will fall back to static LLM_API_KEY
  ✓ Gateway-auth proxy running (PID 1234)
```

**Startup failure:**
```
→ Starting gateway-auth proxy on 127.0.0.1:18081 → https://gateway.example.com...
  ✓ Token helper found: rbi-sl-token
  ✗ Gateway-auth proxy failed to start
```

### Runtime Logs

The proxy logs to stdout/stderr (visible via `docker logs` or `./codebox.sh logs`):

**Request:**
```
2025-01-15T10:30:45.123Z  INFO [gateway-auth-proxy] [abc123] --> POST /v1/chat/completions (active=1)
2025-01-15T10:30:45.234Z  INFO [gateway-auth-proxy] [abc123] <-- 200 OK (0.11s ttfb)
2025-01-15T10:30:50.456Z  INFO [gateway-auth-proxy] [abc123] Completed in 5.33s (active=0)
```

**Token refresh:**
```
2025-01-15T10:35:00.000Z  INFO [gateway-auth-proxy] Refreshing token from helper
2025-01-15T10:35:00.123Z  INFO [gateway-auth-proxy] Token refreshed (expires 2025-01-15T11:35:00.000Z)
```

**Auth retry:**
```
2025-01-15T10:40:00.000Z  WARN [gateway-auth-proxy] [def456] <-- 401 Unauthorized (0.05s ttfb)
2025-01-15T10:40:00.001Z  WARN [gateway-auth-proxy] [def456] Auth failure (401), refreshing token and retrying
2025-01-15T10:40:00.124Z  INFO [gateway-auth-proxy] [def456] Retrying with refreshed token
2025-01-15T10:40:00.234Z  INFO [gateway-auth-proxy] [def456] <-- 200 (retry, 0.23s total)
```

**Periodic stats (every 5 minutes):**
```
2025-01-15T10:45:00.000Z  INFO [gateway-auth-proxy] Stats: total=142 active=0 token_refreshes=3 auth_retries=1 helper_errors=0 token_source=helper pool_idle=4
```

### Debug Logging

For verbose output:
```bash
CODEBOX_GATEWAY_AUTH_LOG_LEVEL=debug
```

Shows:
- Request/response headers
- JWT parsing details
- Cache hit/miss events
- Connection pooling activity

## Troubleshooting

### Proxy not starting

**Symptom:**
```
✗ Gateway-auth proxy failed to start
```

**Check:**
1. Is port 18081 already in use? Change `CODEBOX_GATEWAY_AUTH_PORT`
2. Is `LLM_BASE_URL` set? Proxy requires it
3. Check container logs: `./codebox.sh logs codebox | grep gateway-auth`

### Helper not found

**Symptom:**
```
✗ Token helper not found: rbi-sl-token
⚠ Will fall back to static LLM_API_KEY
```

**Check:**
1. Is helper installed? `docker exec codebox which rbi-sl-token`
2. Is it on `PATH`? Or use absolute path: `CODEBOX_GATEWAY_AUTH_HELPER=/usr/local/bin/rbi-sl-token`
3. Is it executable? `docker exec codebox test -x "$(which rbi-sl-token)" && echo yes`

If helper is intentionally absent, set `LLM_API_KEY` and proxy will use it.

### Auth failures not retrying

**Symptom:**
Requests fail with 401/403, no retry logged

**Check:**
1. Is response actually 401/403? Other 4xx don't trigger retry
2. Was request already retried? Only retries once per request
3. Did token refresh fail? Check logs for "Token refresh failed"

### Tokens expiring too soon

**Symptom:**
Frequent token refreshes, auth retries

**Possible causes:**
1. JWT `exp` not being parsed correctly (check debug logs)
2. `CODEBOX_GATEWAY_AUTH_CACHE_TTL` too short (default: 3300s = 55 min)
3. Helper returning short-lived tokens

**Adjust TTL:**
```bash
CODEBOX_GATEWAY_AUTH_CACHE_TTL=5400  # 90 minutes
```

### Discovery not using proxy

**Symptom:**
Model discovery fails or uses old credentials

**Check:**
1. Is `CODEBOX_GATEWAY_AUTH_PROXY=true`?
2. Did proxy start successfully? Check `LLM_GATEWAY_AUTH_URL` is set
3. Clear discovery cache: `rm -f /tmp/codebox-gateway-models-*.json`

## Testing

Helper can be tested independently:
```bash
# Inside container
docker exec -it codebox bash
rbi-sl-token
# Should print JWT token, exit 0
```

Proxy logs show token source:
```
token_source=helper      # Using rbi-sl-token
token_source=static-key  # Using LLM_API_KEY fallback
token_source=unchecked   # No requests yet
```

## Security

### Token Handling

- Tokens are cached **in memory only** (not written to disk)
- Helper output (stdout) is captured and discarded after parsing
- Proxy replaces incoming `Authorization` headers (agents can't leak tokens)
- Static fallback (`LLM_API_KEY`) only used when helper unavailable

### Header Filtering

When the helper returns JSON with a `headers` field, only **safe headers** are forwarded. The following headers are **always blocked**:

- `authorization` — always overridden with token from `token` field
- `host` — set to upstream host by proxy
- `content-length` — may change during proxying
- `content-type` — may change during proxying
- `transfer-encoding` — controlled by proxy
- `connection` — keep-alive managed by proxy
- `proxy-*` — internal proxy headers
- `te`, `trailer`, `upgrade` — hop-by-hop headers

Safe headers like `X-Request-ID`, `X-Correlation-ID`, or custom gateway-specific headers are preserved and forwarded to the upstream.

## Performance

- **Connection pooling**: HTTP/HTTPS keep-alive, reuses sockets (maxSockets=16, maxFreeSockets=8)
- **Zero-copy proxying**: Request/response bodies streamed through (except on auth retry)
- **Cache hit**: < 1ms overhead vs direct connection
- **Cache miss**: + helper invocation time (~100-500ms for token acquisition)
- **Auth retry**: Doubles request time (upstream called twice)

Overhead is negligible compared to LLM inference time (typically seconds).
