# ═══════════════════════════════════════════════════════════════════
# Build stage: has build-essential for native npm modules
# ═══════════════════════════════════════════════════════════════════
# Global build args (declared before first FROM for cross-stage visibility)

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
# CACHEBUST_CODEBOX: changing this value invalidates the npm install cache
# so Docker re-fetches the latest version even when CODEBOX_VERSION=latest.
# codebox.sh rebuild/update pass --build-arg CACHEBUST_CODEBOX=$(date +%s).
ARG CODEBOX_VERSION=latest
ARG CACHEBUST_CODEBOX=0
RUN npm install -g opencode-ai@${CODEBOX_VERSION}

# Install Claude Code globally
ARG CLAUDE_CODE_VERSION=latest
ARG CACHEBUST_CLAUDE_CODE=0
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Install Pi coding agent globally
# --ignore-scripts is what pi.dev's own install docs specify.
ARG PI_VERSION=latest
ARG CACHEBUST_PI=0
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent@${PI_VERSION}

# Install provider SDKs, plugins, and oh-my-opencode-slim
# Pins are EXACT (no "latest"/caret ranges) so npm never needs to revalidate
# a tag against the registry — lib/plugins.sh compares an md5 fingerprint of
# this file against a baked .deps-fingerprint and skips `npm install` at
# runtime when they match, saving ~4-5s on every container start. Bump these
# deliberately: run an unpinned install once, read the resolved versions back
# out of package-lock.json, and pin those exact versions here.
RUN mkdir -p /root/.config/opencode && \
    echo '{"dependencies":{"@ai-sdk/openai-compatible":"3.0.39","@ai-sdk/groq":"3.0.63","@opencode-ai/plugin":"1.18.23","@openrouter/ai-sdk-provider":"2.10.0","oh-my-opencode-slim":"2.2.17"}}' \
    > /root/.config/opencode/package.json && \
    cd /root/.config/opencode && npm install && \
    md5sum /root/.config/opencode/package.json | cut -d' ' -f1 \
        > /root/.config/opencode/.deps-fingerprint

# Install MCP server packages globally (avoids npx registry checks at runtime)
RUN npm install -g \
    @modelcontextprotocol/server-memory@2026.1.26 \
    @upstash/context7-mcp@2.1.2 \
    @modelcontextprotocol/server-sequential-thinking@2025.12.18 \
    mcp-time-server@1.0.1 \
    playwright \
    @cyanheads/git-mcp-server@2.8.4 \
    @hypnosis/docker-mcp-server@1.4.1 \
    serve@14.2.3 \
    wrangler

# ═══════════════════════════════════════════════════════════════════
# atl-builder: RBI-internal Atlassian CLI (https://code.rbi.tech/raiffeisen/atl)
# Source is passed via the `atl` build context (ATL_SRC_PATH in .env).
# Falls back to a stub when ATL_SRC_PATH is not set or points to an empty dir.
# ═══════════════════════════════════════════════════════════════════
FROM golang:1.26-alpine AS atl-builder

RUN apk add --no-cache ca-certificates
RUN --mount=type=secret,id=ca-cert,required=false \
    if [ -s /run/secrets/ca-cert ]; then \
        cp /run/secrets/ca-cert /usr/local/share/ca-certificates/custom-ca.crt && \
        update-ca-certificates; \
    fi

COPY --from=atl . /src/
RUN if [ -f /src/go.mod ]; then \
        cd /src && go build -o /usr/local/bin/atl . ; \
    else \
        printf '#!/bin/sh\necho "atl: set ATL_SRC_PATH in .env and rebuild"\nexit 1\n' \
            > /usr/local/bin/atl ; \
    fi && chmod +x /usr/local/bin/atl

# ═══════════════════════════════════════════════════════════════════
# Runtime stage: slim, no build tools
# ═══════════════════════════════════════════════════════════════════
FROM node:22-bookworm-slim AS runtime

# LABEL maintainer="your-name"
LABEL description="CodeBox - persistent AI coding agent"

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
        fd-find \
        tini \
        tmux \
        zsh \
        python3 \
        sqlite3 \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd

# ─── Zsh + Oh My Zsh (shell pane) ────────────────────────────────
RUN git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git /root/.oh-my-zsh \
    && cp /root/.oh-my-zsh/templates/zshrc.zsh-template /root/.zshrc

# ─── Docker CLI only (static binary, ~50 MB vs ~250 MB docker.io) ──
ARG DOCKER_VERSION=27.3.1
ARG TARGETARCH
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") && \
    curl -fsSL "https://download.docker.com/linux/static/stable/${ARCH}/docker-${DOCKER_VERSION}.tgz" \
    | tar xz --strip-components=1 -C /usr/local/bin docker/docker

# ─── Docker Compose v2 CLI plugin ──────────────────────────────────
# The static tarball above ships the CLI only, no cli-plugins dir, so
# `docker compose` was an unknown command and the shim below dead.
# Pinned to the last v2 release deliberately: v5 dropped the internal
# buildkit builder and delegates builds to Docker Bake, so it would also
# need the buildx plugin (~60 MB) before codebox.sh's `build` / `up
# --build` worked. v2 is self-contained, and 2.24+ is all the
# `!override` tag in docker-compose.override.yml requires.
ARG DOCKER_COMPOSE_VERSION=2.40.3
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") && \
    mkdir -p /usr/local/lib/docker/cli-plugins && \
    curl -fsSL "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${ARCH}" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose && \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# ─── docker-compose shim (delegates to compose v2; needed by legacy scripts) ──
RUN printf '#!/bin/sh\nexec docker compose "$@"\n' > /usr/local/bin/docker-compose && \
    chmod +x /usr/local/bin/docker-compose

# ─── ttyd (web terminal — used when CODEBOX_MODE=tui or tmux) ──────
ARG TTYD_VERSION=1.7.7
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") && \
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${ARCH}" \
    -o /usr/local/bin/ttyd && chmod +x /usr/local/bin/ttyd

# ─── mkcert (locally-trusted TLS certs for ttyd clipboard support) ──
ARG MKCERT_VERSION=1.4.4
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "amd64") && \
    curl -fsSL "https://github.com/FiloSottile/mkcert/releases/download/v${MKCERT_VERSION}/mkcert-v${MKCERT_VERSION}-linux-${ARCH}" \
    -o /usr/local/bin/mkcert && chmod +x /usr/local/bin/mkcert

# ─── Bun ───────────────────────────────────────────────────────────
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:$PATH:/host/homebrew-bin:/host/homebrew-sbin:/host/usr-local-bin:/host/usr-local-sbin:/host/user-local-bin"

# ─── Copy compiled artifacts from builder ──────────────────────────
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=builder /root/.config/opencode/node_modules /root/.config/opencode/node_modules
COPY --from=builder /root/.config/opencode/package.json /root/.config/opencode/package.json
COPY --from=builder /root/.config/opencode/.deps-fingerprint /root/.config/opencode/.deps-fingerprint
COPY --from=builder /root/.npm /root/.npm

# Re-create global bin symlinks (npm symlinks are lost across stages)
# IMPORTANT: Copy the Go binary to a stable path OUTSIDE node_modules.
# oh-my-opencode-slim's auto-update-checker can rm -rf and rebuild
# node_modules at runtime, destroying the binary mid-session.
# /usr/local/bin/opencode-go is immune to npm/bun operations.
# The binary name varies across opencode-ai releases (.opencode, opencode, etc.)
# so we locate it by excluding JS files rather than hardcoding the name.
RUN go_bin=$(find /usr/local/lib/node_modules/opencode-ai/bin -maxdepth 1 -type f \
        ! -name '*.js' ! -name '*.mjs' ! -name '*.cjs' 2>/dev/null | head -1) && \
    if [ -n "$go_bin" ]; then \
        cp "$go_bin" /usr/local/bin/opencode-go && chmod +x /usr/local/bin/opencode-go; \
    fi && \
    if [ -f /usr/local/lib/node_modules/opencode-ai/bin/opencode ]; then \
        ln -sf /usr/local/lib/node_modules/opencode-ai/bin/opencode /usr/local/bin/opencode; \
    elif [ -x /usr/local/bin/opencode-go ]; then \
        ln -sf /usr/local/bin/opencode-go /usr/local/bin/opencode; \
    fi && \
    ln -sf /usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe /usr/local/bin/claude && \
    pi_dir=/usr/local/lib/node_modules/@earendil-works/pi-coding-agent && \
    pi_bin=$(node -e 'const b=require(process.argv[1]+"/package.json").bin; process.stdout.write(typeof b==="string"?b:(b&&(b.pi||Object.values(b)[0]))||"")' "$pi_dir" 2>/dev/null || true) && \
    if [ -z "$pi_bin" ] || [ ! -f "$pi_dir/$pi_bin" ]; then \
        pi_bin=$(cd "$pi_dir" 2>/dev/null && find dist bin -maxdepth 2 -type f -name '*cli*.js' 2>/dev/null | head -1 || true); \
    fi && \
    if [ -n "$pi_bin" ] && [ -f "$pi_dir/$pi_bin" ]; then \
        ln -sf "$pi_dir/$pi_bin" /usr/local/bin/pi && chmod +x "$pi_dir/$pi_bin"; \
    else \
        echo "WARNING: could not resolve pi binary under $pi_dir — /usr/local/bin/pi will be missing (CODEBOX_APP=pi will fail at startup)"; \
    fi && \
    ln -sf ../lib/node_modules/@modelcontextprotocol/server-memory/dist/index.js /usr/local/bin/mcp-server-memory && \
    ln -sf ../lib/node_modules/@upstash/context7-mcp/dist/index.js /usr/local/bin/context7-mcp && \
    ln -sf ../lib/node_modules/@modelcontextprotocol/server-sequential-thinking/dist/index.js /usr/local/bin/mcp-server-sequential-thinking && \
    ln -sf ../lib/node_modules/mcp-time-server/bin/mcp-time-server.js /usr/local/bin/mcp-time-server && \
    ln -sf ../lib/node_modules/playwright/cli.js /usr/local/bin/playwright && \
    ln -sf ../lib/node_modules/@cyanheads/git-mcp-server/dist/index.js /usr/local/bin/git-mcp-server && \
    ln -sf ../lib/node_modules/@hypnosis/docker-mcp-server/dist/index.js /usr/local/bin/docker-mcp-server && \
    ln -sf ../lib/node_modules/serve/build/main.js /usr/local/bin/serve

# ─── Workspace and data directories ───────────────────────────────
RUN mkdir -p /workspace \
    /root/.local/share/opencode \
    /root/.config/opencode/skills \
    /root/.agents/skills \
    /root/.claude \
    /root/.pi/agent

WORKDIR /workspace

# ─── Skills (baked into image) ─────────────────────────────────────
# simplify + agent-browser: installed via npx skills add
# codemap: copied from bundled oh-my-opencode-slim package (was "cartography" before v1.0.0)
RUN npx skills add https://github.com/brianlovin/claude-config --skill simplify -a '*' -y --global && \
    npx skills add https://github.com/vercel-labs/agent-browser --skill agent-browser -a '*' -y --global && \
    cp -r /root/.config/opencode/node_modules/oh-my-opencode-slim/src/skills/codemap /root/.config/opencode/skills/codemap

# ─── Playwright system libraries (browsers install at runtime) ──────
# `install-deps` apt-installs only the X11/GTK/font/audio libraries that
# Chrome needs (~376 MB, no browser binaries) — it runs its own
# apt-get update, so the empty lists left by the layer above are fine.
# The browsers themselves (~984 MB) are NOT baked in. They download per
# container on first start into a named volume, gated by the runtime
# CODEBOX_PLAYWRIGHT var — see lib/playwright.sh. This keeps one image
# shared by every service instead of one variant per Playwright setting.
# These libraries also back the agent-browser skill, which drives Chrome
# over CDP and needs the same shared objects.
ENV PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright
RUN playwright install-deps chromium && rm -rf /var/lib/apt/lists/*

# ═══════════════════════════════════════════════════════════════════
# Churn zone: everything below re-runs on most builds.
# Keep expensive layers ABOVE this line.
#
# The atl build context is a fresh `git clone` into a new temp dir on
# every codebox.sh invocation (see _clone_atl), so its digest changes
# each build and invalidates every layer beneath it. Keeping the COPY
# here means that only trivial COPYs are affected — do not move it up.
# ═══════════════════════════════════════════════════════════════════

# ─── atl (RBI-internal Atlassian CLI, optional) ────────────────────
COPY --from=atl-builder /usr/local/bin/atl /usr/local/bin/atl

# ─── Agent skills ─────────────────────────────────────────────────
# /root/.agents/skills is the harness-neutral global skill dir read by
# Pi (see its docs/skills.md). Skills here describe binaries baked in
# above, so their lifetime matches the image's — hence the COPY rather
# than a runtime write into the per-service config volume.
COPY skills/ /root/.agents/skills/

# ─── tmux configuration (TUI mode) ────────────────────────────────
COPY tmux/tmux.conf /root/.tmux.conf
COPY tmux/ /opt/opencode/tmux/

# ─── Plugin config (oh-my-opencode-slim) ───────────────────────────
# Baked into the image; override at runtime via docker-compose volume mount.
COPY templates/oh-my-opencode-slim.json.template /root/.config/opencode/oh-my-opencode-slim.json

# ─── Entrypoint and config ────────────────────────────────────────
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY bin/mcp-run /usr/local/bin/mcp-run
COPY bin/websearch-mcp.js /opt/opencode/bin/websearch-mcp.js
COPY lib/ /opt/opencode/lib/
COPY templates/ /opt/opencode/templates/
COPY proxy/prefill-proxy.mjs /opt/opencode/proxy/prefill-proxy.mjs
RUN chmod +x /usr/local/bin/entrypoint.sh \
    /usr/local/bin/mcp-run \
    && find /opt/opencode/tmux -name '*.sh' -exec chmod +x {} +

# Port is set at runtime via CODEBOX_PORT (default 3000)
# EXPOSE is omitted — each compose service maps its own port.

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -fsS -o /dev/null http://localhost:${CODEBOX_PORT:-3000}/ || exit 1

ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]
