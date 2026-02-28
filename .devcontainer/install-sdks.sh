#!/bin/bash
# Install optional SDKs based on config.json → sdks section
# Runs during postCreate — installs persist for the container's lifetime
# Temporarily opens firewall for required domains, then refreshes DNS after
# NOTE: No set -e — SDK installs are optional and must not block install-agent-config.sh

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
        if curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh; then
            chmod +x /tmp/dotnet-install.sh
            sudo /tmp/dotnet-install.sh --channel 9.0 --install-dir /usr/share/dotnet || echo "⚠ .NET 9.0 install failed — continuing"
            sudo /tmp/dotnet-install.sh --channel 10.0 --quality preview --install-dir /usr/share/dotnet || echo "⚠ .NET 10.0 preview install failed — continuing"
            rm -f /tmp/dotnet-install.sh
            sudo ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet 2>/dev/null || true
            if command -v dotnet &>/dev/null; then
                echo "✓ .NET $(dotnet --version) installed"
            else
                echo "⚠ .NET install completed with errors — dotnet not available"
            fi
        else
            echo "⚠ Failed to download .NET install script — skipping"
        fi
    fi
else
    echo "· .NET SDK disabled — set sdks.dotnet: true in config.json to enable"
fi

# Rust (via rustup)
RUST_ENABLED=$(jq -r '.sdks.rust // false' "$CONFIG_FILE" 2>/dev/null || echo "false")

if [ "$RUST_ENABLED" = "true" ]; then
    if command -v rustc &>/dev/null; then
        echo "✓ Rust already installed — skipping"
    else
        echo "Installing Rust via rustup..."
        for domain in sh.rustup.rs static.rust-lang.org; do
            allow_domain "$domain"
        done
        if curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y; then
            # Source cargo env for this script
            . "$HOME/.cargo/env" 2>/dev/null || true
            if command -v rustc &>/dev/null; then
                echo "✓ Rust $(rustc --version) installed"
            else
                echo "⚠ Rust install completed with errors — rustc not available"
            fi
        else
            echo "⚠ Failed to install Rust — skipping"
        fi
    fi
else
    echo "· Rust SDK disabled — set sdks.rust: true in config.json to enable"
fi

# Go (official tarball)
GO_ENABLED=$(jq -r '.sdks.go // false' "$CONFIG_FILE" 2>/dev/null || echo "false")

if [ "$GO_ENABLED" = "true" ]; then
    if command -v go &>/dev/null; then
        echo "✓ Go already installed — skipping"
    else
        echo "Installing Go..."
        for domain in go.dev dl.google.com; do
            allow_domain "$domain"
        done
        ARCH=$(dpkg --print-architecture)
        case "$ARCH" in
            amd64) GO_ARCH="amd64" ;;
            arm64) GO_ARCH="arm64" ;;
            *) echo "⚠ Unsupported architecture $ARCH for Go — skipping"; GO_ARCH="" ;;
        esac
        if [ -n "$GO_ARCH" ]; then
            GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" 2>/dev/null | head -1)
            if [ -n "$GO_VERSION" ]; then
                if curl -fsSL -o /tmp/go.tar.gz "https://dl.google.com/go/${GO_VERSION}.linux-${GO_ARCH}.tar.gz"; then
                    sudo tar -C /usr/local -xzf /tmp/go.tar.gz
                    rm -f /tmp/go.tar.gz
                    export PATH="/usr/local/go/bin:$PATH"
                    if command -v go &>/dev/null; then
                        echo "✓ Go $(go version) installed"
                    else
                        echo "⚠ Go install completed with errors — go not available"
                    fi
                else
                    echo "⚠ Failed to download Go tarball — skipping"
                fi
            else
                echo "⚠ Failed to determine latest Go version — skipping"
            fi
        fi
    fi
else
    echo "· Go SDK disabled — set sdks.go: true in config.json to enable"
fi

# Deno
DENO_ENABLED=$(jq -r '.sdks.deno // false' "$CONFIG_FILE" 2>/dev/null || echo "false")

if [ "$DENO_ENABLED" = "true" ]; then
    if command -v deno &>/dev/null; then
        echo "✓ Deno already installed — skipping"
    else
        echo "Installing Deno..."
        for domain in deno.land dl.deno.land github.com; do
            allow_domain "$domain"
        done
        if curl -fsSL https://deno.land/install.sh | sh; then
            export PATH="$HOME/.deno/bin:$PATH"
            if command -v deno &>/dev/null; then
                echo "✓ Deno $(deno --version | head -1) installed"
            else
                echo "⚠ Deno install completed with errors — deno not available"
            fi
        else
            echo "⚠ Failed to install Deno — skipping"
        fi
    fi
else
    echo "· Deno SDK disabled — set sdks.deno: true in config.json to enable"
fi
