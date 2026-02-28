#!/bin/bash
set -euo pipefail

# nmc-update — In-container updater for No More Configs
# Installed to /usr/local/bin/nmc-update by the Dockerfile.
# Fetches latest changes, pulls, and detects devcontainer rebuilds.

WORKSPACE="${CLAUDE_WORKSPACE:-/workspace}"
CACHE_DIR="${HOME}/.cache/nmc"
FLAG_FILE="${CACHE_DIR}/.update-available"

# ---------------------------------------------------------------------------
# ANSI colors — respects NO_COLOR (https://no-color.org)
# ---------------------------------------------------------------------------

if [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    BOLD="\033[1m"
    DIM="\033[2m"
    RESET="\033[0m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    CYAN="\033[36m"
    RED="\033[31m"
else
    BOLD="" DIM="" RESET="" GREEN="" YELLOW="" CYAN="" RED=""
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Files that users are expected to modify — not considered "dirty"
USER_FILES=("config.json" "secrets.json" "projects/")

has_tracked_changes() {
    local status
    status=$(git -C "$WORKSPACE" status --porcelain 2>/dev/null) || return 1
    [[ -z "$status" ]] && return 1

    while IFS= read -r line; do
        local file="${line:3}"
        local skip=false
        for uf in "${USER_FILES[@]}"; do
            if [[ "$file" == "$uf" || "$file" == "$uf"* ]]; then
                skip=true
                break
            fi
        done
        if [[ "$skip" == false ]]; then
            return 0
        fi
    done <<< "$status"
    return 1
}

read_version() {
    local changelog="${WORKSPACE}/CHANGELOG.md"
    if [[ -f "$changelog" ]]; then
        sed -n 's/^## \[\([0-9]*\.[0-9]*\.[0-9]*\)\].*/\1/p' "$changelog" | head -1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo -e "\n${CYAN}${BOLD}No More Configs${RESET} — updating\n"

cd "$WORKSPACE"

# 1. Save .devcontainer tree hash before pull
old_devcontainer_hash=$(git rev-parse HEAD:.devcontainer 2>/dev/null || echo "")
old_version=$(read_version)
old_version="${old_version:-unknown}"

# 2. Fetch
echo -e "${DIM}Fetching updates...${RESET}"
if ! git fetch origin 2>/dev/null; then
    echo -e "${RED}Fetch failed.${RESET} Check your network connection.\n"
    exit 1
fi

# 3. Check if already up to date
local_head=$(git rev-parse HEAD 2>/dev/null || echo "")
remote_head=$(git rev-parse origin/main 2>/dev/null || echo "")

if [[ -n "$local_head" && "$local_head" == "$remote_head" ]]; then
    echo -e "${GREEN}Already up to date.${RESET} (v${old_version})\n"
    rm -f "$FLAG_FILE"
    exit 0
fi

# 4. Warn about dirty working tree (but don't abort)
if has_tracked_changes; then
    echo -e "${YELLOW}Warning:${RESET} You have uncommitted changes to tracked NMC files."
    echo -e "${DIM}The pull may fail if there are conflicts. Commit or stash first if needed.${RESET}\n"
fi

# 5. Pull
echo -e "${DIM}Pulling changes...${RESET}"
if ! git pull origin main 2>/dev/null; then
    echo -e "${RED}Pull failed.${RESET}"
    echo -e "\n${YELLOW}Tip:${RESET} If you have local changes, try: git stash && nmc-update\n"
    exit 1
fi

new_version=$(read_version)
new_version="${new_version:-unknown}"

# 6. Compare .devcontainer tree hash
rebuild_needed=false
if [[ -n "$old_devcontainer_hash" ]]; then
    new_devcontainer_hash=$(git rev-parse HEAD:.devcontainer 2>/dev/null || echo "")
    if [[ "$old_devcontainer_hash" != "$new_devcontainer_hash" ]]; then
        rebuild_needed=true
    fi
fi

# 7. Summary
if [[ "$old_version" != "$new_version" ]]; then
    echo -e "\n${GREEN}${BOLD}Updated!${RESET} v${old_version} → ${BOLD}v${new_version}${RESET}"
else
    echo -e "\n${GREEN}${BOLD}Updated!${RESET} (v${new_version})"
fi

if [[ "$rebuild_needed" == true ]]; then
    echo -e "\n${YELLOW}${BOLD}Container rebuild needed${RESET} — devcontainer files changed."
    echo -e "\n${BOLD}Rebuild from inside VS Code:${RESET}"
    echo -e "  Ctrl+Shift+P → ${CYAN}Dev Containers: Rebuild Container${RESET}"
else
    echo -e "${DIM}No devcontainer changes — no rebuild needed.${RESET}"
fi

# 8. Clear update flag
rm -f "$FLAG_FILE"

echo ""
