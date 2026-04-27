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
CYAN='\033[0;36m'
NC='\033[0m'

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
    echo "                            Use 'Dockerfile.rbi' for FlowCode (RBI Artifactory required)"
    echo ""
    echo "Commands:"
    echo "  start [svc...]    Build and start services (default: all)"
    echo "  stop [svc...]     Stop services (default: all)"
    echo "  restart [svc...]  Restart — picks up .env AND lib/templates/entrypoint/proxy/tmux edits (no build)"
    echo "  logs [svc]        Follow logs"
    echo "  shell <svc>       Open a shell in a service"
    echo "  rebuild [svc...]  Rebuild image (use when Dockerfile or installed binaries change)"
    echo "  down              Stop and remove all containers"
    echo "  status            Show all services"
    echo "  urls              Show all running URLs"
    echo "  nuke [svc...]     Full rebuild — pulls latest opencode-ai/claude-code release"
    echo "  version [svc]     Show current opencode-ai version in container"
    echo ""
    echo "Services are defined in docker-compose.yml and docker-compose.override.yml"
    echo ""
    echo "Examples:"
    echo "  $0 start                                    # Start all repos"
    echo "  $0 start codebox                             # Start only this repo"
    echo "  $0 --dockerfile Dockerfile.rbi start        # Start with FlowCode (RBI only)"
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
        echo -e "${YELLOW}Pulling latest base image and rebuilding with latest opencode-ai...${NC}"
        $COMPOSE build --no-cache --pull --build-arg CODEBOX_VERSION=latest "$@"
        $COMPOSE up -d "$@"
        echo ""
        echo -e "${GREEN}✓ Updated. Current versions:${NC}"
        for svc in $($COMPOSE ps --services 2>/dev/null); do
            ver=$($COMPOSE exec -T "$svc" opencode --version 2>/dev/null || echo "unknown")
            echo -e "  ${CYAN}${svc}${NC}: opencode-ai ${ver}"
        done
        ;;
    version)
        shift
        for svc in ${@:-$($COMPOSE ps --services 2>/dev/null)}; do
            ver=$($COMPOSE exec -T "$svc" opencode --version 2>/dev/null || echo "not running")
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
