#!/bin/bash
# Install optional SDKs based on config.json → sdks section
# Runs during postCreate — installs persist for the container's lifetime
# Temporarily opens firewall for required domains, then refreshes DNS after

set -e

CONFIG_FILE="${CLAUDE_WORKSPACE:-/workspace}/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "⚠ config.json not found — skipping SDK installs"
    exit 0
fi

# Helper: temporarily allow a domain through the firewall
allow_domain() {
    local domain="$1"
    local ips
    ips=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.' || true)
    for ip in $ips; do
        sudo ipset add allowed-domains "$ip" -exist 2>/dev/null || true
    done
}

# .NET SDKs (9.0 + 10.0)
DOTNET_ENABLED=$(jq -r '.sdks.dotnet // false' "$CONFIG_FILE" 2>/dev/null || echo "false")

if [ "$DOTNET_ENABLED" = "true" ]; then
    if command -v dotnet &>/dev/null; then
        echo "✓ .NET already installed — skipping"
    else
        echo "Installing .NET SDKs (9.0 + 10.0)..."
        # Open firewall for .NET download domains
        for domain in dot.net dotnet.microsoft.com builds.dotnet.microsoft.com dotnetcli.azureedge.net dotnetbuilds.azureedge.net; do
            allow_domain "$domain"
        done
        curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
        chmod +x /tmp/dotnet-install.sh
        /tmp/dotnet-install.sh --channel 9.0 --install-dir /usr/share/dotnet
        /tmp/dotnet-install.sh --channel 10.0 --quality preview --install-dir /usr/share/dotnet
        rm /tmp/dotnet-install.sh
        sudo ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet
        echo "✓ .NET $(dotnet --version) installed"
    fi
else
    echo "· .NET SDK disabled — set sdks.dotnet: true in config.json to enable"
fi
