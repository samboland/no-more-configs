---
name: nmc-system
description: No More Configs (NMC) system reference. Use when the user asks about the devcontainer, Docker setup, container configuration, workspace layout, installed tools, firewall, networking, Langfuse tracing, MCP gateway, mounted volumes, ports, environment variables, shell configuration, plugin system architecture, how plugins are installed, how hooks are registered, how the install script works, or any question about how this development environment is set up and configured.
license: MIT
metadata:
  author: Sam Boland
  version: "3.0.0"
---

# No More Configs — System Reference

Complete reference for the development environment Claude Code runs inside. Use this to answer questions about the container setup, networking, tools, configuration, and plugin system without searching the filesystem.

For active introspection, use the `/nmc` command. For troubleshooting, the `nmc-diagnostics` agent investigates runtime state.

## Architecture

```
Host (VS Code + Docker Desktop)
 ├── VS Code → Dev Container (Debian/Node 20, user: node)
 │   ├── Claude Code CLI + Codex CLI + custom skills + GSD framework
 │   ├── NMC plugin system (skills, commands, agents, hooks)
 │   ├── iptables whitelist firewall
 │   └── /var/run/docker.sock (bind-mounted from host)
 │
 └── Sidecar Stack (Docker-outside-of-Docker, same Docker engine)
     ├── langfuse-web          127.0.0.1:3052 → :3000
     ├── langfuse-worker       127.0.0.1:3030 → :3030
     ├── docker-mcp-gateway    127.0.0.1:8811 → :8811
     ├── postgres              127.0.0.1:5433 → :5432
     ├── clickhouse            127.0.0.1:8124 → :8123
     ├── redis                 127.0.0.1:6379 → :6379
     └── minio                 127.0.0.1:9090 → :9000 (console :9091 → :9001)
```

The dev container and sidecar stack are sibling containers sharing the host Docker engine. They communicate via `host.docker.internal`.

## Configuration System

All container configuration is driven by two files at the repo root:

| File | Tracked | Purpose |
|------|---------|---------|
| `config.json` | Yes | Non-secret settings: firewall domains, Langfuse host, VS Code git scan paths, MCP servers, plugin enable/disable |
| `secrets.json` | No (gitignored) | Credentials: Claude/Codex auth, git identity, infra secrets |

On container creation, `install-agent-config.sh` reads both files and generates:
- `~/.claude/settings.json` (hooks, env vars, permissions — merged from `agent-config/settings.json.template` + plugins + GSD)
- `~/.claude/skills/`, `~/.claude/hooks/`, `~/.claude/commands/`, `~/.claude/agents/` (copied from `agent-config/` + plugins)
- `~/.codex/skills/`, `~/.codex/prompts/` (skills and commands mirrored for Codex, frontmatter stripped)
- `.devcontainer/firewall-domains.conf` (core domains + `config.json` extras)
- `.vscode/settings.json` (git scan paths from `config.json` + auto-detected repos)
- `~/.claude/.mcp.json` (Claude MCP server config from enabled templates)
- `~/.codex/config.toml` (Codex config including `[mcp_servers.*]` from enabled templates)
- `~/.claude/.credentials.json` (restored from `secrets.json`)
- `~/.codex/auth.json` (restored from `secrets.json`)
- `infra/.env` (generated from `secrets.json` infra section via `langfuse-setup --generate-env`)

> **Never use `settings.local.json` for hooks, env vars, or other functional settings.** Claude Code does not execute hooks defined in `settings.local.json`. All hooks, environment variables, and permissions must be in `settings.json`. The `settings.local.json` file is only for per-machine overrides that should not be committed (e.g., project-level `.claude/settings.local.json` for repo-specific allow rules). The install script merges everything into `settings.json`.

### Credential Round-Trip

```
secrets.json → install-agent-config.sh → runtime files
                                              ↓
secrets.json ← save-secrets ← live container
```

`save-secrets` (installed to PATH) captures live Claude credentials, Codex credentials, git identity, and infrastructure secrets back into `secrets.json` for persistence across rebuilds.

## Plugin System

Plugins are bundled packages of skills, commands, agents, and hooks under `agent-config/plugins/`. Each plugin has a `plugin.json` manifest.

### Plugin Structure

```
agent-config/plugins/my-plugin/
├── plugin.json           # Required manifest
├── skills/               # Optional — SKILL.md directories
├── commands/             # Optional — slash command .md files
├── agents/               # Optional — agent definition .md files
└── hooks/                # Optional — hook scripts referenced by plugin.json
```

### plugin.json Format

```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "description": "What this plugin does",
  "hooks": {
    "Stop": [{ "type": "command", "command": "bash ~/.claude/hooks/my-hook.sh" }]
  },
  "env": { "MY_VAR": "value" }
}
```

### Install Flow

On container creation, the install script:
1. Discovers plugins in `agent-config/plugins/*/`
2. Checks `config.json` `.plugins.{name}.enabled` (default: true)
3. Validates `plugin.json` exists and name matches directory
4. Copies skills → `~/.claude/skills/` + `~/.codex/skills/`, commands → `~/.claude/commands/` + `~/.codex/prompts/`, agents → `~/.claude/agents/`, hooks → `~/.claude/hooks/`
5. Clones project `.claude/` content (skills + commands) into `~/.codex/` for Codex (skips projects in `codex.skip_dirs`)
6. Accumulates hook registrations and env vars from all plugins
6. After GSD install + enforcement, merges template hooks + env into `~/.claude/settings.json`
7. Merges plugin hooks into `~/.claude/settings.json` `.hooks` (appended, not overwritten)
8. Merges plugin env vars into `~/.claude/settings.json` `.env`

### Plugin Control via config.json

```json
{
  "plugins": {
    "my-plugin": { "enabled": false },
    "other-plugin": { "enabled": true, "env": { "OVERRIDE": "value" } }
  }
}
```

- Not mentioned = enabled by default
- `enabled: false` = fully skipped (no files copied, no hooks registered)
- `env` overrides take precedence over plugin.json defaults

## Workspace Layout

```
/workspace/
├── .devcontainer/
│   ├── Dockerfile              # Node 20 + Claude Code + GSD + Docker CLI + firewall tools
│   ├── devcontainer.json       # Mounts, ports, env vars, lifecycle hooks
│   ├── install-agent-config.sh # Master config generator (reads config.json + secrets.json)
│   ├── init-firewall.sh        # iptables whitelist (runs on every start)
│   ├── refresh-firewall-dns.sh # DNS refresh for firewall domains
│   ├── save-secrets.sh         # Credential capture helper (installed to PATH)
│   ├── langfuse-setup.sh       # Langfuse stack setup (installed to PATH as langfuse-setup)
│   ├── init-gsd.sh             # GSD framework installer
│   ├── setup-container.sh      # Post-create setup (git config, Docker socket)
│   ├── setup-network-checks.sh # Langfuse pip install + connectivity checks
│   └── mcp-setup-bin.sh        # MCP auto-config (installed to PATH as mcp-setup)
│
├── agent-config/               # Version-controlled agent config source
│   ├── settings.json.template  # Claude Code settings with {{PLACEHOLDER}} tokens
│   ├── mcp-templates/          # MCP server templates
│   │   └── mcp-gateway.json
│   ├── skills/                 # Standalone skills (copied to ~/.claude/skills/)
│   ├── hooks/                  # Standalone hooks (copied to ~/.claude/hooks/)
│   │   └── langfuse_hook.py    # Langfuse tracing hook
│   └── plugins/                # NMC plugins
│       ├── nmc-langfuse-tracing/ # Langfuse conversation tracing
│       ├── nmc/                # System introspection & diagnostics
│       ├── nmc-ralph-loop/     # Self-referential loop technique
│       ├── plugin-dev/         # Plugin development toolkit
│       └── frontend-design/    # Frontend design skills
│
├── config.json                 # Master non-secret settings
│
├── infra/                      # Langfuse + MCP gateway infrastructure
│   ├── docker-compose.yml      # 8-service stack
│   ├── .env                    # Generated from secrets.json by langfuse-setup (gitignored)
│   ├── data/                   # Persistent bind mounts: postgres, clickhouse, minio (gitignored)
│   ├── mcp/mcp.json            # MCP gateway server configuration
│   └── scripts/                # MCP verification scripts
│
├── .planning/                  # GSD project planning state
├── projects/                # Working directory for repos developed in the sandbox
└── review/                     # Reviews, specs, external AI output
```

## Key Paths

| Path | Purpose |
|------|---------|
| `/workspace/config.json` | Master settings (firewall, langfuse, vscode, mcp, plugins) |
| `/workspace/secrets.json` | Credentials (Claude auth, Codex auth, infra secrets) — gitignored |
| `/workspace/agent-config/` | Version-controlled templates, skills, hooks, plugins |
| `/home/node/.claude/` | Container-local Claude config (generated at build time) |
| `/home/node/.codex/` | Codex CLI config, credentials, skills, and prompts |
| `/home/node/.codex/config.toml` | Codex config (model, MCP servers, approval policy) |
| `/home/node/.codex/auth.json` | Codex OAuth credentials (restored from secrets.json) |
| `/home/node/.codex/skills/` | Skills mirrored from Claude (global + project) |
| `/home/node/.codex/prompts/` | Commands mirrored from Claude (frontmatter stripped) |
| `/home/node/.codex/sessions/` | Conversation history (Docker volume, persists across rebuilds) |
| `/home/node/.claude/commands/gsd/` | GSD slash commands (30+) |
| `/home/node/.claude/agents/gsd-*.md` | GSD specialized agents (11 agents) |
| `/home/node/.claude/hooks/langfuse_hook.py` | Langfuse tracing hook |
| `/home/node/.claude/settings.json` | Claude Code settings (hooks, env vars, permissions, model) |
| `/home/node/.claude/.mcp.json` | MCP server configuration |
| `/usr/local/bin/save-secrets` | Credential capture helper |
| `/usr/local/bin/langfuse-setup` | Langfuse stack setup (generate secrets, start, verify) |
| `/usr/local/bin/init-firewall.sh` | Firewall script |
| `/usr/local/bin/mcp-setup` | MCP auto-config script |
| `/var/run/docker.sock` | Host Docker socket (bind-mounted) |
| `/commandhistory/` | Persistent shell history (Docker volume) |

## Ports

| Port | Service | Notes |
|------|---------|-------|
| **3052** | Langfuse Web UI | From container: `http://host.docker.internal:3052`. From host: `http://localhost:3052` |
| 3030 | Langfuse Worker | Internal async job processing |
| 5433 | PostgreSQL | Offset from 5432 to avoid collisions |
| 6379 | Redis | Cache + job queue |
| 8124 | ClickHouse | Analytics engine |
| **8811** | MCP Gateway | Model Context Protocol gateway (loopback-only) |
| 9090 | MinIO S3 | Object storage |
| 9091 | MinIO Console | Admin UI |
| 3000 | Dev App | Forwarded by devcontainer.json (silent) |
| 8787 | Dev App 2 | Forwarded by devcontainer.json (silent) |

## Environment Variables

### Set in devcontainer.json (containerEnv)

| Variable | Value | Purpose |
|----------|-------|---------|
| `NODE_OPTIONS` | `--max-old-space-size=4096` | 4GB Node.js heap |
| `POWERLEVEL9K_DISABLE_GITSTATUS` | `true` | Prevent slow git status in prompt |
| `LANGFUSE_HOST` | `http://host.docker.internal:3052` | Langfuse endpoint |
| `MCP_GATEWAY_URL` | `http://host.docker.internal:8811` | MCP gateway endpoint |

### Set in ~/.claude/settings.json (env)

| Variable | Value | Purpose |
|----------|-------|---------|
| `TRACE_TO_LANGFUSE` | `true` | Master switch for tracing hook |
| `LANGFUSE_PUBLIC_KEY` | `pk-lf-local-claude-code` | Auto-provisioned project key |
| `LANGFUSE_SECRET_KEY` | _(from secrets.json)_ | Generated by langfuse-setup |
| `LANGFUSE_HOST` | `http://host.docker.internal:3052` | Langfuse API endpoint |

## Installed Tools

| Category | Tools |
|----------|-------|
| **Runtime** | Node.js 20, Python 3.11, npm 10, zsh 5.9 |
| **Shell** | Oh-My-Zsh, Powerlevel10k theme, fzf, plugins: git + fzf |
| **VCS** | Git 2.39, GitHub CLI (gh), git-delta 0.18.2 |
| **Docker** | Docker CLI 29.2, Docker Compose v2 |
| **Network** | curl, wget, iptables, ipset, iproute2, dnsutils, aggregate |
| **Editors** | nano (default), vim |
| **Utilities** | jq, fzf, unzip, man-db, procps, less |
| **Python** | langfuse, openai, opentelemetry-api, httpx |
| **npm global** | get-shit-done-cc, claude (latest), @openai/codex (latest) |

## Shell Shortcuts

| Command | Action |
|---------|--------|
| `claude` | Runs with bypassPermissions by default (set in global settings.json) |
| `clauder` | Alias for `claude --resume` |
| `codex` | OpenAI Codex CLI — agentic coding with GPT-5.3-Codex |
| `codexr` | Alias for `codex resume` |
| `save-secrets` | Capture live credentials to secrets.json |
| `langfuse-setup` | Generate secrets, start Langfuse stack, verify health |
| `mcp-setup` | Regenerate MCP configs (Claude .mcp.json + Codex config.toml) + gateway health check |

## Hooks

| Event | Script | Purpose |
|-------|--------|---------|
| **Stop** | `python3 /home/node/.claude/hooks/langfuse_hook.py` | Send conversation traces to Langfuse |
| **Stop** | `bash /home/node/.claude/hooks/stop-hook.sh` | Ralph Wiggum loop continuation |
| **SessionStart** | `node /home/node/.claude/hooks/gsd-check-update.js` | Check for GSD framework updates |
| **StatusLine** | `node /home/node/.claude/hooks/gsd-statusline.js` | Show GSD state in terminal status line |

## Firewall

The iptables-based firewall (`init-firewall.sh`) runs on every container start. Default policy is **DROP** — only whitelisted domains are reachable.

Core domains (30, always included): Anthropic, GitHub, npm, PyPI, Debian, VS Code Marketplace, Cloudflare, Google Storage, OpenAI (API, Auth, Platform, ChatGPT), Google AI API.

Extra domains from `config.json → firewall.extra_domains` are appended.

To temporarily allow a blocked domain:

```bash
IP=$(dig +short example.com | tail -1)
sudo iptables -I OUTPUT -d "$IP" -j ACCEPT
```

To permanently add: edit `config.json → firewall.extra_domains` and rebuild.

## Mounts & Volumes

| Source | Target | Type | Purpose |
|--------|--------|------|---------|
| Host Docker socket | `/var/run/docker.sock` | Bind | Docker-outside-of-Docker |
| `claude-code-bashhistory` | `/commandhistory` | Volume | Shell history persists across rebuilds |
| `claude-code-conversations` | `/home/node/.claude/projects` | Volume | Claude conversation data persists across rebuilds |
| `codex-conversations` | `/home/node/.codex/sessions` | Volume | Codex conversation data persists across rebuilds |
| Workspace | `/workspace` | Bind | Delegated consistency |

Note: No `~/.claude` bind mount. All Claude config is generated container-locally by `install-agent-config.sh`.

## Lifecycle Commands

### postCreateCommand (first build only)

1. `setup-container.sh` — Docker socket perms, git config
2. `install-agent-config.sh` — Reads config.json + secrets.json, generates all runtime config, installs skills/hooks/commands, installs plugins, installs GSD framework

### postStartCommand (every start)

1. `init-firewall.sh` — iptables whitelist
2. Git trust + line ending config
3. `setup-network-checks.sh` — Langfuse pip install + connectivity checks
4. `init-gsd.sh` — GSD command check
5. `mcp-setup` — Regenerate MCP configs (Claude + Codex) + gateway health check

## Rebuild Behavior

Rebuilding the dev container does NOT affect the sidecar stack (Langfuse runs on host Docker engine, data in bind mounts under `infra/data/`). If `secrets.json` contains credentials, they are automatically restored on rebuild by `install-agent-config.sh`. Run `save-secrets` before rebuilding to capture current credentials.

## Docker Run Capabilities

- `NET_ADMIN` + `NET_RAW` — required for iptables firewall
- `--add-host=host.docker.internal:host-gateway` — enables host resolution

## Permissions

- **Node user:** passwordless sudo (`NOPASSWD:ALL`)
- **Docker socket:** `chmod 666` applied on create
