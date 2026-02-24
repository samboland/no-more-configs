#!/bin/bash
# MCP setup script - regenerates .mcp.json and Codex config.toml MCP sections
# Uses the same template system as install-agent-config.sh

# Source shared MCP helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/lib-mcp.sh" ]; then
    source "$SCRIPT_DIR/lib-mcp.sh"
else
    # Fallback: try workspace location
    source "/workspace/.devcontainer/lib-mcp.sh" 2>/dev/null || true
fi

gateway_url="${MCP_GATEWAY_URL:-http://host.docker.internal:8811}"
claude_dir="${HOME}/.claude"
workspace="${CLAUDE_WORKSPACE:-/workspace}"
config_file="${workspace}/config.json"
templates_dir="${workspace}/agent-config/mcp-templates"

mkdir -p "$claude_dir"

# ============================================================================
# CLAUDE: Regenerate .mcp.json
# ============================================================================

# Load existing .mcp.json (written by install-agent-config.sh, may contain plugin servers)
EXISTING_MCP=$(cat "$claude_dir/.mcp.json" 2>/dev/null || echo '{"mcpServers":{}}')

# Extract and preserve plugin servers (identified by _source tag starting with "plugin:")
PLUGIN_SERVERS=$(echo "$EXISTING_MCP" | jq '.mcpServers |
    with_entries(select(.value._source? // "" | startswith("plugin:")))' 2>/dev/null || echo '{}')

PLUGIN_COUNT=$(echo "$PLUGIN_SERVERS" | jq 'length' 2>/dev/null || echo "0")

# Build base servers from config.json templates (refreshed each start)
MCP_JSON='{"mcpServers":{}}'
MCP_COUNT=0

if [ -f "$config_file" ]; then
    ENABLED_SERVERS=$(jq -r '.mcp_servers | to_entries[] | select(.value.enabled == true) | .key' "$config_file" 2>/dev/null || echo "")

    if [ -n "$ENABLED_SERVERS" ]; then
        for SERVER in $ENABLED_SERVERS; do
            # Check targets — skip servers not targeting Claude
            SERVER_CONFIG=$(jq --arg s "$SERVER" '.mcp_servers[$s]' "$config_file" 2>/dev/null || echo '{}')
            if ! server_targets_agent "claude" "$SERVER_CONFIG"; then
                continue
            fi
            TEMPLATE_FILE="${templates_dir}/${SERVER}.json"
            if [ -f "$TEMPLATE_FILE" ]; then
                HYDRATED=$(sed "s|{{MCP_GATEWAY_URL}}|$gateway_url|g" "$TEMPLATE_FILE")
                MCP_JSON=$(echo "$MCP_JSON" | jq --argjson server "{\"$SERVER\": $HYDRATED}" '.mcpServers += $server')
                MCP_COUNT=$((MCP_COUNT + 1))
            else
                echo "⚠ Template not found: $TEMPLATE_FILE"
            fi
        done
    fi
fi

# Merge: plugin servers (preserved from install) + base servers (refreshed)
# Plugin servers take precedence (they are plugin-owned)
FINAL_MCP=$(jq -n --argjson plugins "$PLUGIN_SERVERS" --argjson base "$MCP_JSON" \
    '{mcpServers: ($plugins + $base.mcpServers)}')

# Fallback: if no servers at all, add default mcp-gateway
TOTAL_COUNT=$(echo "$FINAL_MCP" | jq '.mcpServers | length')
if [ "$TOTAL_COUNT" -eq 0 ]; then
    FINAL_MCP='{"mcpServers":{"mcp-gateway":{"type":"sse","url":"'"$gateway_url"'/sse"}}}'
    TOTAL_COUNT=1
fi

echo "$FINAL_MCP" | jq '.' > "${claude_dir}/.mcp.json"

if [ "$PLUGIN_COUNT" -gt 0 ]; then
    echo "✓ Claude .mcp.json: $TOTAL_COUNT server(s) ($PLUGIN_COUNT plugin, $MCP_COUNT base)"
else
    echo "✓ Claude .mcp.json: $TOTAL_COUNT server(s)"
fi

# ============================================================================
# CODEX: Regenerate config.toml MCP sections
# ============================================================================

CODEX_TOML="/home/node/.codex/config.toml"
CODEX_MCP_COUNT=0

if [ -f "$CODEX_TOML" ]; then
    # Build new MCP section from templates (Codex-targeted)
    MCP_SECTION=""
    if [ -f "$config_file" ]; then
        ENABLED_SERVERS=$(jq -r '.mcp_servers | to_entries[] | select(.value.enabled == true) | .key' "$config_file" 2>/dev/null || echo "")
        for SERVER in $ENABLED_SERVERS; do
            SERVER_CONFIG=$(jq --arg s "$SERVER" '.mcp_servers[$s]' "$config_file" 2>/dev/null || echo '{}')
            if ! server_targets_agent "codex" "$SERVER_CONFIG"; then
                continue
            fi
            TEMPLATE_FILE="${templates_dir}/${SERVER}.json"
            if [ -f "$TEMPLATE_FILE" ]; then
                HYDRATED=$(sed "s|{{MCP_GATEWAY_URL}}|$gateway_url|g" "$TEMPLATE_FILE")
                MCP_SECTION="${MCP_SECTION}$(json_mcp_to_toml "$SERVER" "$HYDRATED")"
                CODEX_MCP_COUNT=$((CODEX_MCP_COUNT + 1))
            fi
        done
    fi

    # Check if markers exist in config.toml
    if grep -q "^# --- MCP servers (auto-generated) ---" "$CODEX_TOML" 2>/dev/null; then
        # Replace content between markers
        awk -v new_content="$MCP_SECTION" '
            /^# --- MCP servers \(auto-generated\) ---/ {
                print
                if (new_content != "") print new_content
                skip=1
                next
            }
            /^# --- end MCP servers ---/ { skip=0 }
            !skip { print }
        ' "$CODEX_TOML" > "${CODEX_TOML}.tmp" && mv "${CODEX_TOML}.tmp" "$CODEX_TOML"
    else
        # Fallback: append MCP section at end (pre-existing config.toml without markers)
        {
            echo ""
            echo "# --- MCP servers (auto-generated) ---"
            echo "$MCP_SECTION"
            echo "# --- end MCP servers ---"
        } >> "$CODEX_TOML"
    fi

    echo "✓ Codex config.toml: $CODEX_MCP_COUNT MCP server(s)"
else
    echo "⚠ Codex config.toml not found — run install-agent-config.sh first"
fi

# ============================================================================
# HEALTH CHECK
# ============================================================================

# Only check gateway health if mcp-gateway is enabled in config
gateway_enabled=$(jq -r '.mcp_servers["mcp-gateway"].enabled // false' "$config_file" 2>/dev/null || echo "false")

if [ "$gateway_enabled" = "true" ]; then
  echo "Checking gateway health at ${gateway_url}/health..."
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --retry 15 --retry-delay 2 --retry-max-time 30 --retry-connrefused \
    "${gateway_url}/health" 2>&1 || echo "000")

  if [ "$http_code" = "200" ]; then
    echo "✓ Gateway is healthy"
  else
    echo "⚠ Warning: Gateway not ready (HTTP ${http_code})"
    echo "  Start: cd ${LANGFUSE_STACK_DIR:-/workspace/infra} && docker compose up -d docker-mcp-gateway"
  fi
else
  echo "⚠ MCP gateway disabled — skipping health check"
fi

echo ""
echo "Claude MCP config: ${claude_dir}/.mcp.json"
echo "Codex MCP config:  ${CODEX_TOML}"
echo "Gateway:           ${gateway_url}"
