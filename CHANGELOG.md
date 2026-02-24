# Changelog

All notable changes to No More Configs will be documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioned per [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

GitHub releases should use the title format: **vX.Y.Z — YYYY-MM-DD**

---

## [1.2.4] - 2026-02-24

### Fixed

- **`initializeCommand` failing on some platforms** — switched from string form to exec-form array in `devcontainer.json`, avoiding shell parsing issues that prevented container creation

---

## [1.2.3] - 2026-02-24

### Added

- **Opt-in .NET SDK** — install .NET 9.0 + 10.0 at container start by setting `sdks.dotnet: true` in `config.json`. Disabled by default to keep build times fast
- `install-sdks.sh` — new postCreate script handles SDK installation with automatic firewall domain allowlisting
- `save-config` now persists the `sdks` section

### Fixed

- `dotnet-install.sh` now runs with `sudo` to write to `/usr/share/dotnet`

### Changed

- .NET SDK removed from devcontainer `features` — no longer installed at build time. This fixes slow builds and build failures for users who don't need .NET
- Unused `NPM_TOKEN` secret removed from publish workflow

---

## [1.2.2] - 2026-02-23

### Added

- **Linux support** — NMC now runs on Linux (tested on Ubuntu 24) with just VS Code and Docker Engine. No WSL2 or Docker Desktop required.

### Changed

- `initializeCommand` switched from PowerShell to Node.js for cross-platform compatibility (Windows + Linux)
- README updated with platform-specific prerequisites (Windows and Linux sections)
- ENOENT known issue marked as Windows-only

---

## [1.2.1] - 2026-02-21

### Added

- **`config.json` auto-creation** — `initializeCommand` (PowerShell) creates `config.json` from `config.default.json` before the container builds, so new users always have a config file without manual steps
- **`config.default.json`** — ships with the repo; contains all default values for every config section
- **`CLAUDE.md`** — workspace-level context for Claude: project layout (`projects/`) and Next.js fast refresh fix (`--webpack` flag + webpack polling)

### Changed

- `nmc-langfuse-tracing` plugin now **disabled by default** — enable in `config.json → plugins` when ready to use Langfuse
- `mcp-gateway` now **disabled by default** in both `config.default.json` and `save-config` fallback
- README updated to reflect Windows-only support and corrected opt-in defaults

### Fixed

- Docker socket `chmod 666` now guarded with `-S` check — missing socket no longer aborts `postCreate`
- `save-config` now uses atomic write (temp file + `mv`) to prevent config truncation on `jq` failure

---

## [1.2.0] - 2026-02-20

### Added

- **Codex command mirroring** — all commands (standalone, plugin, and project plugin) are now mirrored to `~/.codex/prompts/` with Claude-specific frontmatter (`allowed-tools`, `hide-from-slash-command-tool`) automatically stripped
- **Project `.claude/` → Codex cloning** — each project's `.claude/skills/` and `.claude/commands/` are cloned into Codex's global `~/.codex/skills/` and `~/.codex/prompts/` on rebuild, independent of project plugin scanning
- **Codex session persistence** — new `codex-conversations` Docker volume mounts `~/.codex/sessions/` so Codex conversation history survives container rebuilds
- **`codex.skip_dirs`** — new `config.json` field to exclude specific project directories from Codex cloning (e.g. `"skip_dirs": ["my-claude-only-project"]`)
- `.codex/` automatically gitignored in project repos as a placeholder for future per-project Codex support
- **Claude memory persistence** — `save-config` now saves `~/.claude/projects/*/memory/` files to `agent-config/memory/`, restored automatically on rebuild
- **Selective home installs** — new `config.json` fields `agent.home_installs.skills` and `agent.home_installs.commands` to install only selected skills/commands (default: all)
- **`project_plugin_scan`** — new `config.json` field to enable/disable project-repo plugin scanning (default: disabled)

### Changed

- Codex CLI now installed with `@latest` tag in Dockerfile to ensure newest version on each build
- `save-config` now generates `codex.skip_dirs` field (defaults to empty array)
- MCP gateway now defaults to disabled in `save-config` (`mcp-gateway.enabled: false`) — enable manually in `config.json` when needed

### Fixed

- `save-config` now preserves `firewall.enabled: false` instead of resetting it to `true` on every run

---

## [1.1.2] - 2026-02-17

### Added

- GitHub Actions VS Code extension added to devcontainer
- Automated npm publishing via GitHub Actions with OIDC trusted publishing and provenance

---

## [1.1.1] - 2026-02-17 `released`

### Changed

- **`save-config` rewrite** — now writes all config sections (firewall, codex, infra, langfuse, vscode, mcp_servers, plugins) with sensible defaults, not just `claude_code` preferences. Auto-discovers installed plugins. Existing non-default values are preserved
- README: added §3 "Clone Your Projects" with project setup instructions
- README: npx installer commands updated to `@latest` throughout

### Fixed

- **Update notification showing backwards versions** — `nmc-update` plugin now only notifies when origin is ahead of local

---

## [1.1.0] - 2026-02-16 `released`

### Added

- **`npx no-more-configs@latest`** — zero-dependency ESM CLI for installing and updating NMC from the host. Handles fresh clone with VS Code auto-open, dirty-tree warnings, `.devcontainer/` tree-hash comparison, and rebuild detection. Published to npm as [`no-more-configs`](https://www.npmjs.com/package/no-more-configs)
- **`nmc-update`** — in-container update command (`/usr/local/bin/nmc-update`). Fetches, pulls, compares devcontainer tree hash, advises rebuild when needed
- **OMZ update notification plugin** — background version check every 24 hours, colored banner on shell open when a new version is available
- npm credential persistence — `save-secrets` captures `~/.npmrc` auth token, restored on rebuild
- Firewall disable option — set `firewall.enabled: false` in `config.json` to flush all iptables rules
- Azure Blob Storage (`*.blob.core.windows.net`) added to core firewall domains (VS Code extension downloads)

### Changed

- Devcontainer renamed from "Claude Code Sandbox" to "No More Configs"
- README: `npx no-more-configs@latest` as primary install method with npm badge
- README: §5 Updating now documents both host-side (`npx no-more-configs@latest`) and in-container (`nmc-update`) update paths
- README: `secrets.json` documentation expanded with full key reference table (all credential sources and their origins)
- Core firewall domain count updated from 31 to 32

### Fixed

- Architecture diagram not centered in README

---

## [1.0.3] - 2026-02-16 `released`

### Fixed

- Project-repo plugins (`projects/*/.claude/plugins/*/`) not loading — install script now auto-discovers and copies their components (skills, commands, agents, hooks) to runtime locations, same as agent-config plugins
- Project plugin commands now namespaced into `commands/<plugin-name>/` subdirectories to avoid collisions (e.g. `uproot:build-hook`)
- Project plugin `hooks.json` (settings format) merged directly into `settings.json` instead of through the agent-config accumulator which wrapped them in an extra layer, causing `Invalid Settings` errors
- Hooks and env vars now reset before rebuilding on each install run, preventing stale entries from persisting across re-runs

---

## [1.0.2] - 2026-02-16 `released`

### Changed

- `gitprojects/` renamed to `projects/` — simpler, less confusing for new users
- `save-secrets` now captures GitHub CLI credentials; restored automatically on rebuild
- README version badge now auto-updates from GitHub releases

### Removed

- `config.example.json`, `secrets.example.json` — schema is documented inline in the README

---

## [1.0.1] - 2026-02-16 `released`

### Fixed

- `langfuse-setup` MinIO/ClickHouse data directory ownership — replaced busybox chown (broken in Docker-outside-of-Docker) with direct `sudo chown`
- GSD framework not updating on container rebuild — now updates to latest on every container start

### Changed

- `config.json` no longer ships in repo — created at runtime by `save-config` and `save-secrets`
- README fully redesigned — centered header, shields.io badges, feature matrix, value proposition
- Copyright year corrected to 2026
- Platform support clarified — tested on Windows (WSL2), macOS/Linux untested
- Acknowledgments expanded — Claude Code credited for plugins and hooks framework, not just devcontainer
- GSD framework description clarified

### Removed

- `review/` directory (internal-only, not useful for end users)
- Personal author name replaced with `agomusio` in plugin and skill metadata

### Added

- `CHANGELOG.md` — project history and release notes
- `TROUBLESHOOTING.md` — common Docker Desktop, WSL2, networking, and filesystem issues with fixes

---

## [1.0.0] - 2026-02-16 `released`

First public release. Everything below is what ships out of the box.

### Core

- **Claude Code** CLI (latest) — Opus 4.6, high effort, bypass permissions
- **Codex CLI** (latest) — GPT-5.3-Codex, full-auto mode, file-based auth
- **Two-file configuration** — `config.json` (settings) + `secrets.json` (credentials, gitignored)
- **Credential persistence** — `save-secrets` captures auth tokens, git identity, and infra secrets; restored automatically on rebuild
- **Preference persistence** — `save-config` captures Claude Code preferences; restored on rebuild

### Plugin System

- Self-registering plugins via `agent-config/plugins/*/plugin.json`
- Hook accumulation (multiple plugins on same events)
- Environment variable injection with `{{TOKEN}}` hydration from `secrets.json`
- Plugin MCP server registration with `_source` tagging
- Config-driven enable/disable and env overrides
- Validation with warnings recap (missing scripts, file conflicts, unresolved tokens)
- **Included plugins:** `nmc`, `nmc-langfuse-tracing`, `nmc-ralph-loop`, `plugin-dev`, `frontend-design`

### Infrastructure

- **iptables firewall** — default-deny, 31 core domains, auto-generated VS Code extension CDN domains, user-configurable extras
- **Langfuse observability** — self-hosted stack (Langfuse + PostgreSQL + ClickHouse + Redis + MinIO), one-command setup via `langfuse-setup`
- **MCP gateway** — Docker MCP Gateway with health checking and auto-configuration
- **Codex MCP server** — optional, lets Claude delegate to Codex mid-session
- **GSD framework** — 30+ slash commands, 11 specialized agents, installed via `npx get-shit-done-cc`

### Developer Experience

- Oh-My-Zsh with Powerlevel10k, fzf, git-delta, GitHub CLI
- Shell aliases: `claude`, `clauder`, `codex`, `codexr`, `save-secrets`, `save-config`, `langfuse-setup`, `mcp-setup`
- Lifecycle log aliases: `slc` (postCreate), `sls` (postStart)
- Cross-agent skills (Claude + Codex)
- Upstream plugin auto-download at build time (plugin-dev, frontend-design)

### Files

- `config.example.json` — annotated config reference
- `secrets.example.json` — secret schema reference
- `LICENSE` — MIT

[1.2.4]: https://github.com/agomusio/no-more-configs/compare/v1.2.3...HEAD
[1.2.3]: https://github.com/agomusio/no-more-configs/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/agomusio/no-more-configs/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/agomusio/no-more-configs/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/agomusio/no-more-configs/compare/v1.1.2...v1.2.0
[1.1.2]: https://github.com/agomusio/no-more-configs/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/agomusio/no-more-configs/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/agomusio/no-more-configs/compare/v1.0.3...v1.1.0
[1.0.3]: https://github.com/agomusio/no-more-configs/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/agomusio/no-more-configs/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/agomusio/no-more-configs/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/agomusio/no-more-configs/releases/tag/v1.0.0
