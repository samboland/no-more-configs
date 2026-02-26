#!/bin/bash
set -euo pipefail

# install-agent-config.sh
# Reads config.json and secrets.json, hydrates templates, installs GSD framework,
# restores credentials, and prints a summary.
# Safe to run multiple times (naturally idempotent).

# Constants and paths
WORKSPACE_ROOT="/workspace"
CONFIG_FILE="$WORKSPACE_ROOT/config.json"
SECRETS_FILE="$WORKSPACE_ROOT/secrets.json"
AGENT_CONFIG_DIR="$WORKSPACE_ROOT/agent-config"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-/home/node/.claude}"
SETTINGS_TEMPLATE="$AGENT_CONFIG_DIR/settings.json.template"
MCP_TEMPLATES_DIR="$AGENT_CONFIG_DIR/mcp-templates"

# Source shared MCP helpers (TOML conversion, targeting)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-mcp.sh"

# JSON validation helper
validate_json() {
    local file="$1"
    local label="$2"
    if ! jq empty < "$file" &>/dev/null; then
        echo "[install] ERROR: $label is not valid JSON — skipping"
        return 1
    fi
    return 0
}

# JSON array membership helper
item_in_json_array() {
    local item="$1"
    local json_array="$2"
    jq -e --arg item "$item" 'index($item) != null' <<< "$json_array" >/dev/null 2>&1
}

# Install filters: empty arrays mean "install all"
should_install_skill() {
    local skill_name="$1"
    if [ "$SKILL_FILTER" = "[]" ]; then
        return 0
    fi
    item_in_json_array "$skill_name" "$SKILL_FILTER"
}

should_install_command() {
    local command_ref="$1"      # supports "name.md" or "namespace/name.md"
    local command_base="${command_ref##*/}"
    if [ "$COMMAND_FILTER" = "[]" ]; then
        return 0
    fi
    item_in_json_array "$command_ref" "$COMMAND_FILTER" || item_in_json_array "$command_base" "$COMMAND_FILTER"
}

# Copy a skill directory to Codex and ensure SKILL.md starts with YAML frontmatter.
copy_skill_dir_to_codex() {
    local src_skill_dir="$1"
    local skill_name
    local dst_skill_dir
    local dst_skill_file
    local tmp_file
    skill_name=$(basename "$src_skill_dir")
    dst_skill_dir="/home/node/.codex/skills/$skill_name"
    dst_skill_file="$dst_skill_dir/SKILL.md"

    rm -rf "$dst_skill_dir"
    mkdir -p "$dst_skill_dir"
    cp -r "$src_skill_dir"/. "$dst_skill_dir"/ 2>/dev/null || true

    if [ ! -f "$dst_skill_file" ]; then
        return 0
    fi

    if [ "$(head -n1 "$dst_skill_file" 2>/dev/null || true)" = "---" ]; then
        return 0
    fi

    tmp_file="$(mktemp)"
    {
        echo "---"
        echo "name: $skill_name"
        echo "description: Converted Claude skill for Codex compatibility."
        echo "---"
        echo ""
        cat "$dst_skill_file"
    } > "$tmp_file"
    mv "$tmp_file" "$dst_skill_file"
    echo "[install] Codex skill '$skill_name': added missing YAML frontmatter"
}

# Strip Claude-specific frontmatter keys from a command .md for Codex prompt format.
# Removes allowed-tools (multi-line YAML list or inline JSON array) and hide-from-slash-command-tool.
strip_allowed_tools_frontmatter() {
    local src="$1" dst="$2"
    if [ "$(head -n1 "$src" 2>/dev/null || true)" != "---" ]; then
        cp "$src" "$dst"; return 0
    fi
    awk '
        BEGIN { in_fm=0; skip_list=0 }
        NR==1 && /^---$/ { in_fm=1; print; next }
        in_fm && /^---$/ { in_fm=0; skip_list=0; print; next }
        in_fm && /^allowed-tools:/ { if (/\[/) next; skip_list=1; next }
        in_fm && skip_list && /^[[:space:]]+-/ { next }
        in_fm && skip_list { skip_list=0 }
        in_fm && /^hide-from-slash-command-tool:/ { next }
        { print }
    ' "$src" > "$dst"
}

# Append .codex/ to a project's .gitignore if not already present.
ensure_codex_gitignore() {
    local project_path="$1"
    # Only act on git repos
    [ -d "$project_path/.git" ] || return 0
    local gitignore="$project_path/.gitignore"
    if [ -f "$gitignore" ]; then
        # Handle both LF and CRLF line endings in grep match
        if ! grep -qP '^\.codex/\r?$' "$gitignore" 2>/dev/null; then
            # Ensure file ends with newline before appending
            [ -s "$gitignore" ] && [ "$(tail -c1 "$gitignore" | od -An -tx1 | tr -d ' ')" != "0a" ] && echo "" >> "$gitignore"
            echo '.codex/' >> "$gitignore"
        fi
    else
        echo '.codex/' > "$gitignore"
    fi
}

# Initialize counters for summary
CONFIG_STATUS="defaults — config.json not found"
SECRETS_STATUS="empty placeholders — secrets.json not found"
CREDS_STATUS="missing — manual login required"
CODEX_CREDS_STATUS="missing — manual login required"
GIT_IDENTITY_STATUS="not set"
CC_PREFS_STATUS="none"
MCP_COUNT=0
GSD_COMMANDS=0
GSD_AGENTS=0
COMMANDS_COUNT=0
SKILL_FILTER='[]'
COMMAND_FILTER='[]'
SKILL_FILTER_STATUS="all"
COMMAND_FILTER_STATUS="all"
PLUGIN_INSTALLED=0
PLUGIN_SKIPPED=0
PLUGIN_HOOKS='{}'
PLUGIN_ENV='{}'
PLUGIN_MCP='{}'
PLUGIN_WARNINGS=0
declare -a PLUGIN_WARNING_MESSAGES=()
CODEX_PROMPTS_COUNT=0
CODEX_CLONE_COUNT=0

# Load config.json (or use defaults)
if [ -f "$CONFIG_FILE" ]; then
    if validate_json "$CONFIG_FILE" "config.json"; then
        CONFIG_STATUS="loaded"
        EXTRA_DOMAINS=$(jq -r '.firewall.extra_domains // [] | join(" ")' "$CONFIG_FILE")
    else
        EXTRA_DOMAINS=""
    fi
else
    echo "[install] config.json not found — using defaults"
    EXTRA_DOMAINS=""
fi

# Optional install filters (config.json: agent.home_installs.skills / commands)
# Empty array or missing key means "install all".
if [ -f "$CONFIG_FILE" ] && validate_json "$CONFIG_FILE" "config.json"; then
    SKILL_FILTER=$(jq -c '.agent.home_installs.skills // []' "$CONFIG_FILE" 2>/dev/null || echo "[]")
    COMMAND_FILTER=$(jq -c '.agent.home_installs.commands // []' "$CONFIG_FILE" 2>/dev/null || echo "[]")

    if ! jq -e 'type == "array"' <<< "$SKILL_FILTER" >/dev/null 2>&1; then
        echo "[install] WARNING: agent.home_installs.skills must be an array — ignoring"
        SKILL_FILTER='[]'
    fi
    if ! jq -e 'type == "array"' <<< "$COMMAND_FILTER" >/dev/null 2>&1; then
        echo "[install] WARNING: agent.home_installs.commands must be an array — ignoring"
        COMMAND_FILTER='[]'
    fi

    SKILL_FILTER_LEN=$(jq 'length' <<< "$SKILL_FILTER" 2>/dev/null || echo 0)
    COMMAND_FILTER_LEN=$(jq 'length' <<< "$COMMAND_FILTER" 2>/dev/null || echo 0)
    if [ "$SKILL_FILTER_LEN" -gt 0 ]; then
        SKILL_FILTER_STATUS="$SKILL_FILTER_LEN selected"
    fi
    if [ "$COMMAND_FILTER_LEN" -gt 0 ]; then
        COMMAND_FILTER_STATUS="$COMMAND_FILTER_LEN selected"
    fi
fi

# Codex skip_dirs: project directory names where .codex cloning is disabled
CODEX_SKIP_DIRS='[]'
if [ -f "$CONFIG_FILE" ] && validate_json "$CONFIG_FILE" "config.json"; then
    CODEX_SKIP_DIRS=$(jq -c '.codex.skip_dirs // []' "$CONFIG_FILE" 2>/dev/null || echo "[]")
    if ! jq -e 'type == "array"' <<< "$CODEX_SKIP_DIRS" >/dev/null 2>&1; then
        echo "[install] WARNING: codex.skip_dirs must be an array — ignoring"
        CODEX_SKIP_DIRS='[]'
    fi
fi

# Load secrets.json (or use empty placeholders)
if [ -f "$SECRETS_FILE" ]; then
    if validate_json "$SECRETS_FILE" "secrets.json"; then
        SECRETS_STATUS="loaded"
    fi
else
    echo "[install] secrets.json not found — using empty placeholders"
fi

# Get MCP Gateway URL from environment or default
MCP_GATEWAY_URL="${MCP_GATEWAY_URL:-http://host.docker.internal:8811}"

# Generate firewall-domains.conf from config.json (GEN-01, GEN-02)
FIREWALL_CONF="$WORKSPACE_ROOT/.devcontainer/firewall-domains.conf"
CORE_DOMAINS=(
    # Package registries
    "registry.npmjs.org"
    "registry.npmjs.com"
    # Anthropic services
    "api.anthropic.com"
    "sentry.io"
    "statsig.anthropic.com"
    "statsig.com"
    # VS Code marketplace + extension CDN
    "marketplace.visualstudio.com"
    "gallerycdn.vsassets.io"
    "gallery.vsassets.io"
    "vsassets.io"
    "vscode.blob.core.windows.net"
    "update.code.visualstudio.com"
    # Azure Blob Storage (VS Code extensions, telemetry, results)
    "productionresultssa1.blob.core.windows.net"
    # Debian repositories
    "deb.debian.org"
    "security.debian.org"
    # GitHub (IP ranges handled separately by init-firewall.sh)
    "github.com"
    "objects.githubusercontent.com"
    "uploads.github.com"
    "codeload.github.com"
    # Cloudflare
    "api.cloudflare.com"
    "dash.cloudflare.com"
    "workers.dev"
    # Python packages
    "pypi.python.org"
    "pypi.org"
    "files.pythonhosted.org"
    # Other
    "storage.googleapis.com"
    "json.schemastore.org"
    # OpenAI — API, auth, and platform (Codex CLI + API usage)
    "api.openai.com"
    "auth.openai.com"
    "platform.openai.com"
    "chatgpt.com"
    # Google AI
    "generativelanguage.googleapis.com"
    # Amazon (Product Advertising API + product data)
    "api.amazon.com"
    "www.amazon.com"
    # Google Fonts
    "fonts.googleapis.com"
    "fonts.gstatic.com"
    # CDN
    "cdn.jsdelivr.net"
    # Vercel (Next.js deployment)
    "vercel.com"
    "api.vercel.com"
    "vercel.live"
    # Cloud Postgres providers (dashboard/API — add your DB endpoint to config.json extra_domains)
    "supabase.co"
    "supabase.com"
    "pooler.supabase.com"
    "neon.tech"
    "neon.com"
    "aivencloud.com"
)

{
    echo "# Generated by install-agent-config.sh — do not edit manually"
    echo "# Core domains (always present)"
    printf '%s\n' "${CORE_DOMAINS[@]}"
    echo ""
    echo "# Extra domains from config.json"
} > "$FIREWALL_CONF"

# Append extra_domains from config.json
if [ -f "$CONFIG_FILE" ]; then
    EXTRA_LIST=$(jq -r '.firewall.extra_domains // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    if [ -n "$EXTRA_LIST" ]; then
        echo "$EXTRA_LIST" >> "$FIREWALL_CONF"
    fi
fi

# Generate per-publisher VS Code CDN domains from devcontainer.json extensions
DEVCONTAINER_JSON="$WORKSPACE_ROOT/.devcontainer/devcontainer.json"
if [ -f "$DEVCONTAINER_JSON" ]; then
    PUBLISHERS=$(jq -r '.customizations.vscode.extensions // [] | .[] | split(".")[0]' "$DEVCONTAINER_JSON" 2>/dev/null | sort -u || true)
    if [ -n "$PUBLISHERS" ]; then
        {
            echo ""
            echo "# VS Code extension publisher CDN domains (auto-generated)"
            while IFS= read -r pub; do
                echo "${pub}.gallerycdn.vsassets.io"
                echo "${pub}.gallery.vsassets.io"
            done <<< "$PUBLISHERS"
        } >> "$FIREWALL_CONF"
    fi
fi

DOMAIN_COUNT=$(grep -c '^[^#]' "$FIREWALL_CONF" | tr -d '[:space:]')
echo "[install] Generated firewall-domains.conf with $DOMAIN_COUNT domain(s)"

# Generate .vscode/settings.json from config.json (GEN-03)
VSCODE_DIR="$WORKSPACE_ROOT/.vscode"
mkdir -p "$VSCODE_DIR"

# Read git scan paths from config.json
GIT_SCAN_PATHS='["."]'
if [ -f "$CONFIG_FILE" ]; then
    CONFIGURED_PATHS=$(jq -r '.vscode.git_scan_paths // []' "$CONFIG_FILE" 2>/dev/null || echo "[]")
    # If configured paths is non-empty array, use it; otherwise auto-detect
    PATH_COUNT=$(echo "$CONFIGURED_PATHS" | jq 'length' 2>/dev/null || echo "0")
    if [ "$PATH_COUNT" -gt 0 ]; then
        # User specified paths — prepend "." (workspace root) if not present
        GIT_SCAN_PATHS=$(echo "$CONFIGURED_PATHS" | jq '. as $paths | if (. | index(".")) then $paths else ["."] + $paths end')
    else
        # Auto-detect: find .git directories under projects/
        DETECTED='["."]'
        if [ -d "$WORKSPACE_ROOT/projects" ]; then
            for git_dir in "$WORKSPACE_ROOT/projects"/*/.git; do
                if [ -d "$git_dir" ]; then
                    project_name=$(basename "$(dirname "$git_dir")")
                    DETECTED=$(echo "$DETECTED" | jq --arg p "projects/$project_name" '. + [$p]')
                fi
            done
        fi
        GIT_SCAN_PATHS="$DETECTED"
    fi
fi

jq -n --argjson paths "$GIT_SCAN_PATHS" '{"git.scanRepositories": $paths}' > "$VSCODE_DIR/settings.json"
echo "[install] Generated .vscode/settings.json with $(echo "$GIT_SCAN_PATHS" | jq 'length') scan path(s)"

# Create directories (idempotent)
mkdir -p "$CLAUDE_DIR/skills"
mkdir -p "$CLAUDE_DIR/hooks"
mkdir -p "$CLAUDE_DIR/agents"
mkdir -p "$CLAUDE_DIR/commands"
mkdir -p /home/node/.codex
mkdir -p /home/node/.codex/prompts

# Resolve Codex model (config.toml generated after plugin loop to include MCP servers)
CODEX_MODEL="gpt-5.3-codex"
if [ -f "$CONFIG_FILE" ]; then
    CONFIGURED_MODEL=$(jq -r '.codex.model // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [ -n "$CONFIGURED_MODEL" ]; then
        CODEX_MODEL="$CONFIGURED_MODEL"
    fi
fi

# Copy skills from agent-config to runtime location (AGT-03) - Cross-agent support
SKILLS_COUNT=0
if [ -d "$AGENT_CONFIG_DIR/skills" ]; then
    # Create Codex skills directory
    mkdir -p /home/node/.codex/skills

    # Copy selected skill directories to both Claude and Codex
    for skill_dir in "$AGENT_CONFIG_DIR/skills"/*/; do
        [ -d "$skill_dir" ] || continue
        skill_name=$(basename "$skill_dir")
        if ! should_install_skill "$skill_name"; then
            continue
        fi
        cp -r "$skill_dir" "$CLAUDE_DIR/skills/"
        copy_skill_dir_to_codex "$skill_dir"
        SKILLS_COUNT=$((SKILLS_COUNT + 1))
    done

    echo "[install] Skills: $SKILLS_COUNT skill(s) -> Claude + Codex"
fi

# Copy hooks from agent-config to runtime location (AGT-04)
HOOKS_COUNT=0
if [ -d "$AGENT_CONFIG_DIR/hooks" ]; then
    cp "$AGENT_CONFIG_DIR/hooks/"* "$CLAUDE_DIR/hooks/" 2>/dev/null || true
    HOOKS_COUNT=$(find "$AGENT_CONFIG_DIR/hooks" -maxdepth 1 -type f 2>/dev/null | wc -l)
    echo "[install] Copied $HOOKS_COUNT hook(s) to $CLAUDE_DIR/hooks/"
fi

# Clean and recreate Codex prompts directory (idempotent across re-runs)
rm -rf /home/node/.codex/prompts && mkdir -p /home/node/.codex/prompts

# Copy standalone commands from agent-config to runtime location
COMMANDS_COUNT=0
if [ -d "$AGENT_CONFIG_DIR/commands" ]; then
    for cmd_file in "$AGENT_CONFIG_DIR/commands/"*.md; do
        # Skip if no .md files exist
        [ -f "$cmd_file" ] || continue

        # Get filename
        cmd_name=$(basename "$cmd_file")

        # Protect GSD namespace (unlikely but safety check)
        if [ "$cmd_name" = "gsd" ]; then
            echo "[install] WARNING: Skipping standalone command 'gsd' (reserved for GSD framework)"
            continue
        fi

        if ! should_install_command "$cmd_name"; then
            continue
        fi

        # Copy to commands directory
        cp "$cmd_file" "$CLAUDE_DIR/commands/"
        strip_allowed_tools_frontmatter "$cmd_file" "/home/node/.codex/prompts/$cmd_name"
        CODEX_PROMPTS_COUNT=$((CODEX_PROMPTS_COUNT + 1))
        COMMANDS_COUNT=$((COMMANDS_COUNT + 1))
    done
    if [ $COMMANDS_COUNT -gt 0 ]; then
        echo "[install] Commands: $COMMANDS_COUNT standalone command(s)"
    fi
fi

# Hydrate settings template (merged into settings.json later, after GSD install)
if [ -f "$SETTINGS_TEMPLATE" ]; then
    HYDRATED_SETTINGS=$(cat "$SETTINGS_TEMPLATE")
    echo "[install] Loaded settings template (will merge into settings.json)"
else
    HYDRATED_SETTINGS='{}'
    echo "[install] WARNING: settings.json.template not found — skipping settings generation"
fi

# Seed settings.json with permissions so GSD installer has a valid file to merge into.
# Final settings enforcement happens AFTER GSD installation (which modifies this file).
if [ ! -f "$CLAUDE_DIR/settings.json" ]; then
    jq -n '{"permissions":{"allow":[],"deny":[],"additionalDirectories":[],"defaultMode":"bypassPermissions"}}' \
        > "$CLAUDE_DIR/settings.json"
fi

# --- Download upstream plugins (if not already present) ---
UPSTREAM_REPO="https://github.com/anthropics/claude-code.git"
UPSTREAM_PLUGINS=("plugin-dev" "frontend-design")
UPSTREAM_SPARSE_PATHS=()
UPSTREAM_NEEDED=()

for up_name in "${UPSTREAM_PLUGINS[@]}"; do
    if [ -d "$AGENT_CONFIG_DIR/plugins/$up_name" ]; then
        echo "[install] Upstream plugin '$up_name': already present, skipping download"
    else
        UPSTREAM_SPARSE_PATHS+=("plugins/$up_name")
        UPSTREAM_NEEDED+=("$up_name")
    fi
done

UPSTREAM_STATUS="present"
if [ ${#UPSTREAM_NEEDED[@]} -gt 0 ]; then
    UPSTREAM_TMP=$(mktemp -d)
    echo "[install] Downloading upstream plugins: ${UPSTREAM_NEEDED[*]}"
    if git clone --depth 1 --filter=blob:none --sparse "$UPSTREAM_REPO" "$UPSTREAM_TMP" 2>/dev/null; then
        ( cd "$UPSTREAM_TMP" && git sparse-checkout set "${UPSTREAM_SPARSE_PATHS[@]}" 2>/dev/null )
        for up_name in "${UPSTREAM_NEEDED[@]}"; do
            if [ -d "$UPSTREAM_TMP/plugins/$up_name" ]; then
                cp -r "$UPSTREAM_TMP/plugins/$up_name" "$AGENT_CONFIG_DIR/plugins/$up_name"
                echo "[install] Upstream plugin '$up_name': downloaded"
            else
                echo "[install] WARNING: Upstream plugin '$up_name' not found in repo"
            fi
        done
        UPSTREAM_STATUS="downloaded ${UPSTREAM_NEEDED[*]}"
    else
        echo "[install] WARNING: Could not reach GitHub — upstream plugins unavailable"
        UPSTREAM_STATUS="failed (GitHub unreachable)"
    fi
    rm -rf "$UPSTREAM_TMP"
fi

# --- Plugin Installation ---
declare -A PLUGIN_FILE_OWNERS=()
declare -a PLUGIN_DETAIL_LINES=()
if [ -d "$AGENT_CONFIG_DIR/plugins" ]; then
    for plugin_dir in "$AGENT_CONFIG_DIR/plugins"/*/; do
        # Guard against empty directory
        [ -d "$plugin_dir" ] || continue

        plugin_name=$(basename "$plugin_dir")
        MANIFEST="$plugin_dir/plugin.json"

        # Reset per-plugin counters
        plugin_skills=0
        plugin_hooks_count=0
        plugin_cmds=0
        plugin_agents=0

        # Check if plugin is enabled in config.json (default: true)
        plugin_enabled="true"
        if [ -f "$CONFIG_FILE" ]; then
            plugin_enabled=$(jq -r --arg name "$plugin_name" '.plugins[$name].enabled // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
        fi

        # Skip if disabled
        if [ "$plugin_enabled" = "false" ]; then
            echo "[install] Plugin '$plugin_name': skipped (disabled)"
            PLUGIN_SKIPPED=$((PLUGIN_SKIPPED + 1))
            continue
        fi

        # Validate plugin.json exists
        if [ ! -f "$MANIFEST" ]; then
            echo "[install] Plugin '$plugin_name': skipped (no plugin.json)"
            PLUGIN_SKIPPED=$((PLUGIN_SKIPPED + 1))
            continue
        fi

        # Validate plugin.json is valid JSON (VAL-04: friendly error + parse details)
        if ! jq empty < "$MANIFEST" &>/dev/null; then
            local parse_error
            parse_error=$(jq empty < "$MANIFEST" 2>&1 || true)
            echo "[install] ERROR: Plugin '$plugin_name' has invalid plugin.json"
            echo "[install]   $parse_error"
            PLUGIN_WARNINGS=$((PLUGIN_WARNINGS + 1))
            PLUGIN_WARNING_MESSAGES+=("Plugin '$plugin_name': invalid plugin.json — $parse_error")
            PLUGIN_SKIPPED=$((PLUGIN_SKIPPED + 1))
            continue
        fi

        # Validate plugin name matches directory name
        manifest_name=$(jq -r '.name // ""' "$MANIFEST" 2>/dev/null)
        if [ "$manifest_name" != "$plugin_name" ]; then
            echo "[install] WARNING: Plugin '$plugin_name' manifest name '$manifest_name' does not match directory name — skipping"
            PLUGIN_WARNINGS=$((PLUGIN_WARNINGS + 1))
            PLUGIN_WARNING_MESSAGES+=("Plugin '$plugin_name': manifest name '$manifest_name' does not match directory name")
            PLUGIN_SKIPPED=$((PLUGIN_SKIPPED + 1))
            continue
        fi

        # Plugin is valid and enabled — proceed to file copying

        # Validate hook scripts exist in plugin directory (VAL-01)
        MANIFEST_HOOK_CHECK=$(jq -r '.hooks // {}' "$MANIFEST" 2>/dev/null || echo "{}")
        if [ "$MANIFEST_HOOK_CHECK" != "{}" ] && [ "$MANIFEST_HOOK_CHECK" != "null" ]; then
            hook_valid=true
            hook_commands=$(echo "$MANIFEST_HOOK_CHECK" | jq -r '.[][] | select(.type == "command") | .command' 2>/dev/null || true)
            for hook_cmd in $hook_commands; do
                # Extract script path from command (handles: python3 /path/to/script.py)
                hook_script=$(echo "$hook_cmd" | awk '{for(i=1;i<=NF;i++) if($i ~ /\.py$|\.sh$/) print $i}')
                if [ -n "$hook_script" ]; then
                    hook_basename=$(basename "$hook_script")
                    if [ ! -f "$plugin_dir/hooks/$hook_basename" ]; then
                        echo "[install] WARNING: Plugin '$plugin_name' hook references non-existent script: $hook_basename"
                        PLUGIN_WARNINGS=$((PLUGIN_WARNINGS + 1))
                        PLUGIN_WARNING_MESSAGES+=("Plugin '$plugin_name': hook script missing — $hook_basename")
                        hook_valid=false
                    fi
                fi
            done
            if [ "$hook_valid" = false ]; then
                echo "[install] Plugin '$plugin_name': skipped (missing hook script)"
                PLUGIN_SKIPPED=$((PLUGIN_SKIPPED + 1))
                continue
            fi
        fi

        # Copy skills (cross-agent: Claude + Codex)
        if [ -d "$plugin_dir/skills" ]; then
            for skill_dir in "$plugin_dir/skills"/*/; do
                [ -d "$skill_dir" ] || continue
                skill_name=$(basename "$skill_dir")
                if ! should_install_skill "$skill_name"; then
                    continue
                fi
                cp -r "$skill_dir" "$CLAUDE_DIR/skills/"
                copy_skill_dir_to_codex "$skill_dir"
                plugin_skills=$((plugin_skills + 1))
            done
        fi

        # Copy hooks (with overwrite detection)
        if [ -d "$plugin_dir/hooks" ]; then
            for hook_file in "$plugin_dir/hooks"/*; do
                [ -f "$hook_file" ] || continue
                hook_basename=$(basename "$hook_file")
                if [ -n "${PLUGIN_FILE_OWNERS[hooks/$hook_basename]+x}" ]; then
                    echo "[install] WARNING: Plugin '$plugin_name' hook file '$hook_basename' conflicts with plugin '${PLUGIN_FILE_OWNERS[hooks/$hook_basename]}' — skipping file"
                    PLUGIN_WARNINGS=$((PLUGIN_WARNINGS + 1))
                    PLUGIN_WARNING_MESSAGES+=("Plugin '$plugin_name': hook file '$hook_basename' conflicts with '${PLUGIN_FILE_OWNERS[hooks/$hook_basename]}'")
                else
                    PLUGIN_FILE_OWNERS["hooks/$hook_basename"]="$plugin_name"
                    cp "$hook_file" "$CLAUDE_DIR/hooks/"
                fi
            done
            plugin_hooks_count=$(find "$plugin_dir/hooks" -maxdepth 1 -type f 2>/dev/null | wc -l)
        fi

        # Copy commands (with GSD protection and overwrite detection)
        if [ -d "$plugin_dir/commands" ]; then
            # Check for GSD directory conflict
            if [ -d "$plugin_dir/commands/gsd" ]; then
                echo "[install] ERROR: Plugin '$plugin_name' attempted to overwrite GSD-protected directory commands/gsd/ -- skipping"
                PLUGIN_WARNINGS=$((PLUGIN_WARNINGS + 1))
                PLUGIN_WARNING_MESSAGES+=("Plugin '$plugin_name': GSD-protected commands/gsd/ directory")
            fi
            # Copy flat command files
            for cmd_file in "$plugin_dir/commands"/*.md; do
                [ -f "$cmd_file" ] || continue
                cmd_basename=$(basename "$cmd_file")
                if ! should_install_command "$cmd_basename"; then
                    continue
                fi
                if [ -n "${PLUGIN_FILE_OWNERS[commands/$cmd_basename]+x}" ]; then
                    echo "[install] WARNING: Plugin '$plugin_name' command '$cmd_basename' conflicts with plugin '${PLUGIN_FILE_OWNERS[commands/$cmd_basename]}' — skipping file"
                    PLUGIN_WARNINGS=$((PLUGIN_WARNINGS + 1))
                    PLUGIN_WARNING_MESSAGES+=("Plugin '$plugin_name': command '$cmd_basename' conflicts with '${PLUGIN_FILE_OWNERS[commands/$cmd_basename]}'")
                else
                    PLUGIN_FILE_OWNERS["commands/$cmd_basename"]="$plugin_name"
                    cp "$cmd_file" "$CLAUDE_DIR/commands/"
                    mkdir -p /home/node/.codex/prompts
                    strip_allowed_tools_frontmatter "$cmd_file" "/home/node/.codex/prompts/$cmd_basename"
                    CODEX_PROMPTS_COUNT=$((CODEX_PROMPTS_COUNT + 1))
                    plugin_cmds=$((plugin_cmds + 1))
                fi
            done
            # Copy namespaced command subdirectories (commands/<namespace>/*.md → <namespace>:cmd)
            for cmd_subdir in "$plugin_dir/commands"/*/; do
                [ -d "$cmd_subdir" ] || continue
                subdir_name=$(basename "$cmd_subdir")
                [ "$subdir_name" = "gsd" ] && continue  # GSD-protected
                mkdir -p "$CLAUDE_DIR/commands/$subdir_name"
                for cmd_file in "$cmd_subdir"*.md; do
                    [ -f "$cmd_file" ] || continue
                    cmd_basename=$(basename "$cmd_file")
                    cmd_ref="$subdir_name/$cmd_basename"
                    if ! should_install_command "$cmd_ref"; then
                        continue
                    fi
                    cp "$cmd_file" "$CLAUDE_DIR/commands/$subdir_name/"
                    mkdir -p "/home/node/.codex/prompts/$subdir_name"
                    strip_allowed_tools_frontmatter "$cmd_file" "/home/node/.codex/prompts/$subdir_name/$cmd_basename"
                    CODEX_PROMPTS_COUNT=$((CODEX_PROMPTS_COUNT + 1))
                    plugin_cmds=$((plugin_cmds + 1))
                done
            done
        fi

        # Copy agents (with GSD protection and overwrite detection)
        if [ -d "$plugin_dir/agents" ]; then
            for agent_file in "$plugin_dir/agents"/*.md; do
                [ -f "$agent_file" ] || continue
                agent_name=$(basename "$agent_file")
                if [[ "$agent_name" =~ ^gsd- ]]; then
                    echo "[install] ERROR: Plugin '$plugin_name' attempted to overwrite GSD-protected file agents/$agent_name -- skipping"
                    PLUGIN_WARNINGS=$((PLUGIN_WARNINGS + 1))
                    PLUGIN_WARNING_MESSAGES+=("Plugin '$plugin_name': GSD-protected agents/$agent_name")
                    continue
                fi
                if [ -n "${PLUGIN_FILE_OWNERS[agents/$agent_name]+x}" ]; then
                    echo "[install] WARNING: Plugin '$plugin_name' agent '$agent_name' conflicts with plugin '${PLUGIN_FILE_OWNERS[agents/$agent_name]}' — skipping file"
                    PLUGIN_WARNINGS=$((PLUGIN_WARNINGS + 1))
                    PLUGIN_WARNING_MESSAGES+=("Plugin '$plugin_name': agent '$agent_name' conflicts with '${PLUGIN_FILE_OWNERS[agents/$agent_name]}'")
                else
                    PLUGIN_FILE_OWNERS["agents/$agent_name"]="$plugin_name"
                    cp "$agent_file" "$CLAUDE_DIR/agents/"
                fi
            done
            plugin_agents=$(find "$plugin_dir/agents" -maxdepth 1 -name "*.md" -type f 2>/dev/null | wc -l)
        fi

        # Accumulate hook registrations
        MANIFEST_HOOKS=$(jq -r '.hooks // {}' "$MANIFEST" 2>/dev/null)
        if [ "$MANIFEST_HOOKS" != "{}" ] && [ "$MANIFEST_HOOKS" != "null" ]; then
            PLUGIN_HOOKS=$(jq -n --argjson acc "$PLUGIN_HOOKS" --argjson new "$MANIFEST_HOOKS" '
                $new | to_entries | reduce .[] as $entry ($acc;
                    .[$entry.key] = ((.[$entry.key] // []) + $entry.value)
                )
            ' 2>/dev/null || echo "$PLUGIN_HOOKS")
        fi

        # Accumulate environment variables with conflict detection
        MANIFEST_ENV=$(jq -r '.env // {}' "$MANIFEST" 2>/dev/null)
        if [ "$MANIFEST_ENV" != "{}" ] && [ "$MANIFEST_ENV" != "null" ]; then
            # Hydrate {{TOKEN}} placeholders in this plugin's env from secrets.json
            if [ -f "$SECRETS_FILE" ]; then
                env_tokens=$(echo "$MANIFEST_ENV" | grep -oP '\{\{[A-Z_]+\}\}' | sort -u || true)
                for token_pattern in $env_tokens; do
                    token_name=$(echo "$token_pattern" | sed 's/{{//;s/}}//')
                    # Namespaced lookup: secrets.json[plugin-name][TOKEN]
                    secret_value=$(jq -r --arg p "$plugin_name" --arg k "$token_name" \
                        '.[$p][$k] // ""' "$SECRETS_FILE" 2>/dev/null || echo "")
                    if [ -n "$secret_value" ]; then
                        MANIFEST_ENV=$(echo "$MANIFEST_ENV" | jq --arg token "$token_pattern" --arg value "$secret_value" \
                            'to_entries | map(if .value == $token then .value = $value else . end) | from_entries' 2>/dev/null || echo "$MANIFEST_ENV")
                    fi
                done
            fi

            # Check for unresolved {{TOKEN}} patterns in plugin env (empty after hydration)
            unresolved_env=$(echo "$MANIFEST_ENV" | jq -r 'to_entries[] | select(.value | test("^\\{\\{.*\\}\\}$")) | .key' 2>/dev/null || true)
            if [ -n "$unresolved_env" ]; then
                for unresolved_var in $unresolved_env; do
                    echo "[install] WARNING: Plugin '$plugin_name' env var '$unresolved_var' has unresolved placeholder"
                    PLUGIN_WARNINGS=$((PLUGIN_WARNINGS + 1))
                    PLUGIN_WARNING_MESSAGES+=("Plugin '$plugin_name': env var '$unresolved_var' has unresolved {{TOKEN}} placeholder")
                done
            fi

            # Check for conflicts: any key in MANIFEST_ENV that already exists in PLUGIN_ENV
            CONFLICTS=$(jq -n --argjson existing "$PLUGIN_ENV" --argjson new "$MANIFEST_ENV" '
                [$new | keys[] | select(. as $k | $existing | has($k))]
            ' 2>/dev/null)
            if [ "$CONFLICTS" != "[]" ] && [ -n "$CONFLICTS" ]; then
                echo "[install] WARNING: Plugin '$plugin_name' env var conflict: $CONFLICTS -- using earlier plugin's values"
                PLUGIN_WARNINGS=$((PLUGIN_WARNINGS + 1))
                PLUGIN_WARNING_MESSAGES+=("Plugin '$plugin_name': env var conflict: $CONFLICTS (first plugin wins)")
                # Only add non-conflicting keys
                PLUGIN_ENV=$(jq -n --argjson existing "$PLUGIN_ENV" --argjson new "$MANIFEST_ENV" '
                    $existing + ($new | to_entries | map(select(.key as $k | $existing | has($k) | not)) | from_entries)
                ' 2>/dev/null || echo "$PLUGIN_ENV")
            else
                PLUGIN_ENV=$(jq -n --argjson existing "$PLUGIN_ENV" --argjson new "$MANIFEST_ENV" '
                    $existing + $new
                ' 2>/dev/null || echo "$PLUGIN_ENV")
            fi

            # Apply config.json overrides (always take precedence)
            if [ -f "$CONFIG_FILE" ]; then
                CONFIG_ENV_OVERRIDES=$(jq -r --arg name "$plugin_name" '.plugins[$name].env // {}' "$CONFIG_FILE" 2>/dev/null || echo "{}")
                if [ "$CONFIG_ENV_OVERRIDES" != "{}" ]; then
                    PLUGIN_ENV=$(jq -n --argjson existing "$PLUGIN_ENV" --argjson overrides "$CONFIG_ENV_OVERRIDES" '
                        $existing * $overrides
                    ' 2>/dev/null || echo "$PLUGIN_ENV")
                fi
            fi
        fi

        # Accumulate MCP servers with source tagging
        MANIFEST_MCP=$(jq -r '.mcp_servers // {}' "$MANIFEST" 2>/dev/null || echo "{}")
        if [ "$MANIFEST_MCP" != "{}" ] && [ "$MANIFEST_MCP" != "null" ]; then
            # Tag each server with _source for traceability
            TAGGED_MCP=$(echo "$MANIFEST_MCP" | jq --arg plugin "$plugin_name" '
                to_entries | map(.value._source = "plugin:\($plugin)") | from_entries
            ' 2>/dev/null || echo "{}")
            if [ "$TAGGED_MCP" != "{}" ]; then
                PLUGIN_MCP=$(jq -n --argjson acc "$PLUGIN_MCP" --argjson new "$TAGGED_MCP" \
                    '$acc * $new' 2>/dev/null || echo "$PLUGIN_MCP")
            fi
        fi

        # Per-plugin detail logging
        detail_parts=()
        [ "${plugin_skills:-0}" -gt 0 ] && detail_parts+=("${plugin_skills} skill(s)")
        [ "${plugin_hooks_count:-0}" -gt 0 ] && detail_parts+=("${plugin_hooks_count} hook(s)")
        [ "${plugin_cmds:-0}" -gt 0 ] && detail_parts+=("${plugin_cmds} command(s)")
        [ "${plugin_agents:-0}" -gt 0 ] && detail_parts+=("${plugin_agents} agent(s)")

        # Count env vars from this plugin's manifest
        plugin_env_count=$(jq -r '.env // {} | length' "$MANIFEST" 2>/dev/null || echo "0")
        [ "$plugin_env_count" -gt 0 ] && detail_parts+=("${plugin_env_count} env var(s)")

        # Count MCP servers from this plugin's manifest
        plugin_mcp_count=$(echo "$MANIFEST_MCP" | jq 'if . == {} or . == null then 0 else length end' 2>/dev/null || echo "0")
        [ "$plugin_mcp_count" -gt 0 ] && detail_parts+=("${plugin_mcp_count} MCP server(s)")

        detail_str=$(IFS=", "; echo "${detail_parts[*]}")
        if [ -n "$detail_str" ]; then
            echo "[install] Plugin '$plugin_name': installed ($detail_str)"
            PLUGIN_DETAIL_LINES+=("  $plugin_name: $detail_str")
        else
            echo "[install] Plugin '$plugin_name': installed (manifest only)"
            PLUGIN_DETAIL_LINES+=("  $plugin_name: manifest only")
        fi
        PLUGIN_INSTALLED=$((PLUGIN_INSTALLED + 1))

    done

    # Log plugin installation summary
    echo "[install] Plugins: $PLUGIN_INSTALLED installed, $PLUGIN_SKIPPED skipped"
fi

# --- Plugin registrations are merged into settings.json after GSD install ---

# (Old plugin recap removed — details integrated into final summary)

# Generate Codex CLI config.toml (after plugin loop so MCP servers are available)
CODEX_MCP_COUNT=0
CODEX_TOML="/home/node/.codex/config.toml"
{
    echo "# Generated by install-agent-config.sh — do not edit manually"
    echo "model = \"$CODEX_MODEL\""
    echo 'cli_auth_credentials_store = "file"'
    echo 'approval_policy = "never"'
    echo 'sandbox_mode = "danger-full-access"'
    echo ""
    echo '[features]'
    echo 'skills = true'
    echo ""
    echo '[projects."/workspace"]'
    echo 'trust_level = "trusted"'
    echo ""
    echo "# --- MCP servers (auto-generated) ---"

    # Add template-based MCP servers targeting Codex
    if [ -f "$CONFIG_FILE" ]; then
        ENABLED_CODEX_SERVERS=$(jq -r '.mcp_servers | to_entries[] | select(.value.enabled == true) | .key' "$CONFIG_FILE" 2>/dev/null || echo "")
        if [ -n "$ENABLED_CODEX_SERVERS" ]; then
            for SERVER in $ENABLED_CODEX_SERVERS; do
                SERVER_CONFIG=$(jq --arg s "$SERVER" '.mcp_servers[$s]' "$CONFIG_FILE" 2>/dev/null || echo '{}')
                if ! server_targets_agent "codex" "$SERVER_CONFIG"; then
                    continue
                fi
                TEMPLATE_FILE="$MCP_TEMPLATES_DIR/${SERVER}.json"
                if [ -f "$TEMPLATE_FILE" ]; then
                    HYDRATED=$(sed "s|{{MCP_GATEWAY_URL}}|$MCP_GATEWAY_URL|g" "$TEMPLATE_FILE")
                    json_mcp_to_toml "$SERVER" "$HYDRATED"
                    CODEX_MCP_COUNT=$((CODEX_MCP_COUNT + 1))
                fi
            done
        fi
    fi

    # Add Codex-targeted plugin MCP servers (hydrated)
    if [ "$PLUGIN_MCP" != "{}" ]; then
        PLUGIN_MCP_KEYS=$(echo "$PLUGIN_MCP" | jq -r 'keys[]' 2>/dev/null || true)
        for mcp_key in $PLUGIN_MCP_KEYS; do
            MCP_SERVER_JSON=$(echo "$PLUGIN_MCP" | jq --arg k "$mcp_key" '.[$k]' 2>/dev/null)
            # Check targets (default: both agents)
            if ! server_targets_agent "codex" "$MCP_SERVER_JSON"; then
                continue
            fi
            # Hydrate tokens from secrets.json
            p_name=$(echo "$MCP_SERVER_JSON" | jq -r '._source // "" | sub("^plugin:"; "")' 2>/dev/null || echo "")
            if [ -n "$p_name" ] && [ -f "$SECRETS_FILE" ]; then
                server_tokens=$(echo "$MCP_SERVER_JSON" | grep -oP '\{\{[A-Z_]+\}\}' | sort -u || true)
                for token_pattern in $server_tokens; do
                    token_name=$(echo "$token_pattern" | sed 's/{{//;s/}}//')
                    secret_value=$(jq -r --arg p "$p_name" --arg k "$token_name" \
                        '.[$p][$k] // ""' "$SECRETS_FILE" 2>/dev/null || echo "")
                    if [ -n "$secret_value" ]; then
                        MCP_SERVER_JSON=$(echo "$MCP_SERVER_JSON" | jq --arg token "$token_pattern" --arg value "$secret_value" \
                            'walk(if type == "string" then gsub($token; $value) else . end)')
                    fi
                done
            fi
            # Strip internal fields before TOML conversion
            CLEAN_JSON=$(echo "$MCP_SERVER_JSON" | jq 'del(._source, .targets)')
            json_mcp_to_toml "$mcp_key" "$CLEAN_JSON"
            CODEX_MCP_COUNT=$((CODEX_MCP_COUNT + 1))
        done
    fi

    echo "# --- end MCP servers ---"
} > "$CODEX_TOML"

if [ "$CODEX_MCP_COUNT" -gt 0 ]; then
    echo "[install] Generated Codex config.toml (model: $CODEX_MODEL, $CODEX_MCP_COUNT MCP server(s))"
else
    echo "[install] Generated Codex config.toml (model: $CODEX_MODEL)"
fi

# Restore Claude credentials (if available)
if [ -f "$SECRETS_FILE" ]; then
    CLAUDE_CREDS=$(jq -e '.claude.credentials // {}' "$SECRETS_FILE" 2>/dev/null || echo "{}")
    # Check if credentials object is non-empty
    if [ "$CLAUDE_CREDS" != "{}" ] && [ "$CLAUDE_CREDS" != "null" ]; then
        echo "$CLAUDE_CREDS" > "$CLAUDE_DIR/.credentials.json"
        chmod 600 "$CLAUDE_DIR/.credentials.json"
        CREDS_STATUS="restored"
        echo "[install] Claude credentials restored"

        # Mark onboarding complete, dismiss effort callout, prevent VS Code extension auto-install
        CLAUDE_JSON="/home/node/.claude.json"
        if [ ! -f "$CLAUDE_JSON" ]; then
            jq -n '{
                "hasCompletedOnboarding": true,
                "theme": "dark",
                "effortCalloutDismissed": true,
                "officialMarketplaceAutoInstallAttempted": true,
                "officialMarketplaceAutoInstalled": true,
                "hasIdeOnboardingBeenShown": {"vscode": true}
            }' > "$CLAUDE_JSON"
        else
            jq '.hasCompletedOnboarding = true | .effortCalloutDismissed = true | .officialMarketplaceAutoInstallAttempted = true | .officialMarketplaceAutoInstalled = true | .hasIdeOnboardingBeenShown.vscode = true' \
                "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" \
                && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
        fi

        # Restore Claude Code user preferences from config.json (saved by save-config.sh)
        CC_PREFS='{}'
        if [ -f "$CONFIG_FILE" ]; then
            CC_PREFS=$(jq -r '.claude_code // {}' "$CONFIG_FILE" 2>/dev/null || echo "{}")
        fi
        if [ "$CC_PREFS" != "{}" ] && [ "$CC_PREFS" != "null" ]; then
            jq --argjson prefs "$CC_PREFS" '. + $prefs' \
                "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" \
                && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
            CC_PREF_KEYS=$(echo "$CC_PREFS" | jq -r 'keys | join(", ")' 2>/dev/null || echo "")
            CC_PREFS_STATUS="restored ($CC_PREF_KEYS)"
            echo "[install] Claude Code preferences restored: $CC_PREF_KEYS"
        fi
    else
        echo "[install] Claude credentials not found — manual login required after first start"
    fi
else
    echo "[install] Claude credentials not found — manual login required after first start"
fi

# Restore Codex CLI credentials (if available)
if [ -f "$SECRETS_FILE" ]; then
    CODEX_AUTH=$(jq -e '.codex.auth // {}' "$SECRETS_FILE" 2>/dev/null || echo "{}")
    if [ "$CODEX_AUTH" != "{}" ] && [ "$CODEX_AUTH" != "null" ]; then
        echo "$CODEX_AUTH" > /home/node/.codex/auth.json
        chmod 600 /home/node/.codex/auth.json
        CODEX_CREDS_STATUS="restored"
        echo "[install] Codex credentials restored"
    else
        echo "[install] Codex credentials not found — manual login required after first start"
    fi
else
    echo "[install] Codex credentials not found — manual login required after first start"
fi

# Restore GitHub CLI credentials from secrets.json
if [ -f "$SECRETS_FILE" ]; then
    GH_TOKEN=$(jq -r '.gh.oauth_token // ""' "$SECRETS_FILE" 2>/dev/null || echo "")
    GH_USER=$(jq -r '.gh.user // ""' "$SECRETS_FILE" 2>/dev/null || echo "")
    GH_PROTO=$(jq -r '.gh.git_protocol // "https"' "$SECRETS_FILE" 2>/dev/null || echo "https")
    if [ -n "$GH_TOKEN" ]; then
        mkdir -p /home/node/.config/gh
        cat > /home/node/.config/gh/hosts.yml << GHEOF
github.com:
    oauth_token: $GH_TOKEN
    user: $GH_USER
    git_protocol: $GH_PROTO
GHEOF
        chmod 600 /home/node/.config/gh/hosts.yml
        echo "[install] GitHub CLI credentials restored ($GH_USER)"
    else
        echo "[install] GitHub CLI credentials not found — run 'gh auth login' to authenticate"
    fi
fi

# Restore npm credentials from secrets.json
if [ -f "$SECRETS_FILE" ]; then
    NPM_TOKEN=$(jq -r '.npm.auth_token // ""' "$SECRETS_FILE" 2>/dev/null || echo "")
    if [ -n "$NPM_TOKEN" ]; then
        echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > /home/node/.npmrc
        chmod 600 /home/node/.npmrc
        echo "[install] npm credentials restored"
    else
        echo "[install] npm credentials not found — run 'npm login' to authenticate"
    fi
fi

# Restore git identity from secrets.json
if [ -f "$SECRETS_FILE" ]; then
    GIT_NAME=$(jq -r '.git.name // ""' "$SECRETS_FILE" 2>/dev/null || echo "")
    GIT_EMAIL=$(jq -r '.git.email // ""' "$SECRETS_FILE" 2>/dev/null || echo "")
    if [ -n "$GIT_NAME" ] && [ -n "$GIT_EMAIL" ]; then
        git config --global user.name "$GIT_NAME"
        git config --global user.email "$GIT_EMAIL"
        GIT_IDENTITY_STATUS="$GIT_NAME <$GIT_EMAIL>"
        echo "[install] Git identity restored: $GIT_NAME <$GIT_EMAIL>"
    else
        echo "[install] Git identity not found in secrets.json — set manually or run save-secrets"
    fi
fi

# Restore Claude memory files from agent-config/memory/
MEMORY_DIR="$AGENT_CONFIG_DIR/memory"
MEMORY_STATUS="none saved"
if [ -d "$MEMORY_DIR" ]; then
    MEMORY_RESTORED=0
    for project_mem in "$MEMORY_DIR"/*/; do
        [ -d "$project_mem" ] || continue
        project_dir=$(basename "$project_mem")
        dest="$CLAUDE_DIR/projects/$project_dir/memory"
        mkdir -p "$dest"
        cp -a "$project_mem"/. "$dest"/
        file_count=$(find "$dest" -type f | wc -l)
        echo "[install] Memory restored: $project_dir ($file_count file(s))"
        MEMORY_RESTORED=$((MEMORY_RESTORED + file_count))
    done
    if [ "$MEMORY_RESTORED" -gt 0 ]; then
        MEMORY_STATUS="$MEMORY_RESTORED file(s) restored"
    fi
fi

# Hydrate {{TOKEN}} placeholders in plugin MCP configs from secrets.json
hydrate_plugin_mcp() {
    local plugin_mcp="$1"
    local secrets_file="$2"
    local hydrated="$plugin_mcp"

    # Iterate over each server to hydrate per-plugin secrets
    local servers
    servers=$(echo "$plugin_mcp" | jq -r 'keys[]' 2>/dev/null || true)

    for server in $servers; do
        # Get plugin name from _source tag
        local p_name
        p_name=$(echo "$plugin_mcp" | jq -r --arg s "$server" '.[$s]._source // "" | sub("^plugin:"; "")' 2>/dev/null || echo "")
        [ -z "$p_name" ] && continue

        # Extract {{TOKEN}} patterns from this server's config
        local server_json
        server_json=$(echo "$plugin_mcp" | jq --arg s "$server" '.[$s]' 2>/dev/null || echo "{}")
        local server_tokens
        server_tokens=$(echo "$server_json" | grep -oP '\{\{[A-Z_]+\}\}' | sort -u || true)

        for token_pattern in $server_tokens; do
            local token_name
            token_name=$(echo "$token_pattern" | sed 's/{{//;s/}}//')

            # Namespaced lookup: secrets.json["plugin-name"]["TOKEN_NAME"]
            local secret_value=""
            if [ -f "$secrets_file" ]; then
                secret_value=$(jq -r --arg p "$p_name" --arg k "$token_name" \
                    '.[$p][$k] // ""' "$secrets_file" 2>/dev/null || echo "")
            fi

            # Warn if missing (per user decision: inline warning, no crash)
            if [ -z "$secret_value" ]; then
                echo "⚠ $p_name: missing $token_name"
            fi

            # Hydrate using jq walk+gsub (safe for special characters in secrets)
            hydrated=$(echo "$hydrated" | jq \
                --arg token "$token_pattern" \
                --arg value "$secret_value" \
                'walk(if type == "string" then gsub($token; $value) else . end)' 2>/dev/null || echo "$hydrated")
        done
    done

    echo "$hydrated"
}

# Generate .mcp.json — unified: plugin servers (hydrated) + base template servers
MCP_JSON='{"mcpServers":{}}'

# Step 1: Add hydrated plugin MCP servers
if [ "$PLUGIN_MCP" != "{}" ]; then
    HYDRATED_PLUGIN_MCP=$(hydrate_plugin_mcp "$PLUGIN_MCP" "$SECRETS_FILE")
    MCP_JSON=$(echo "$MCP_JSON" | jq --argjson plugin "$HYDRATED_PLUGIN_MCP" \
        '.mcpServers = $plugin')
    PLUGIN_MCP_COUNT=$(echo "$HYDRATED_PLUGIN_MCP" | jq 'length' 2>/dev/null || echo "0")
    MCP_COUNT=$((MCP_COUNT + PLUGIN_MCP_COUNT))
fi

# Step 2: Add base template servers from config.json (Claude-targeted only)
if [ -f "$CONFIG_FILE" ]; then
    ENABLED_SERVERS=$(jq -r '.mcp_servers | to_entries[] | select(.value.enabled == true) | .key' "$CONFIG_FILE" 2>/dev/null || echo "")

    if [ -n "$ENABLED_SERVERS" ]; then
        for SERVER in $ENABLED_SERVERS; do
            # Check targets — skip servers not targeting Claude
            SERVER_CONFIG=$(jq --arg s "$SERVER" '.mcp_servers[$s]' "$CONFIG_FILE" 2>/dev/null || echo '{}')
            if ! server_targets_agent "claude" "$SERVER_CONFIG"; then
                continue
            fi
            TEMPLATE_FILE="$MCP_TEMPLATES_DIR/${SERVER}.json"
            if [ -f "$TEMPLATE_FILE" ]; then
                HYDRATED=$(sed "s|{{MCP_GATEWAY_URL}}|$MCP_GATEWAY_URL|g" "$TEMPLATE_FILE")
                MCP_JSON=$(echo "$MCP_JSON" | jq --argjson server "{\"$SERVER\": $HYDRATED}" '.mcpServers += $server')
                MCP_COUNT=$((MCP_COUNT + 1))
            else
                echo "[install] WARNING: Template $TEMPLATE_FILE not found for enabled server $SERVER"
            fi
        done
    fi
fi

# Fallback: if no servers at all, add default mcp-gateway
SERVER_COUNT=$(echo "$MCP_JSON" | jq '.mcpServers | length')
if [ "$SERVER_COUNT" -eq 0 ]; then
    MCP_JSON='{"mcpServers":{"mcp-gateway":{"type":"sse","url":"'"$MCP_GATEWAY_URL"'/sse"}}}'
    MCP_COUNT=1
fi

echo "$MCP_JSON" > "$CLAUDE_DIR/.mcp.json"
echo "[install] Generated .mcp.json with $MCP_COUNT server(s)"

# Generate infra/.env from secrets.json if infra section exists
INFRA_ENV_STATUS="skipped — no infra secrets"
if [ -f "$SECRETS_FILE" ]; then
    HAS_INFRA=$(jq -e '.infra.postgres_password // empty' "$SECRETS_FILE" 2>/dev/null && echo "yes" || echo "")
    if [ -n "$HAS_INFRA" ]; then
        if command -v langfuse-setup &>/dev/null; then
            langfuse-setup --generate-env 2>/dev/null && INFRA_ENV_STATUS="generated" || INFRA_ENV_STATUS="failed"
            echo "[install] infra/.env: $INFRA_ENV_STATUS"
        else
            echo "[install] WARNING: langfuse-setup not on PATH — skipping .env generation"
        fi
    fi
fi

# Detect unresolved {{PLACEHOLDER}} tokens in generated files (GEN-06)
UNRESOLVED=""
for generated_file in "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/.mcp.json"; do
    if [ -f "$generated_file" ]; then
        tokens=$(grep -oP '\{\{[A-Z_]+\}\}' "$generated_file" 2>/dev/null || true)
        if [ -n "$tokens" ]; then
            UNRESOLVED="$UNRESOLVED $tokens"
            # Replace unresolved tokens with empty strings
            sed -i 's/{{[A-Z_]*}}//g' "$generated_file"
        fi
    fi
done
if [ -n "$UNRESOLVED" ]; then
    echo "[install] WARNING: Unresolved placeholders replaced with empty strings:$UNRESOLVED"
fi

# Install GSD framework
if [ -d "$CLAUDE_DIR/commands/gsd" ] && [ "$(ls -A "$CLAUDE_DIR/commands/gsd" 2>/dev/null)" ]; then
    echo "[install] GSD: already installed, skipping"
    # Count existing installation
    GSD_COMMANDS=$(find "$CLAUDE_DIR/commands/gsd" -name "*.md" 2>/dev/null | wc -l || echo 0)
    GSD_AGENTS=$(find "$CLAUDE_DIR/agents" -name "*.md" 2>/dev/null | wc -l || echo 0)
else
    echo "[install] Installing GSD framework..."
    if npx get-shit-done-cc --claude --global > /dev/null 2>&1; then
        echo "[install] GSD framework installed"
        # Count after installation
        GSD_COMMANDS=$(find "$CLAUDE_DIR/commands/gsd" -name "*.md" 2>/dev/null | wc -l || echo 0)
        GSD_AGENTS=$(find "$CLAUDE_DIR/agents" -name "*.md" 2>/dev/null | wc -l || echo 0)
    else
        echo "[install] WARNING: GSD installation failed"
        GSD_COMMANDS=0
        GSD_AGENTS=0
    fi
fi

# Enforce required settings.json values AFTER GSD (which modifies the file).
jq '.permissions.defaultMode = "bypassPermissions" | .effortLevel = "high" | .model = "opus" | .skipDangerousModePermissionPrompt = true' \
    "$CLAUDE_DIR/settings.json" > "$CLAUDE_DIR/settings.json.tmp" \
    && mv "$CLAUDE_DIR/settings.json.tmp" "$CLAUDE_DIR/settings.json"
echo "[install] Enforced settings.json (bypassPermissions, opus, effortLevel: high)"

# --- Merge template + plugin hooks/env into settings.json ---
# Done AFTER GSD install + enforcement so nothing overwrites these values.
# Claude Code only reads hooks and env from settings.json (not settings.local.json).

# Reset hooks and env before rebuilding (idempotent across re-runs)
jq '.hooks = {} | .env = {}' "$CLAUDE_DIR/settings.json" > "$CLAUDE_DIR/settings.json.tmp" \
    && mv "$CLAUDE_DIR/settings.json.tmp" "$CLAUDE_DIR/settings.json"

# Merge hydrated template (hooks, env, additionalDirectories) into settings.json
if [ "$HYDRATED_SETTINGS" != "{}" ]; then
    jq --argjson tmpl "$HYDRATED_SETTINGS" '
        # Merge hooks: append template hook arrays to existing arrays per event
        .hooks = ((.hooks // {}) as $existing |
            ($tmpl.hooks // {}) | to_entries | reduce .[] as $entry ($existing;
                .[$entry.key] = ((.[$entry.key] // []) + $entry.value)
            )
        ) |
        # Merge env vars (template values, may be overridden by plugins below)
        .env = ((.env // {}) + ($tmpl.env // {})) |
        # Merge additionalDirectories
        .permissions.additionalDirectories = (
            ((.permissions.additionalDirectories // []) + ($tmpl.permissions.additionalDirectories // [])) | unique
        )
    ' "$CLAUDE_DIR/settings.json" > "$CLAUDE_DIR/settings.json.tmp" \
        && mv "$CLAUDE_DIR/settings.json.tmp" "$CLAUDE_DIR/settings.json"
    echo "[install] Merged template hooks + env into settings.json"
fi

# Merge plugin hooks into settings.json
if [ "$PLUGIN_HOOKS" != "{}" ]; then
    jq --argjson plugin_hooks "$PLUGIN_HOOKS" '
        reduce ($plugin_hooks | to_entries[]) as $entry (.;
            .hooks[$entry.key] = ((.hooks[$entry.key] // []) + [{"hooks": $entry.value}])
        )
    ' "$CLAUDE_DIR/settings.json" > "$CLAUDE_DIR/settings.json.tmp" \
        && mv "$CLAUDE_DIR/settings.json.tmp" "$CLAUDE_DIR/settings.json"
    echo "[install] Merged plugin hooks into settings.json"
fi

# Merge plugin env vars into settings.json
if [ "$PLUGIN_ENV" != "{}" ]; then
    jq --argjson plugin_env "$PLUGIN_ENV" '.env = ((.env // {}) + $plugin_env)' \
        "$CLAUDE_DIR/settings.json" > "$CLAUDE_DIR/settings.json.tmp" \
        && mv "$CLAUDE_DIR/settings.json.tmp" "$CLAUDE_DIR/settings.json"
    echo "[install] Merged plugin env vars into settings.json"
fi

# --- Auto-discover and install project-repo plugins ---
# Scans /workspace/projects/*/.claude/plugins/*/ for valid plugin manifests
# and copies their components to runtime locations (same as agent-config plugins).
# The plugins[] array alone doesn't work from /workspace/ — Claude Code only
# auto-discovers plugin components when cwd matches the project root.
#
# Read project_plugin_scan from config.json (default: false).
# Can also override via env var NMC_SKIP_PROJECT_PLUGINS=1.
if [ -z "${NMC_SKIP_PROJECT_PLUGINS:-}" ]; then
    _scan_enabled=$(jq -r '.project_plugin_scan // false' "$CONFIG_FILE" 2>/dev/null)
    if [ "$_scan_enabled" = "true" ]; then
        NMC_SKIP_PROJECT_PLUGINS=0
    else
        NMC_SKIP_PROJECT_PLUGINS=1
    fi
fi

PROJECT_PLUGINS_COUNT=0
declare -a PROJECT_PLUGIN_DETAIL_LINES=()
declare -a PROJECT_HOOKS_PENDING=()

if [ "$NMC_SKIP_PROJECT_PLUGINS" = "1" ]; then
    echo "[install] Project plugin scanning disabled (NMC_SKIP_PROJECT_PLUGINS=1)"
elif [ -d "$WORKSPACE_ROOT/projects" ]; then
    for project_dir in "$WORKSPACE_ROOT/projects"/*/; do
        [ -d "$project_dir" ] || continue
        PLUGINS_DIR="$project_dir.claude/plugins"
        [ -d "$PLUGINS_DIR" ] || continue
        project_basename=$(basename "$project_dir")

        for plugin_dir in "$PLUGINS_DIR"/*/; do
            [ -d "$plugin_dir" ] || continue
            plugin_name=$(basename "$plugin_dir")

            # Accept manifest at .claude-plugin/plugin.json (standard) or plugin.json (legacy)
            MANIFEST=""
            if [ -f "$plugin_dir/.claude-plugin/plugin.json" ]; then
                MANIFEST="$plugin_dir/.claude-plugin/plugin.json"
            elif [ -f "$plugin_dir/plugin.json" ]; then
                MANIFEST="$plugin_dir/plugin.json"
            fi

            if [ -z "$MANIFEST" ]; then
                echo "[install] Project plugin '$plugin_name' in $project_basename: skipped (no manifest)"
                continue
            fi

            if ! jq empty < "$MANIFEST" &>/dev/null; then
                echo "[install] Project plugin '$plugin_name' in $project_basename: skipped (invalid JSON)"
                continue
            fi

            # Reset per-plugin counters
            pp_skills=0; pp_cmds=0; pp_agents=0; pp_hooks=0

            # Copy skills (cross-agent: Claude + Codex)
            if [ -d "$plugin_dir/skills" ]; then
                for skill_dir in "$plugin_dir/skills"/*/; do
                    [ -d "$skill_dir" ] || continue
                    skill_name=$(basename "$skill_dir")
                    if ! should_install_skill "$skill_name"; then
                        continue
                    fi
                    cp -r "$skill_dir" "$CLAUDE_DIR/skills/"
                    copy_skill_dir_to_codex "$skill_dir"
                    pp_skills=$((pp_skills + 1))
                done
            fi

            # Copy commands into namespaced subdirectory (commands/<plugin-name>/ → /plugin-name:cmd)
            if [ -d "$plugin_dir/commands" ]; then
                # Use manifest name for namespace (matches how the plugin identifies itself)
                cmd_namespace=$(jq -r '.name // ""' "$MANIFEST" 2>/dev/null)
                [ -z "$cmd_namespace" ] && cmd_namespace="$plugin_name"
                mkdir -p "$CLAUDE_DIR/commands/$cmd_namespace"
                for cmd_file in "$plugin_dir/commands"/*.md; do
                    [ -f "$cmd_file" ] || continue
                    cmd_basename=$(basename "$cmd_file")
                    cmd_ref="$cmd_namespace/$cmd_basename"
                    if ! should_install_command "$cmd_ref"; then
                        continue
                    fi
                    cp "$cmd_file" "$CLAUDE_DIR/commands/$cmd_namespace/"
                    mkdir -p "/home/node/.codex/prompts/$cmd_namespace"
                    strip_allowed_tools_frontmatter "$cmd_file" "/home/node/.codex/prompts/$cmd_namespace/$cmd_basename"
                    CODEX_PROMPTS_COUNT=$((CODEX_PROMPTS_COUNT + 1))
                    pp_cmds=$((pp_cmds + 1))
                done
            fi

            # Copy agents (with conflict detection)
            if [ -d "$plugin_dir/agents" ]; then
                for agent_file in "$plugin_dir/agents"/*.md; do
                    [ -f "$agent_file" ] || continue
                    agent_basename=$(basename "$agent_file")
                    if [[ "$agent_basename" =~ ^gsd- ]]; then
                        echo "[install] WARNING: Project plugin '$plugin_name' GSD-protected agents/$agent_basename — skipping"
                        continue
                    fi
                    if [ -n "${PLUGIN_FILE_OWNERS[agents/$agent_basename]+x}" ]; then
                        echo "[install] WARNING: Project plugin '$plugin_name' agent '$agent_basename' conflicts with '${PLUGIN_FILE_OWNERS[agents/$agent_basename]}' — skipping"
                        PLUGIN_WARNINGS=$((PLUGIN_WARNINGS + 1))
                        PLUGIN_WARNING_MESSAGES+=("Project plugin '$plugin_name': agent '$agent_basename' conflicts with '${PLUGIN_FILE_OWNERS[agents/$agent_basename]}'")
                    else
                        PLUGIN_FILE_OWNERS["agents/$agent_basename"]="$plugin_name (project: $project_basename)"
                        cp "$agent_file" "$CLAUDE_DIR/agents/"
                    fi
                done
                pp_agents=$(find "$plugin_dir/agents" -maxdepth 1 -name "*.md" -type f 2>/dev/null | wc -l)
            fi

            # Merge hooks from hooks/hooks.json directly into settings.json
            # hooks.json uses settings.json format (objects with matcher + hooks sub-array),
            # so we concatenate directly — NOT through PLUGIN_HOOKS which uses the flat format.
            if [ -f "$plugin_dir/hooks/hooks.json" ]; then
                HOOKS_JSON=$(cat "$plugin_dir/hooks/hooks.json")
                if jq empty <<< "$HOOKS_JSON" &>/dev/null; then
                    pp_hooks=$(jq 'to_entries | map(.value | length) | add // 0' <<< "$HOOKS_JSON")
                    PROJECT_HOOKS_PENDING+=("$HOOKS_JSON")
                fi
            fi

            # Copy standalone hook scripts
            if [ -d "$plugin_dir/hooks" ]; then
                for hook_file in "$plugin_dir/hooks"/*; do
                    [ -f "$hook_file" ] || continue
                    hook_basename=$(basename "$hook_file")
                    # Skip hooks.json — already processed above
                    [ "$hook_basename" = "hooks.json" ] && continue
                    if [ -n "${PLUGIN_FILE_OWNERS[hooks/$hook_basename]+x}" ]; then
                        echo "[install] WARNING: Project plugin '$plugin_name' hook '$hook_basename' conflicts with '${PLUGIN_FILE_OWNERS[hooks/$hook_basename]}' — skipping"
                    else
                        PLUGIN_FILE_OWNERS["hooks/$hook_basename"]="$plugin_name (project: $project_basename)"
                        cp "$hook_file" "$CLAUDE_DIR/hooks/"
                    fi
                done
            fi

            # Build detail line
            detail_parts=()
            [ "$pp_skills" -gt 0 ] && detail_parts+=("${pp_skills} skill(s)")
            [ "$pp_cmds" -gt 0 ] && detail_parts+=("${pp_cmds} command(s)")
            [ "$pp_agents" -gt 0 ] && detail_parts+=("${pp_agents} agent(s)")
            [ "$pp_hooks" -gt 0 ] && detail_parts+=("${pp_hooks} hook(s)")
            detail_str=$(IFS=", "; echo "${detail_parts[*]}")

            if [ -n "$detail_str" ]; then
                echo "[install] Project plugin '$plugin_name' in $project_basename: installed ($detail_str)"
                PROJECT_PLUGIN_DETAIL_LINES+=("  $project_basename/$plugin_name: $detail_str")
            else
                echo "[install] Project plugin '$plugin_name' in $project_basename: installed (manifest only)"
                PROJECT_PLUGIN_DETAIL_LINES+=("  $project_basename/$plugin_name: manifest only")
            fi
            PROJECT_PLUGINS_COUNT=$((PROJECT_PLUGINS_COUNT + 1))
        done
    done
fi

# Merge project plugin hooks directly into settings.json
# hooks.json files are already in settings format — just concatenate arrays per event.
if [ ${#PROJECT_HOOKS_PENDING[@]} -gt 0 ]; then
    for hooks_json in "${PROJECT_HOOKS_PENDING[@]}"; do
        jq --argjson new "$hooks_json" '
            reduce ($new | to_entries[]) as $entry (.;
                .hooks[$entry.key] = ((.hooks[$entry.key] // []) + $entry.value)
            )
        ' "$CLAUDE_DIR/settings.json" > "$CLAUDE_DIR/settings.json.tmp" \
            && mv "$CLAUDE_DIR/settings.json.tmp" "$CLAUDE_DIR/settings.json"
    done
    echo "[install] Merged project plugin hooks into settings.json"
fi

# --- Clone repo .claude/ content to ~/.codex/ for Codex compatibility ---
# Codex doesn't support per-project .codex/ dirs yet, so skills and prompts
# are hydrated into the global ~/.codex/ location. Local .codex/ dirs are
# gitignored as placeholders for future support.
# Runs independently of NMC_SKIP_PROJECT_PLUGINS — direct .claude/ content always cloned.
if [ -d "$WORKSPACE_ROOT/projects" ]; then
    for project_dir in "$WORKSPACE_ROOT/projects"/*/; do
        [ -d "$project_dir" ] || continue
        CLAUDE_PROJECT_DIR="$project_dir.claude"
        [ -d "$CLAUDE_PROJECT_DIR" ] || continue

        project_basename=$(basename "$project_dir")

        # Skip projects listed in codex.skip_dirs
        if item_in_json_array "$project_basename" "$CODEX_SKIP_DIRS" 2>/dev/null; then
            echo "[install] Codex clone '$project_basename': skipped (codex.skip_dirs)"
            # Still gitignore .codex/ even for skipped projects
            ensure_codex_gitignore "$project_dir"
            continue
        fi

        clone_skills=0
        clone_cmds=0

        # Clone skills: .claude/skills/*/ → ~/.codex/skills/*/
        if [ -d "$CLAUDE_PROJECT_DIR/skills" ]; then
            mkdir -p /home/node/.codex/skills
            for skill_dir in "$CLAUDE_PROJECT_DIR/skills"/*/; do
                [ -d "$skill_dir" ] || continue
                copy_skill_dir_to_codex "$skill_dir"
                clone_skills=$((clone_skills + 1))
            done
        fi

        # Clone commands: .claude/commands/*.md → ~/.codex/prompts/*.md
        if [ -d "$CLAUDE_PROJECT_DIR/commands" ]; then
            mkdir -p /home/node/.codex/prompts
            for cmd_file in "$CLAUDE_PROJECT_DIR/commands"/*.md; do
                [ -f "$cmd_file" ] || continue
                cmd_basename=$(basename "$cmd_file")
                strip_allowed_tools_frontmatter "$cmd_file" "/home/node/.codex/prompts/$cmd_basename"
                clone_cmds=$((clone_cmds + 1))
            done
            # Clone namespaced command subdirectories
            for cmd_subdir in "$CLAUDE_PROJECT_DIR/commands"/*/; do
                [ -d "$cmd_subdir" ] || continue
                subdir_name=$(basename "$cmd_subdir")
                mkdir -p "/home/node/.codex/prompts/$subdir_name"
                for cmd_file in "$cmd_subdir"*.md; do
                    [ -f "$cmd_file" ] || continue
                    cmd_basename=$(basename "$cmd_file")
                    strip_allowed_tools_frontmatter "$cmd_file" "/home/node/.codex/prompts/$subdir_name/$cmd_basename"
                    clone_cmds=$((clone_cmds + 1))
                done
            done
        fi

        # Skip: agents, hooks.json, settings.json, COMMAND_INDEX.md (no Codex equivalents)

        # Ensure .codex/ is gitignored (placeholder for future per-project support)
        ensure_codex_gitignore "$project_dir"

        if [ "$clone_skills" -gt 0 ] || [ "$clone_cmds" -gt 0 ]; then
            echo "[install] Codex clone '$project_basename': $clone_skills skill(s), $clone_cmds command(s)"
            CODEX_CLONE_COUNT=$((CODEX_CLONE_COUNT + 1))
        fi
    done
fi

# Print summary
echo "[install] --- Summary ---"
echo "[install] Config: $CONFIG_STATUS"
echo "[install] Secrets: $SECRETS_STATUS"
echo "[install] Settings: generated"
echo "[install] Credentials (Claude): $CREDS_STATUS"
echo "[install] Credentials (Codex): $CODEX_CREDS_STATUS"
echo "[install] Git identity: $GIT_IDENTITY_STATUS"
echo "[install] Preferences: $CC_PREFS_STATUS"
echo "[install] Memory: $MEMORY_STATUS"
echo "[install] Skill filter: $SKILL_FILTER_STATUS"
echo "[install] Command filter: $COMMAND_FILTER_STATUS"
echo "[install] Skills: $SKILLS_COUNT skill(s) -> Claude + Codex"
echo "[install] Hooks: $HOOKS_COUNT hook(s)"
echo "[install] Commands: $COMMANDS_COUNT standalone command(s)"
echo "[install] Codex prompts: $CODEX_PROMPTS_COUNT prompt(s) -> ~/.codex/prompts/"
echo "[install] Codex clone: $CODEX_CLONE_COUNT project(s)"
echo "[install] Upstream plugins: $UPSTREAM_STATUS"
echo "[install] Plugins (agent-config): $PLUGIN_INSTALLED installed, $PLUGIN_SKIPPED skipped"
if [ ${#PLUGIN_DETAIL_LINES[@]} -gt 0 ]; then
    for detail_line in "${PLUGIN_DETAIL_LINES[@]}"; do
        echo "[install] $detail_line"
    done
fi
if [ "$NMC_SKIP_PROJECT_PLUGINS" = "1" ]; then
    echo "[install] Plugins (projects): disabled"
else
    echo "[install] Plugins (projects): $PROJECT_PLUGINS_COUNT installed"
fi
if [ ${#PROJECT_PLUGIN_DETAIL_LINES[@]} -gt 0 ]; then
    for detail_line in "${PROJECT_PLUGIN_DETAIL_LINES[@]}"; do
        echo "[install] $detail_line"
    done
fi
if [ "$PLUGIN_WARNINGS" -gt 0 ]; then
    echo "[install] Plugin warnings: $PLUGIN_WARNINGS"
fi
echo "[install] MCP (Claude): $MCP_COUNT server(s)"
echo "[install] MCP (Codex): $CODEX_MCP_COUNT server(s)"
echo "[install] Infra .env: $INFRA_ENV_STATUS"
echo "[install] GSD: $GSD_COMMANDS commands + $GSD_AGENTS agents"
echo "[install] Done."

# Warnings recap (if any)
if [ ${#PLUGIN_WARNING_MESSAGES[@]} -gt 0 ]; then
    echo ""
    echo "[install] --- Warnings Recap ---"
    for warning in "${PLUGIN_WARNING_MESSAGES[@]}"; do
        echo "[install] WARNING: $warning"
    done
    echo "[install] --- End Warnings ---"
fi
