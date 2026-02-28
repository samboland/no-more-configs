#!/bin/bash
set -euo pipefail

# save-config.sh
# Captures all NMC configuration into config.json.
# All known sections are saved (including defaults) so the file is easy to edit.
# Run this before rebuilding to preserve preferences across container rebuilds.

CONFIG_FILE="/workspace/config.json"
CLAUDE_JSON="${HOME}/.claude.json"

# Start with existing config.json or empty object
if [ -f "$CONFIG_FILE" ]; then
    if ! jq empty < "$CONFIG_FILE" &>/dev/null; then
        echo "[save-config] ERROR: config.json is not valid JSON"
        exit 1
    fi
    CONFIG=$(cat "$CONFIG_FILE")
else
    CONFIG='{}'
fi

# ─── Section 1: claude_code (from ~/.claude.json) ────────────────────────────

# Known preference keys and their defaults.
# Feature-flagged keys (no stable default) are always saved if present.
declare -A CC_DEFAULTS=(
    ["autoCompactEnabled"]="true"
    ["autoInstallIdeExtension"]="true"
    ["autoConnectIde"]="false"
    ["respectGitignore"]="true"
    ["fileCheckpointingEnabled"]="true"
    ["terminalProgressBarEnabled"]="true"
    ["diffTool"]='"auto"'
    ["editorMode"]='"normal"'
    ["preferredNotifChannel"]='"auto"'
)

# Feature-flagged keys — saved whenever present (no stable default)
FEATURE_FLAGGED_KEYS=(
    "codeDiffFooterEnabled"
    "prStatusFooterEnabled"
    "claudeInChromeDefaultEnabled"
)

ALL_CC_KEYS=("${!CC_DEFAULTS[@]}" "${FEATURE_FLAGGED_KEYS[@]}")

CC_RESULT='{}'
CC_SAVED=()
CC_DEFAULTED=()

if [ -f "$CLAUDE_JSON" ] && jq empty < "$CLAUDE_JSON" &>/dev/null; then
    echo "[save-config] Reading Claude Code preferences from ~/.claude.json..."
    for key in "${ALL_CC_KEYS[@]}"; do
        has_key=$(jq --arg k "$key" 'has($k)' "$CLAUDE_JSON")
        if [ "$has_key" = "true" ]; then
            live_value=$(jq --arg k "$key" '.[$k]' "$CLAUDE_JSON")
            CC_RESULT=$(echo "$CC_RESULT" | jq --arg k "$key" --argjson v "$live_value" '.[$k] = $v')
            CC_SAVED+=("$key=$live_value")
        elif [ -n "${CC_DEFAULTS[$key]+x}" ]; then
            default="${CC_DEFAULTS[$key]}"
            CC_RESULT=$(echo "$CC_RESULT" | jq --arg k "$key" --argjson v "$default" '.[$k] = $v')
            CC_DEFAULTED+=("$key")
        fi
    done
else
    echo "[save-config] ~/.claude.json not found — using defaults for claude_code"
    for key in "${!CC_DEFAULTS[@]}"; do
        default="${CC_DEFAULTS[$key]}"
        CC_RESULT=$(echo "$CC_RESULT" | jq --arg k "$key" --argjson v "$default" '.[$k] = $v')
        CC_DEFAULTED+=("$key")
    done
fi

CONFIG=$(echo "$CONFIG" | jq --argjson prefs "$CC_RESULT" '.claude_code = $prefs')

# ─── Section 2: firewall ─────────────────────────────────────────────────────

CONFIG=$(echo "$CONFIG" | jq '
    .firewall //= {} |
    .firewall |= (if has("enabled") then . else .enabled = true end) |
    .firewall.extra_domains //= []
')

# ─── Section 3: codex ────────────────────────────────────────────────────────

CONFIG=$(echo "$CONFIG" | jq '.codex //= {} | .codex.model //= "gpt-5.3-codex" | .codex.skip_dirs //= []')

# ─── Section 4: infra ────────────────────────────────────────────────────────

CONFIG=$(echo "$CONFIG" | jq '.infra //= {} | .infra.mcp_workspace_bind //= "/workspace"')

# ─── Section 5: langfuse ─────────────────────────────────────────────────────

CONFIG=$(echo "$CONFIG" | jq '.langfuse //= {} | .langfuse.host //= "http://host.docker.internal:3052"')

# ─── Section 6: vscode ───────────────────────────────────────────────────────

CONFIG=$(echo "$CONFIG" | jq '.vscode //= {} | .vscode.git_scan_paths //= []')

# ─── Section 7: mcp_servers ──────────────────────────────────────────────────

CONFIG=$(echo "$CONFIG" | jq '
    .mcp_servers //= {} |
    .mcp_servers["mcp-gateway"] //= {"enabled": false}
')

# ─── Section 8: sdks ─────────────────────────────────────────────────────────

CONFIG=$(echo "$CONFIG" | jq '
  .sdks //= {} |
  .sdks.dotnet //= false |
  .sdks.rust //= false |
  .sdks.go //= false |
  .sdks.deno //= false
')

# ─── Section 9: plugins ──────────────────────────────────────────────────────

# Discover installed plugins and ensure each has an entry.
# Opt-in plugins (langfuse tracing) default to disabled; others default to enabled.
CONFIG=$(echo "$CONFIG" | jq '.plugins //= {}')

OPT_IN_PLUGINS=("nmc-langfuse-tracing")

for plugin_dir in /workspace/agent-config/plugins/*/; do
    [ -d "$plugin_dir" ] || continue
    plugin_name=$(basename "$plugin_dir")
    default_enabled="true"
    for opt_in in "${OPT_IN_PLUGINS[@]}"; do
        [ "$plugin_name" = "$opt_in" ] && default_enabled="false" && break
    done
    CONFIG=$(echo "$CONFIG" | jq --arg p "$plugin_name" --argjson d "$default_enabled" '.plugins[$p] //= {"enabled": $d}')
done

# ─── Section 10: Claude memory ───────────────────────────────────────────────

# Save Claude's per-project memory files so they survive container rebuilds.
# Memory dirs live at ~/.claude/projects/<project-dir>/memory/
MEMORY_DIR="/workspace/agent-config/memory"
CLAUDE_PROJECTS="${CLAUDE_DIR:-$HOME/.claude}/projects"
MEMORY_SAVED=0

if [ -d "$CLAUDE_PROJECTS" ]; then
    for mem_dir in "$CLAUDE_PROJECTS"/*/memory; do
        [ -d "$mem_dir" ] || continue
        # Skip empty memory directories
        mem_files=$(find "$mem_dir" -maxdepth 1 -type f 2>/dev/null | head -1)
        [ -z "$mem_files" ] && continue

        project_dir=$(basename "$(dirname "$mem_dir")")
        dest="$MEMORY_DIR/$project_dir"
        mkdir -p "$dest"
        cp -a "$mem_dir"/. "$dest"/
        file_count=$(find "$dest" -type f | wc -l)
        echo "[save-config] Memory saved: $project_dir ($file_count file(s))"
        MEMORY_SAVED=$((MEMORY_SAVED + file_count))
    done
fi

if [ "$MEMORY_SAVED" -eq 0 ]; then
    echo "[save-config] No Claude memory files found to save"
fi

# ─── Write ────────────────────────────────────────────────────────────────────

echo "$CONFIG" | jq '.' > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

# ─── Summary ──────────────────────────────────────────────────────────────────

echo "[save-config] --- Summary ---"

# Claude Code prefs
if [ ${#CC_SAVED[@]} -gt 0 ]; then
    echo "[save-config] claude_code (from live):"
    for entry in "${CC_SAVED[@]}"; do
        echo "[save-config]   $entry"
    done
fi
if [ ${#CC_DEFAULTED[@]} -gt 0 ]; then
    echo "[save-config] claude_code (defaults): ${CC_DEFAULTED[*]}"
fi

# Other sections — show what's set
for section in firewall codex infra langfuse vscode mcp_servers sdks plugins; do
    value=$(jq -c ".$section" "$CONFIG_FILE")
    echo "[save-config] $section: $value"
done

echo "[save-config] Memory: $MEMORY_SAVED file(s) saved to agent-config/memory/"
echo "[save-config] Written to $CONFIG_FILE"
echo ""
echo "[save-config] Tip: also run save-secrets to persist credentials (Claude, Codex, infra keys, etc.)"
