#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f ${SCRIPT_DIR}/docker-compose.yml"

# Include override file if it exists
if [ -f "${SCRIPT_DIR}/docker-compose.override.yml" ]; then
    COMPOSE="${COMPOSE} -f ${SCRIPT_DIR}/docker-compose.override.yml"
fi

# ─── --dockerfile / -d flag (optional) ────────────────────────────
# Override the Dockerfile used for build commands.
# E.g.: ./codebox.sh --dockerfile Dockerfile.rbi start
if [ "${1:-}" = "--dockerfile" ] || [ "${1:-}" = "-d" ]; then
    if [ -z "${2:-}" ]; then
        echo "Error: --dockerfile requires a filename argument"
        exit 1
    fi
    export DOCKERFILE="${2}"
    shift 2
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Host-only commands ───────────────────────────────────────────
# The container ships a Docker CLI + Compose plugin and mounts the host's
# docker.sock, so every command in here *runs* — it just does the wrong
# thing, in one of three ways:
#
#   1. Path rewrite — start / restart / rebuild / nuke. Compose resolves
#      relative and ~ paths against the client's filesystem while the
#      daemon reads the result as a host path, so in here `.` becomes
#      /workspace and `~/.ssh` becomes /root/.ssh, neither of which is
#      the real host path. Anything that creates a container recreates it
#      with mounts pointing at paths that do not exist on the host,
#      silently losing the workspace bind and the dev-iteration mounts.
#
#   2. Self-destruct — stop / down / restart. These address containers by
#      project label, which resolves perfectly well in here — including
#      the container running the command. `stop` with no service argument
#      stops every CodeBox container, this one included, killing the
#      session mid-command.
#
#   3. Host-wide destruction — prune. `docker builder prune` and
#      `docker image prune` hit the host daemon and reclaim the host's
#      build cache from a nested context that cannot see what it broke.
#
# This is an allowlist, not a blocklist. A blocklist fails open: the
# previous one enumerated the path-rewrite commands only, so `stop` and
# `prune` slipped through, and every command added to the `case` block
# below would have slipped through too. Naming the safe commands instead
# means new subcommands are refused in here until deliberately cleared.
#
# Raw `docker` commands bypass this file entirely — lib/guard-bin/docker
# guards those, and lib/docker-guard.sh puts it on PATH at startup.
#
# Escape hatch for a native-Linux host that mounts the repo at the same
# path inside and out, where the rewrite is a no-op:
#   CODEBOX_ALLOW_IN_CONTAINER=true ./codebox.sh restart svc
_CONTAINER_SAFE=" logs shell status urls version help "
if { [ -f /run/codebox-container ] || [ -f /.dockerenv ] || [ -f /run/.containerenv ]; } \
   && [ "${CODEBOX_ALLOW_IN_CONTAINER:-false}" != "true" ] \
   && [[ "${_CONTAINER_SAFE}" != *" ${1:-help} "* ]]; then
    echo -e "${RED}Error: '${1:-}' is not available inside a CodeBox container.${NC}" >&2
    echo "" >&2
    echo "It would either recreate containers with bind mounts resolved against" >&2
    echo "the container filesystem (./ → /workspace, ~ → /root), stop the very" >&2
    echo "container running this command, or prune the host's build cache." >&2
    echo "" >&2
    echo -e "Run it in a terminal on the host instead. From in here, these are safe:" >&2
    echo -e "  ${CYAN}$0 status${NC} · ${CYAN}$0 logs <svc>${NC} · ${CYAN}$0 shell <svc>${NC} · ${CYAN}$0 urls${NC} · ${CYAN}$0 version${NC}" >&2
    exit 1
fi

# Clone atl source to a temp dir and export ATL_SRC_PATH for the Docker build.
# Falls back silently if the repo is unreachable — the image will contain a stub.
_clone_atl() {
    local repo="${ATL_REPO_URL:-https://code.rbi.tech/raiffeisen/atl}"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    echo -e "${CYAN}Cloning atl from ${repo}...${NC}"
    if git clone --depth=1 --quiet "${repo}" "${tmp_dir}" 2>/dev/null; then
        export ATL_SRC_PATH="${tmp_dir}"
        # shellcheck disable=SC2064
        trap "rm -rf '${tmp_dir}'" EXIT
        echo -e "${GREEN}✓ atl source ready${NC}"
    else
        rm -rf "${tmp_dir}"
        echo -e "${YELLOW}  Warning: could not clone atl — binary will not be available in image${NC}"
    fi
}

# ─── Pre-flight: ensure host-side mount targets exist ─────────────
# Docker bind-mounts to files that don't exist will silently create
# empty *directories*, which confuses later reads. Worse, mounting
# /dev/null as a file works on native Linux but is fragile on Docker
# Desktop / Rancher Desktop after a VM restart.
# This function creates missing placeholder files so Docker always
# has a real file to mount.
_preflight() {
    # Host auth.json — entrypoint merges Copilot tokens from this
    local auth_dir="${HOME}/.local/share/opencode"
    local auth_file="${auth_dir}/auth.json"
    if [ -d "${auth_file}" ]; then
        # Docker previously created an empty directory here — fix it
        rmdir "${auth_file}" 2>/dev/null || true
    fi
    if [ ! -f "${auth_file}" ]; then
        mkdir -p "${auth_dir}"
        echo '{}' > "${auth_file}"
    fi

    # GitHub Copilot config directory
    mkdir -p "${HOME}/.config/github-copilot" 2>/dev/null || true

    _clone_atl

    # .env file — Docker bind-mounts create an empty directory if the
    # source file doesn't exist, which breaks env_file and .env reload.
    if [ -d "${SCRIPT_DIR}/.env" ]; then
        rmdir "${SCRIPT_DIR}/.env" 2>/dev/null || true
    fi
    if [ ! -f "${SCRIPT_DIR}/.env" ]; then
        touch "${SCRIPT_DIR}/.env"
        echo -e "${YELLOW}  Created empty .env (copy .env.example and fill in your values)${NC}"
    fi
}

usage() {
    echo "Usage: $0 [--dockerfile <file>] <command> [service...]"
    echo ""
    echo "Options:"
    echo "  --dockerfile, -d <file>   Dockerfile to build from (default: Dockerfile)"
    echo ""
    echo "Commands:"
    echo "  start [svc...]    Build and start services (default: all)"
    echo "  stop [svc...]     Stop services (default: all)"
    echo "  restart [svc...]  Restart — picks up .env, plus lib/templates/entrypoint/proxy/tmux"
    echo "                    edits ONLY if the service bind-mounts them (no build)"
    echo "  logs [svc]        Follow logs"
    echo "  shell <svc>       Open a shell in a service"
    echo "  rebuild [svc...]  Rebuild image (use when Dockerfile or installed binaries change)"
    echo "  down              Stop and remove all containers"
    echo "  status            Show all services"
    echo "  urls              Show all running URLs"
    echo "  nuke [svc...]     Full rebuild — auto-prunes stale layers, then pulls latest opencode-ai/claude-code"
    echo "  prune             Reclaim Docker build cache and dangling layers"
    echo "  version [svc]     Show current opencode-ai version in container"
    echo ""
    echo "Services are defined in docker-compose.yml and docker-compose.override.yml"
    echo ""
    echo "Host-only: start, stop, restart, rebuild, nuke, down, prune. Run these in"
    echo "a terminal on the host — inside a CodeBox container they would recreate"
    echo "services with bind mounts resolved against the container filesystem, stop"
    echo "the container running the command, or prune the host's build cache."
    echo "Safe in-container: logs, shell, status, urls, version."
    echo ""
    echo "Examples:"
    echo "  $0 start                                    # Start all repos"
    echo "  $0 start codebox                             # Start only this repo"
    echo "  $0 -d Dockerfile.rbi rebuild codebox"
    echo "  $0 logs codebox                             # Follow logs"
    echo "  $0 shell codebox                            # Bash into container"
    echo ""
}

case "${1:-help}" in
    start)
        shift
        _preflight
        echo -e "${GREEN}Starting CodeBox...${NC}"
        $COMPOSE up -d --build "$@"
        echo ""
        echo -e "${GREEN}✓ Services running:${NC}"
        $COMPOSE ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || $COMPOSE ps
        ;;
    stop)
        shift
        echo -e "${YELLOW}Stopping...${NC}"
        $COMPOSE stop "$@"
        echo -e "${GREEN}✓ Stopped${NC}"
        ;;
    restart)
        shift
        _preflight
        echo -e "${YELLOW}Restarting (recreating containers to pick up .env changes)...${NC}"
        $COMPOSE up -d --force-recreate "$@"
        echo ""
        echo -e "${GREEN}✓ Services restarted:${NC}"
        $COMPOSE ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || $COMPOSE ps
        ;;
    logs)
        shift
        $COMPOSE logs -f "$@"
        ;;
    shell)
        shift
        if [ -z "$1" ]; then
            echo "Usage: $0 shell <service>"
            exit 1
        fi
        $COMPOSE exec "$1" bash
        ;;
    rebuild)
        shift
        _preflight
        echo -e "${YELLOW}Rebuilding...${NC}"
        echo -e "${CYAN}Tip: use 'nuke' to pull the latest opencode-ai/claude-code release.${NC}"
        $COMPOSE build "$@"
        $COMPOSE up -d --force-recreate "$@"
        ;;
    status)
        $COMPOSE ps
        ;;
    urls)
        echo -e "${CYAN}CodeBox URLs:${NC}"
        $COMPOSE ps --format "table {{.Name}}\t{{.Ports}}" 2>/dev/null || $COMPOSE ps
        ;;
    nuke)
        shift
        _preflight
        echo -e "${YELLOW}Pruning stale Docker layers from previous builds...${NC}"
        docker builder prune -f
        docker image prune -f
        echo -e "${YELLOW}Pulling latest base image and rebuilding with latest opencode-ai...${NC}"
        $COMPOSE build --no-cache --pull --build-arg CODEBOX_VERSION=latest "$@"
        $COMPOSE up -d "$@"
        echo ""
        echo -e "${GREEN}✓ Updated. Current versions:${NC}"
        for svc in $($COMPOSE ps --services 2>/dev/null); do
            ver=$($COMPOSE exec -T "$svc" sh -c \
              'for b in opencode-go opencode; do command -v "$b" >/dev/null 2>&1 && "$b" --version 2>/dev/null && break; done || echo "unknown"' \
              2>/dev/null || echo "unknown")
            echo -e "  ${CYAN}${svc}${NC}: opencode-ai ${ver}"
        done
        ;;
    prune)
        echo -e "${YELLOW}Pruning Docker build cache and dangling images...${NC}"
        before=$(df -h / | awk 'NR==2 {print $4}')
        docker builder prune -f
        docker image prune -f
        after=$(df -h / | awk 'NR==2 {print $4}')
        echo -e "${GREEN}✓ Done. Free space: ${before} → ${after}${NC}"
        ;;
    version)
        shift
        for svc in ${@:-$($COMPOSE ps --services 2>/dev/null)}; do
            ver=$($COMPOSE exec -T "$svc" sh -c \
              'for b in opencode-go opencode; do command -v "$b" >/dev/null 2>&1 && "$b" --version 2>/dev/null && break; done || echo "unknown"' \
              2>/dev/null || echo "not running")
            echo -e "  ${CYAN}${svc}${NC}: opencode-ai ${ver}"
        done
        ;;
    down)
        echo -e "${YELLOW}Stopping and removing all...${NC}"
        $COMPOSE down
        echo -e "${GREEN}✓ Done${NC}"
        ;;
    *)
        usage
        exit 1
        ;;
esac
