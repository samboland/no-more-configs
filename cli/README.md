# no-more-configs

One-command installer & updater for [No More Configs](https://github.com/agomusio/no-more-configs) — a clone-and-go VS Code devcontainer built for Claude Code.

## Install

```bash
npx no-more-configs
```

Clones the repo, prints next steps, and tries to open VS Code automatically.

## Update

Run the same command inside (or pointing at) an existing install:

```bash
npx no-more-configs
```

If devcontainer files changed, you'll be advised to rebuild the container.

## Usage

```
npx no-more-configs [directory]   # Install or update (default: no-more-configs)
npx no-more-configs --help        # Show help
npx no-more-configs --version     # Show version
```

## Prerequisites

- [Node.js](https://nodejs.org/) >= 18 (for npx)
- [Git](https://git-scm.com/)
- [VS Code](https://code.visualstudio.com/) with the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Windows) or [Docker Engine](https://docs.docker.com/engine/install/) (Linux)

## What You Get

A fully configured devcontainer with Claude Code, Codex CLI, iptables firewall, plugin system, Langfuse tracing, and more. See the [main README](https://github.com/agomusio/no-more-configs) for details.

## License

MIT
