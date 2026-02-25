#!/bin/bash
set -euo pipefail

CONFIG_FILE="/workspace/config.json"

# Check if nmc-langfuse-tracing plugin is enabled in config.json
langfuse_enabled="false"
if [ -f "$CONFIG_FILE" ]; then
    langfuse_enabled=$(jq -r '.plugins["nmc-langfuse-tracing"].enabled // false' "$CONFIG_FILE" 2>/dev/null || echo "false")
fi

if [ "$langfuse_enabled" != "true" ]; then
    echo "[network] Langfuse tracing disabled — skipping network checks"
    exit 0
fi

python3 -m pip install langfuse --break-system-packages --quiet

if ping -c 1 host.docker.internal >/dev/null 2>&1; then
    echo "[network] Host reachable: host.docker.internal"
else
    echo "[network] Host unreachable — check init-firewall.sh"
fi

echo "[network] Checking Langfuse on port 3052..."
if curl -s -o /dev/null -w "%{http_code}" http://host.docker.internal:3052/api/public/health | grep -q "200"; then
    echo "[network] Langfuse is reachable."
else
    echo "[network] Langfuse unreachable on 3052."
    echo "[network] Run: langfuse-setup"
fi
