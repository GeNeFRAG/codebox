# bin/

Helper scripts copied into `/usr/local/bin/` in the container image.

| File | Purpose |
|------|---------|
| `mcp-run` | Stdio-safe `docker run` wrapper for Docker-socket MCP servers |

## mcp-run

MCP servers that run as sibling containers (e.g. GitHub, Atlassian, Grafana) need the Docker socket. `mcp-run` wraps `docker run -i --rm` and ensures only one instance with a given logical name runs at a time — it kills any prior container with the same name before spawning a new one. This prevents orphaned containers after agent hard-kills or tmux `respawn-pane`.

Usage in a template (e.g. `templates/opencode.json.template`):
```json
"command": "mcp-run",
"args": ["my-server", "--rm", "-i", "my-image:latest", "--some-flag"]
```

The first argument after `mcp-run` becomes the container name (`mcp-<name>`); remaining arguments are passed directly to `docker run`.
