# ─── lib/system-checks.sh ───────────────────────────────────────────────────
# Runtime environment validation:
#   - Docker socket availability (for MCP servers)
#   - Git configuration mounts (.gitconfig, .git-credentials, .gitconfig-work)
#   - safe.directory setup for all repos under /workspace
#   - Workspace symlinks into $HOME for "Open project" dialog discovery

# ─── Docker socket check (for MCP servers) ────────────────────────
if [ -S "/var/run/docker.sock" ]; then
    echo "  ✓ Docker socket available (MCP containers supported)"
    # Kill any MCP containers left over from a previous CodeBox session so
    # they don't duplicate when the agent spawns new ones on startup.
    _stale=$(docker ps -q --filter label=codebox.role=mcp 2>/dev/null)
    if [ -n "${_stale}" ]; then
        echo "  ↻ Removing stale MCP containers from previous session"
        echo "${_stale}" | xargs docker rm -f >/dev/null 2>&1 || true
    fi
else
    echo "  ⚠ Docker socket not mounted - Docker-based MCP servers will not work"
fi

# ─── Git configuration ────────────────────────────────────────────
# Validate .gitconfig mount — Docker creates a directory if the host file
# doesn't exist, which breaks git. Redirect to an empty file in that case.
GITCONFIG="/root/.gitconfig"
if [ -d "${GITCONFIG}" ]; then
    echo "  ⚠ ${GITCONFIG} is a directory (host ~/.gitconfig missing?) — using defaults"
    echo "    Create ~/.gitconfig on the host, or ignore this if git defaults are fine"
    export GIT_CONFIG_GLOBAL="/dev/null"
elif [ -f "${GITCONFIG}" ] && [ -s "${GITCONFIG}" ]; then
    echo "  ✓ Host .gitconfig mounted"
fi

# Host .gitconfig is mounted read-only; use env vars to add safe.directory.
# Discover all git repos under /workspace (supports multi-repo workspaces).
# Capture once into an array to avoid re-globbing later (TOCTOU safety).
_gitdirs=()
[ -d /workspace/.git ] && _gitdirs+=(/workspace/.git)
for _g in /workspace/*/.git; do
    [ -d "${_g}" ] && _gitdirs+=("${_g}")
done

_git_idx=0
for _gitdir in "${_gitdirs[@]}"; do
    _repo_path="$(dirname "${_gitdir}")"
    export "GIT_CONFIG_KEY_${_git_idx}=safe.directory"
    export "GIT_CONFIG_VALUE_${_git_idx}=${_repo_path}"
    _git_idx=$((_git_idx + 1))
done
_repo_count=${#_gitdirs[@]}
export GIT_CONFIG_COUNT="${_git_idx}"

if [ "${_repo_count}" -gt 1 ]; then
    echo "  ✓ Multi-repo workspace: ${_repo_count} repos discovered"
elif [ "${_repo_count}" -eq 1 ]; then
    echo "  ✓ Git safe.directory configured"
fi

# Validate .git-credentials mount
GIT_CRED="/root/.git-credentials"
if [ -d "${GIT_CRED}" ]; then
    echo "  ⚠ ${GIT_CRED} is a directory (host file missing?) — HTTPS push credentials unavailable"
    echo "    Set GIT_CREDENTIALS_PATH in .env to your credentials file, or leave unset to disable"
elif [ -f "${GIT_CRED}" ] && [ -s "${GIT_CRED}" ]; then
    echo "  ✓ Git credentials available (HTTPS push supported)"
fi

# Validate .gitconfig-work mount (optional secondary git identity)
GIT_WORK="/root/.gitconfig-work"
if [ -d "${GIT_WORK}" ]; then
    echo "  ⚠ ${GIT_WORK} is a directory (host file missing?) — work git identity unavailable"
    echo "    Set GIT_CONFIG_WORK_PATH in .env to your work config file, or leave unset to disable"
elif [ -f "${GIT_WORK}" ] && [ -s "${GIT_WORK}" ]; then
    echo "  ✓ Git work config mounted (conditional identity active)"
fi

# ─── Expose /workspace under $HOME for "Open project" dialog ──────
# The web UI searches $HOME for project directories. Inside Docker,
# /root only has dotfiles which are filtered out, so the dialog is
# empty. Symlinking repos into $HOME makes them discoverable.
if [ "${_repo_count}" -gt 1 ]; then
    # Multi-repo: symlink each sub-repo individually
    for _gitdir in "${_gitdirs[@]}"; do
        _repo_path="$(dirname "${_gitdir}")"
        _repo_name="$(basename "${_repo_path}")"
        if [ ! -e "${HOME}/${_repo_name}" ]; then
            ln -sf "${_repo_path}" "${HOME}/${_repo_name}"
        fi
    done
    echo "  ✓ Symlinked ${_repo_count} repos into ~/ for project discovery"
else
    # Single-repo: symlink /workspace itself
    WORKSPACE_NAME="$(basename "$(git -C /workspace rev-parse --show-toplevel 2>/dev/null || echo /workspace)")"
    if [ ! -e "${HOME}/${WORKSPACE_NAME}" ]; then
        ln -sf /workspace "${HOME}/${WORKSPACE_NAME}"
        echo "  ✓ Symlinked /workspace → ~/${WORKSPACE_NAME}"
    fi
fi
