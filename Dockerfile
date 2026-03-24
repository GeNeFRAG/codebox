# ═══════════════════════════════════════════════════════════════════
# Build stage: has build-essential for native npm modules
# ═══════════════════════════════════════════════════════════════════
FROM node:22-bookworm-slim AS builder

# Corporate CA cert (optional): passed as a build secret from CA_CERT_PATH.
# At runtime, mounted via docker-compose volume to /certs/ca-bundle.pem.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates build-essential python3 curl \
    && rm -rf /var/lib/apt/lists/*
RUN --mount=type=secret,id=ca-cert,required=false \
    mkdir -p /certs && \
    if [ -s /run/secrets/ca-cert ]; then \
        cp /run/secrets/ca-cert /usr/local/share/ca-certificates/custom-ca.crt && \
        cp /run/secrets/ca-cert /certs/ca-bundle.pem && \
        update-ca-certificates; \
    fi

ENV NODE_EXTRA_CA_CERTS=/certs/ca-bundle.pem
ENV NODE_OPTIONS="--use-openssl-ca"

# Install opencode-ai globally
# CACHEBUST_OPENCODE: changing this value invalidates the npm install cache
# so Docker re-fetches the latest version even when OPENCODE_VERSION=latest.
# opencode-web.sh rebuild/update pass --build-arg CACHEBUST_OPENCODE=$(date +%s).
ARG OPENCODE_VERSION=latest
ARG CACHEBUST_OPENCODE=0
RUN npm install -g opencode-ai@${OPENCODE_VERSION}

# Install Claude Code globally
ARG CLAUDE_CODE_VERSION=latest
ARG CACHEBUST_CLAUDE_CODE=0
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Install provider SDKs, plugins, and oh-my-opencode-slim
RUN mkdir -p /root/.config/opencode && \
    echo '{"dependencies":{"@ai-sdk/openai-compatible":"latest","@ai-sdk/groq":"^3.0.24","@opencode-ai/plugin":"latest","@openrouter/ai-sdk-provider":"^2.2.3","oh-my-opencode-slim":"latest"}}' \
    > /root/.config/opencode/package.json && \
    cd /root/.config/opencode && npm install

# Install MCP server packages globally (avoids npx registry checks at runtime)
RUN npm install -g \
    @modelcontextprotocol/server-memory@2026.1.26 \
    @upstash/context7-mcp@2.1.2 \
    @modelcontextprotocol/server-sequential-thinking@2025.12.18 \
    mcp-time-server@1.0.1 \
    @playwright/mcp@0.0.68 \
    @cyanheads/git-mcp-server@2.8.4

# ═══════════════════════════════════════════════════════════════════
# Runtime stage: slim, no build tools
# ═══════════════════════════════════════════════════════════════════
FROM node:22-bookworm-slim AS runtime

# LABEL maintainer="your-name"
LABEL description="OpenCode AI Web - persistent AI coding agent"

# ─── CA certificate ────────────────────────────────────────────────
# Build secret from CA_CERT_PATH; at runtime, compose mounts to /certs/ca-bundle.pem.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN --mount=type=secret,id=ca-cert,required=false \
    mkdir -p /certs && \
    if [ -s /run/secrets/ca-cert ]; then \
        cp /run/secrets/ca-cert /usr/local/share/ca-certificates/custom-ca.crt && \
        cp /run/secrets/ca-cert /certs/ca-bundle.pem && \
        update-ca-certificates; \
    fi

ENV NODE_EXTRA_CA_CERTS=/certs/ca-bundle.pem
ENV NODE_OPTIONS="--use-openssl-ca"

# ─── UTF-8 locale ─────────────────────────────────────────────────
# Required for Unicode rendering in tmux, ttyd, and TUI apps (box
# drawing, bullets, emoji, status bar glyphs).  C.UTF-8 is always
# available on bookworm-slim without installing extra locale packages.
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# ─── Runtime tools only (NO build-essential, NO docker.io) ─────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        curl \
        openssh-client \
        jq \
        gettext-base \
        unzip \
        ripgrep \
        tini \
        tmux \
        python3 \
        sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# ─── Docker CLI only (static binary, ~50 MB vs ~250 MB docker.io) ──
ARG DOCKER_VERSION=27.3.1
ARG TARGETARCH
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") && \
    curl -fsSL "https://download.docker.com/linux/static/stable/${ARCH}/docker-${DOCKER_VERSION}.tgz" \
    | tar xz --strip-components=1 -C /usr/local/bin docker/docker

# ─── ttyd (web terminal — used when OPENCODE_MODE=tui or tmux) ──────
ARG TTYD_VERSION=1.7.7
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") && \
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${ARCH}" \
    -o /usr/local/bin/ttyd && chmod +x /usr/local/bin/ttyd

# ─── Bun ───────────────────────────────────────────────────────────
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:$PATH"

# ─── Copy compiled artifacts from builder ──────────────────────────
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=builder /root/.config/opencode/node_modules /root/.config/opencode/node_modules
COPY --from=builder /root/.config/opencode/package.json /root/.config/opencode/package.json
COPY --from=builder /root/.npm /root/.npm

# ─── Plugin config (oh-my-opencode-slim) ───────────────────────────
# Baked into the image; override at runtime via docker-compose volume mount.
COPY oh-my-opencode-slim.json.example /root/.config/opencode/oh-my-opencode-slim.json

# Re-create global bin symlinks (npm symlinks are lost across stages)
# IMPORTANT: Copy the Go binary to a stable path OUTSIDE node_modules.
# oh-my-opencode-slim's auto-update-checker can rm -rf and rebuild
# node_modules at runtime, destroying the binary mid-session.
# /usr/local/bin/opencode-go is immune to npm/bun operations.
RUN cp /usr/local/lib/node_modules/opencode-ai/bin/.opencode /usr/local/bin/opencode-go && \
    chmod +x /usr/local/bin/opencode-go && \
    ln -sf /usr/local/lib/node_modules/opencode-ai/bin/opencode /usr/local/bin/opencode && \
    ln -sf /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js /usr/local/bin/claude && \
    ln -sf ../lib/node_modules/@modelcontextprotocol/server-memory/dist/index.js /usr/local/bin/mcp-server-memory && \
    ln -sf ../lib/node_modules/@upstash/context7-mcp/dist/index.js /usr/local/bin/context7-mcp && \
    ln -sf ../lib/node_modules/@modelcontextprotocol/server-sequential-thinking/dist/index.js /usr/local/bin/mcp-server-sequential-thinking && \
    ln -sf ../lib/node_modules/mcp-time-server/bin/mcp-time-server.js /usr/local/bin/mcp-time-server && \
    ln -sf ../lib/node_modules/@playwright/mcp/cli.js /usr/local/bin/playwright-mcp && \
    ln -sf ../lib/node_modules/@cyanheads/git-mcp-server/dist/index.js /usr/local/bin/git-mcp-server

# ─── Workspace and data directories ───────────────────────────────
RUN mkdir -p /workspace \
    /root/.local/share/opencode \
    /root/.config/opencode/skills \
    /root/.agents/skills \
    /root/.claude

WORKDIR /workspace

# ─── Skills (baked into image) ─────────────────────────────────────
# simplify + agent-browser: installed via npx skills add
# cartography: copied from bundled oh-my-opencode-slim package
RUN npx skills add https://github.com/brianlovin/claude-config --skill simplify -a '*' -y --global && \
    npx skills add https://github.com/vercel-labs/agent-browser --skill agent-browser -a '*' -y --global && \
    cp -r /root/.config/opencode/node_modules/oh-my-opencode-slim/src/skills/cartography /root/.config/opencode/skills/cartography

# ─── tmux configuration (TUI mode) ────────────────────────────────
COPY tmux.conf /root/.tmux.conf
COPY tmux-theme-dark.conf /opt/opencode/tmux-theme-dark.conf
COPY tmux-theme-light.conf /opt/opencode/tmux-theme-light.conf

# ─── Entrypoint and config ────────────────────────────────────────
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY opencode.json.template /opt/opencode/opencode.json.template
COPY claude-code.mcp.json.template /opt/opencode/claude-code.mcp.json.template
COPY prefill-proxy.mjs /opt/opencode/prefill-proxy.mjs
COPY agent-monitor.sh /opt/opencode/agent-monitor.sh
COPY agent-monitor-toggle.sh /opt/opencode/agent-monitor-toggle.sh
COPY agent-status.sh /opt/opencode/agent-status.sh
COPY session-status.sh /opt/opencode/session-status.sh
COPY session-status-claude.sh /opt/opencode/session-status-claude.sh
COPY tmux-theme-toggle.sh /opt/opencode/tmux-theme-toggle.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    /opt/opencode/agent-monitor.sh \
    /opt/opencode/agent-monitor-toggle.sh \
    /opt/opencode/agent-status.sh \
    /opt/opencode/session-status.sh \
    /opt/opencode/session-status-claude.sh \
    /opt/opencode/tmux-theme-toggle.sh

# Port is set at runtime via OPENCODE_PORT (default 3000)
# EXPOSE is omitted — each compose service maps its own port.

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -fsS -o /dev/null http://localhost:${OPENCODE_PORT:-3000}/ || exit 1

ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]
