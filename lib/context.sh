# ─── lib/context.sh ──────────────────────────────────────────────────────────
# Context window optimization for Claude Code.
# Disables skills, agents, and commands based on CODEBOX_* env vars to reduce
# the amount of tooling loaded into the system prompt.
#
# STRATEGY: Backs up targeted files to /tmp, then deletes them from the
# workspace. On graceful shutdown (SIGTERM/SIGINT), _restore_claude_context()
# copies them back so the host filesystem is left unchanged.
# If the container is hard-killed, files are trivially restored via:
#   git checkout -- .claude/

_CLAUDE_BACKUP_DIR="/tmp/.claude-pruned-backup"
_CLAUDE_CONTEXT_PRUNED=false

_restore_claude_context() {
    [ "${_CLAUDE_CONTEXT_PRUNED}" = "true" ] || return 0
    if [ -d "${_CLAUDE_BACKUP_DIR}" ]; then
        cp -a "${_CLAUDE_BACKUP_DIR}/." "/workspace/.claude/"
        rm -rf "${_CLAUDE_BACKUP_DIR}"
        _CLAUDE_CONTEXT_PRUNED=false
    fi
}

_optimize_claude_code_context() {
    local claude_dir="/workspace/.claude"
    local changes=""
    local needs_prune=false

    [ -d "${claude_dir}" ] || return 0

    if [ "${CODEBOX_SKILLS_BMAD:-true}" = "false" ] || [ "${CODEBOX_SKILLS_BMAD:-}" = "0" ]; then
        needs_prune=true
    fi
    if [ "${CODEBOX_GSD:-true}" = "false" ] || [ "${CODEBOX_GSD:-}" = "0" ]; then
        needs_prune=true
    fi

    [ "${needs_prune}" = "true" ] || return 0

    rm -rf "${_CLAUDE_BACKUP_DIR}"
    mkdir -p "${_CLAUDE_BACKUP_DIR}"

    # ─── BMad skills toggle ────────────────────────────────────────────
    if [ "${CODEBOX_SKILLS_BMAD:-true}" = "false" ] || [ "${CODEBOX_SKILLS_BMAD:-}" = "0" ]; then
        local bmad_count=0
        for dir in "${claude_dir}"/skills/bmad-*/; do
            [ -d "${dir}" ] || continue
            local rel="${dir#${claude_dir}/}"
            mkdir -p "${_CLAUDE_BACKUP_DIR}/${rel}"
            cp -a "${dir}/." "${_CLAUDE_BACKUP_DIR}/${rel}/"
            rm -rf "${dir}"
            bmad_count=$((bmad_count + 1))
        done
        [ "${bmad_count}" -gt 0 ] && changes="${changes} bmad-skills(${bmad_count})"

        local bmad_cmds=0
        if [ -d "${claude_dir}/commands" ]; then
            for cmd_file in "${claude_dir}"/commands/*.md; do
                [ -f "${cmd_file}" ] || continue
                mkdir -p "${_CLAUDE_BACKUP_DIR}/commands"
                cp -a "${cmd_file}" "${_CLAUDE_BACKUP_DIR}/commands/"
                rm -f "${cmd_file}"
                bmad_cmds=$((bmad_cmds + 1))
            done
        fi
        [ "${bmad_cmds}" -gt 0 ] && changes="${changes} bmad-commands(${bmad_cmds})"
    fi

    # ─── GSD system toggle ─────────────────────────────────────────────
    if [ "${CODEBOX_GSD:-true}" = "false" ] || [ "${CODEBOX_GSD:-}" = "0" ]; then
        local gsd_cmds=0 gsd_agents=0

        if [ -d "${claude_dir}/commands/gsd" ]; then
            gsd_cmds=$(find "${claude_dir}/commands/gsd/" -name "*.md" 2>/dev/null | wc -l)
            mkdir -p "${_CLAUDE_BACKUP_DIR}/commands"
            cp -a "${claude_dir}/commands/gsd" "${_CLAUDE_BACKUP_DIR}/commands/"
            rm -rf "${claude_dir}/commands/gsd"
        fi

        for agent in "${claude_dir}"/agents/gsd-*.md; do
            [ -f "${agent}" ] || continue
            mkdir -p "${_CLAUDE_BACKUP_DIR}/agents"
            cp -a "${agent}" "${_CLAUDE_BACKUP_DIR}/agents/"
            rm -f "${agent}"
            gsd_agents=$((gsd_agents + 1))
        done

        if [ -d "${claude_dir}/hooks" ]; then
            cp -a "${claude_dir}/hooks" "${_CLAUDE_BACKUP_DIR}/"
            rm -rf "${claude_dir}/hooks"
        fi

        if [ -f "${claude_dir}/gsd-file-manifest.json" ]; then
            cp -a "${claude_dir}/gsd-file-manifest.json" "${_CLAUDE_BACKUP_DIR}/"
            rm -f "${claude_dir}/gsd-file-manifest.json"
        fi

        if [ -d "${claude_dir}/get-shit-done" ]; then
            cp -a "${claude_dir}/get-shit-done" "${_CLAUDE_BACKUP_DIR}/"
            rm -rf "${claude_dir}/get-shit-done"
        fi

        changes="${changes} gsd-commands(${gsd_cmds}) gsd-agents(${gsd_agents}) gsd-hooks"
    fi

    _CLAUDE_CONTEXT_PRUNED=true

    if [ -n "${changes}" ]; then
        echo "  ✓ Context optimized: disabled${changes}"
        echo "    (backed up to ${_CLAUDE_BACKUP_DIR} — restored on shutdown)"
    fi
}
