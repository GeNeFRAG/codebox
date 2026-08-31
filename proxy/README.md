# proxy/

Contains `prefill-proxy.mjs` — a local HTTP proxy used by OpenCode only.

## What it does

Sits between OpenCode and the upstream LLM gateway (`LLM_BASE_URL`). Its sole job is to strip `assistant`-role prefill messages from request bodies before forwarding them upstream. Some LLM gateways reject requests that contain an assistant turn as the last message; this proxy makes OpenCode's prefill feature transparent to those gateways.

- Listens on `http://127.0.0.1:18080` inside the container.
- OpenCode's config (`opencode.json`) points at this address instead of `LLM_BASE_URL` when the proxy is active.
- **Disabled by default** (`PREFILL_PROXY=false`). Set `PREFILL_PROXY=true` to enable.
- Disabled automatically if the LLM gateway health check fails at startup (falls back to direct connection).
- Not used by Claude Code.

## Why it defaults to off

The gateway bug it worked around is fixed. Verified 2026-08 against `genai-sbox.rbi.tech`: a trailing
`assistant` message is accepted with HTTP 200 on `claude-opus-5`, `claude-opus-4-8`, `claude-opus-4-6`,
`claude-sonnet-5`, and `claude-haiku-4-5` — including streaming, tool calls, and multiple consecutive
trailing assistant messages. Across 319 real chat completions in production the strip path fired
**zero** times (`stripped=0`).

Leaving it on is not free: `PROXY_TIMEOUT` (default 120s) is enforced by the proxy itself, and
legitimate responses do exceed it — the slowest observed *successful* completion was 172s. Those
requests were destroyed mid-stream and surfaced to OpenCode as `socket hang up`.

Re-enable only if you point CodeBox at a gateway that still rejects prefill. Note the strip is lossy:
the trailing assistant content is deleted, not merged, so the model answers a different prompt than
was sent.

## Enabling

## Lifecycle

Started by `lib/proxy.sh:_start_proxy` (phase 10 of the boot flow). Killed on SIGTERM/SIGINT via the `_cleanup` trap registered in `entrypoint.sh`.

## Disabling

Set `PREFILL_PROXY=true` in `.env`, then `./codebox.sh restart <svc>`. With it off, OpenCode connects directly to `LLM_BASE_URL`.
