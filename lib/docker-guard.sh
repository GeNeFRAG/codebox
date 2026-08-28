#!/bin/bash
# ─── Docker self-destruct guard installation ────────────────────────
# Puts lib/guard-bin/docker in front of the real Docker CLI on PATH, so
# nothing running in this container can stop, remove, or recreate the
# container it lives in via the mounted host docker.sock. See the header
# of lib/guard-bin/docker for the decision rules.
#
# Sourced by entrypoint.sh (phase 3b), which then calls
# _install_docker_guard.

GUARD_BIN="/opt/opencode/lib/guard-bin"

_install_docker_guard() {
    if [ ! -x "${GUARD_BIN}/docker" ]; then
        echo "  ⚠ docker guard not found at ${GUARD_BIN}/docker — skipping"
        return 0
    fi

    # Which Compose project do we belong to? Same self-introspection the
    # CA cert path resolution uses. Falls back to the pinned project name
    # in docker-compose.yml if the socket isn't ready yet.
    CODEBOX_COMPOSE_PROJECT="$(docker inspect "$(hostname)" \
        --format '{{index .Config.Labels "com.docker.compose.project"}}' \
        2>/dev/null || true)"
    export CODEBOX_COMPOSE_PROJECT="${CODEBOX_COMPOSE_PROJECT:-codebox}"

    # Positive "you are inside CodeBox" marker. codebox.sh reads it to
    # refuse host-only subcommands, and the shim reads the project name
    # from it in shells that did not inherit the export.
    echo "${CODEBOX_COMPOSE_PROJECT}" > /run/codebox-container 2>/dev/null \
        || echo "  ⚠ could not write /run/codebox-container"

    # For this process tree: the agent, ttyd, tmux, and every shell they spawn.
    case ":${PATH}:" in
        *":${GUARD_BIN}:"*) ;;
        *) export PATH="${GUARD_BIN}:${PATH}" ;;
    esac

    # For shells that do not inherit the above: `codebox.sh shell <svc>` is
    # `docker compose exec … bash`, which gets the image's ENV PATH, and the
    # tmux server survives restarts so its existing panes keep the old one.
    local line="export PATH=\"${GUARD_BIN}:\${PATH}\"  # codebox docker guard"
    local rc
    for rc in /root/.bashrc /root/.zshrc; do
        [ -f "${rc}" ] || touch "${rc}" 2>/dev/null || continue
        grep -qF "${GUARD_BIN}" "${rc}" 2>/dev/null || echo "${line}" >> "${rc}"
    done

    echo "→ Docker guard active (project '${CODEBOX_COMPOSE_PROJECT}' is protected from in-container stop/rm)"
}
