#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f ${SCRIPT_DIR}/docker-compose.yml"

# Include override file if it exists
if [ -f "${SCRIPT_DIR}/docker-compose.override.yml" ]; then
    COMPOSE="${COMPOSE} -f ${SCRIPT_DIR}/docker-compose.override.yml"
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <command> [service...]"
    echo ""
    echo "Commands:"
    echo "  start [svc...]    Build and start services (default: all)"
    echo "  stop [svc...]     Stop services (default: all)"
    echo "  restart [svc...]  Restart services"
    echo "  logs [svc]        Show logs (follow)"
    echo "  shell <svc>       Open a shell in a service"
    echo "  rebuild [svc...]  Force rebuild and start"
    echo "  down              Stop and remove all containers"
    echo "  status            Show all services"
    echo "  urls              Show all running URLs"
    echo ""
    echo "Services are defined in docker-compose.yml and docker-compose.override.yml"
    echo ""
    echo "Examples:"
    echo "  $0 start                   # Start all repos"
    echo "  $0 start opencode-docker   # Start only this repo"
    echo "  $0 logs opencode-docker    # Follow logs"
    echo "  $0 shell opencode-docker   # Bash into container"
    echo ""
}

case "${1:-help}" in
    start)
        shift
        echo -e "${GREEN}Starting OpenCode Web...${NC}"
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
        $COMPOSE restart "$@"
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
        echo -e "${YELLOW}Rebuilding...${NC}"
        $COMPOSE up -d --build --force-recreate "$@"
        ;;
    status)
        $COMPOSE ps
        ;;
    urls)
        echo -e "${CYAN}OpenCode Web URLs:${NC}"
        $COMPOSE ps --format "table {{.Name}}\t{{.Ports}}" 2>/dev/null || $COMPOSE ps
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
