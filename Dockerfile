# ═══════════════════════════════════════════════════════════════════
# Build stage: has build-essential for native npm modules
# ═══════════════════════════════════════════════════════════════════
FROM node:22-bookworm-slim AS builder

# Corporate CA cert (optional): place your ca-bundle.pem in the build context
# or mount at runtime via docker-compose volume to /certs/ca-bundle.pem
COPY ca-bundle.pem* /usr/local/share/ca-certificates/custom-ca.crt
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates build-essential python3 curl \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/custom-ca.crt
ENV NODE_OPTIONS="--use-openssl-ca"

# Install opencode-ai globally
RUN npm install -g opencode-ai@1.2.15

# Install provider SDKs and plugins
RUN mkdir -p /root/.config/opencode && \
    echo '{"dependencies":{"@ai-sdk/openai-compatible":"latest","@ai-sdk/groq":"^3.0.24","@opencode-ai/plugin":"1.2.15","@openrouter/ai-sdk-provider":"^2.2.3"}}' \
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
COPY ca-bundle.pem* /usr/local/share/ca-certificates/custom-ca.crt
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/custom-ca.crt
ENV NODE_OPTIONS="--use-openssl-ca"

# ─── Runtime tools only (NO build-essential, NO docker.io) ─────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        curl \
        openssh-client \
        jq \
        gettext-base \
        unzip \
        ripgrep \
    && rm -rf /var/lib/apt/lists/*

# ─── Docker CLI only (static binary, ~50 MB vs ~250 MB docker.io) ──
ARG DOCKER_VERSION=27.3.1
ARG TARGETARCH
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") && \
    curl -fsSL "https://download.docker.com/linux/static/stable/${ARCH}/docker-${DOCKER_VERSION}.tgz" \
    | tar xz --strip-components=1 -C /usr/local/bin docker/docker

# ─── Bun ───────────────────────────────────────────────────────────
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:$PATH"

# ─── Copy compiled artifacts from builder ──────────────────────────
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=builder /root/.config/opencode/node_modules /root/.config/opencode/node_modules
COPY --from=builder /root/.config/opencode/package.json /root/.config/opencode/package.json
COPY --from=builder /root/.npm /root/.npm

# Re-create global bin symlinks (npm symlinks are lost across stages)
RUN ln -sf /usr/local/lib/node_modules/opencode-ai/bin/opencode /usr/local/bin/opencode && \
    ln -sf ../lib/node_modules/@modelcontextprotocol/server-memory/dist/index.js /usr/local/bin/mcp-server-memory && \
    ln -sf ../lib/node_modules/@upstash/context7-mcp/dist/index.js /usr/local/bin/context7-mcp && \
    ln -sf ../lib/node_modules/@modelcontextprotocol/server-sequential-thinking/dist/index.js /usr/local/bin/mcp-server-sequential-thinking && \
    ln -sf ../lib/node_modules/mcp-time-server/bin/mcp-time-server.js /usr/local/bin/mcp-time-server && \
    ln -sf ../lib/node_modules/@playwright/mcp/cli.js /usr/local/bin/playwright-mcp && \
    ln -sf ../lib/node_modules/@cyanheads/git-mcp-server/dist/index.js /usr/local/bin/git-mcp-server

# ─── Workspace and data directories ───────────────────────────────
RUN mkdir -p /workspace \
    /root/.local/share/opencode \
    /root/.config/opencode/commands \
    /root/.config/opencode/skills \
    /root/.agents/skills

WORKDIR /workspace

# ─── Entrypoint and config ────────────────────────────────────────
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY opencode.json.template /opt/opencode/opencode.json.template
COPY prefill-proxy.mjs /opt/opencode/prefill-proxy.mjs
RUN chmod +x /usr/local/bin/entrypoint.sh

# Port is set at runtime via OPENCODE_PORT (default 3000)
# EXPOSE is omitted — each compose service maps its own port.

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:${OPENCODE_PORT:-3000}/ || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
