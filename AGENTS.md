# Project Context

This repo is a **Docker wrapper** for [OpenCode](https://github.com/opencode-ai/opencode). It does not contain the opencode application itself — it packages it into a container with MCP servers, a prefill proxy, and browser-accessible UI modes (web, tui, tmux).

## Key Files

| File | What it configures |
|------|--------------------|
| `entrypoint.sh` | Container startup sequence (config generation, auth, proxy, mode selection) |
| `opencode.json.template` | OpenCode config — MCP servers, permissions, provider endpoints |
| `oh-my-opencode-slim.json.example` | Agent preset — which model/skills/MCPs each agent role uses + fallback chains |
| `prefill-proxy.mjs` | Local HTTP proxy that strips assistant prefill messages before forwarding to the LLM |
| `docker-compose.yml` | Base service definition (volumes, healthcheck, resource limits) |
| `tmux.conf` | tmux keybindings and status bar config (tmux mode only) |
| `agent-monitor.sh` / `agent-status.sh` / `session-status.sh` | tmux status bar and monitor pane — poll the SQLite DB for subagent activity |
| `agent-monitor-toggle.sh` | Toggles the monitor pane on/off |

## Conventions

- Environment variables are documented in `.env.example` and substituted into configs by `entrypoint.sh` via `envsubst`.
- MCP servers are defined in `opencode.json.template`. Enabled ones run as Node processes; disabled ones (github, atlassian, grafana) require Docker socket access.
- Shell scripts target `bash` and run inside the container at `/opt/opencode/`.
- The `oh-my-opencode-slim` plugin is an npm package baked into the image. Its config lives at `/root/.config/opencode/oh-my-opencode-slim.json`.
