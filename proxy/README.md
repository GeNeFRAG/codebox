# proxy/

Contains `prefill-proxy.mjs` — a local HTTP proxy used by OpenCode only.

## What it does

Sits between OpenCode and the upstream LLM gateway (`LLM_BASE_URL`). Its sole job is to strip `assistant`-role prefill messages from request bodies before forwarding them upstream. Some LLM gateways reject requests that contain an assistant turn as the last message; this proxy makes OpenCode's prefill feature transparent to those gateways.

- Listens on `http://127.0.0.1:18080` inside the container.
- OpenCode's config (`opencode.json`) points at this address instead of `LLM_BASE_URL` when the proxy is active.
- Enabled when `PREFILL_PROXY=true` (the default for OpenCode).
- Disabled automatically if the LLM gateway health check fails at startup (falls back to direct connection).
- Not used by Claude Code.

## Lifecycle

Started by `lib/proxy.sh:_start_proxy` (phase 10 of the boot flow). Killed on SIGTERM/SIGINT via the `_cleanup` trap registered in `entrypoint.sh`.

## Disabling

Set `PREFILL_PROXY=false` in `.env`. OpenCode will then connect directly to `LLM_BASE_URL`.
