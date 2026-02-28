FROM node:20

ARG TZ
ENV TZ="$TZ"

# Prevent interactive prompts and per-step delays during apt installs
ENV DEBIAN_FRONTEND=noninteractive

# Intentionally use latest Claude Code on each build for fast access to updates.
ARG CLAUDE_CODE_VERSION=latest

# Install basic development tools and iptables/ipset
# ADDED: lsb-release, curl, ca-certificates for Docker install
RUN apt-get update && apt-get install -y --no-install-recommends \
  apt-utils \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  python3-pip \
  python3-venv \
  lsb-release \
  curl \
  ca-certificates \
  iputils-ping \
  locales \
  postgresql-client \
  redis-tools \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# ADDED: Install Docker CLI (Docker-outside-of-Docker)
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce-cli docker-compose-plugin && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Optional SDKs are installed at postCreate time via install-sdks.sh
# (config.json → sdks.dotnet, etc.)

# Root-phase setup: npm-global dir, bash history, workspace dirs, git-delta, sudoers
ARG USERNAME=node
ARG GIT_DELTA_VERSION=0.18.2
RUN mkdir -p /usr/local/share/npm-global && \
    chown -R node:node /usr/local/share && \
    mkdir /commandhistory && \
    touch /commandhistory/.bash_history && \
    chown -R $USERNAME /commandhistory && \
    mkdir -p /workspace /home/node/.claude && \
    chown -R node:node /workspace /home/node/.claude && \
    ARCH=$(dpkg --print-architecture) && \
    curl -fsSL -o "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" \
      "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    echo "node ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/node && \
    chmod 0440 /etc/sudoers.d/node

WORKDIR /workspace

# Set up non-root user
USER node

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Set the default shell to zsh rather than sh
ENV SHELL=/bin/zsh

# Set the default editor and visual
ENV EDITOR=nano
ENV VISUAL=nano

# Workspace path references (used by scripts, aliases, and runtime config)
ENV LANGFUSE_STACK_DIR=/workspace/infra
ENV CLAUDE_WORKSPACE=/workspace

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(curl -fsSL https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# Runtimes: corepack (pnpm/yarn), Bun, Claude Code
RUN sudo corepack enable && corepack prepare pnpm@latest yarn@stable --activate && \
    curl -fsSL https://bun.sh/install | bash && \
    curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}"

ENV PATH="/home/node/.bun/bin:/home/node/.local/bin:${PATH}"

# Skip permissions for Claude in WSL
ENV CLAUDE_BYPASS_PERMISSIONS=true

# npm global installs, shell config, and aliases
RUN echo "export LANGFUSE_STACK_DIR=/workspace/infra" >> /home/node/.bashrc && \
    echo "export CLAUDE_WORKSPACE=/workspace" >> /home/node/.bashrc && \
    echo "export LANGFUSE_STACK_DIR=/workspace/infra" >> /home/node/.zshrc && \
    echo "export CLAUDE_WORKSPACE=/workspace" >> /home/node/.zshrc && \
    claude --version && \
    npm install -g get-shit-done-cc @openai/codex@latest bmad-method && \
    mkdir -p /home/node/.codex/sessions && \
    echo "alias clauder='claude --resume'" >> /home/node/.bashrc && \
    echo "alias clauder='claude --resume'" >> /home/node/.zshrc && \
    echo "alias codexr='codex resume'" >> /home/node/.bashrc && \
    echo "alias codexr='codex resume'" >> /home/node/.zshrc && \
    echo "alias slc='cat /tmp/devcontainer-logs/postCreate.log'" >> /home/node/.bashrc && \
    echo "alias slc='cat /tmp/devcontainer-logs/postCreate.log'" >> /home/node/.zshrc && \
    echo "alias sls='cat /tmp/devcontainer-logs/postStart.log'" >> /home/node/.bashrc && \
    echo "alias sls='cat /tmp/devcontainer-logs/postStart.log'" >> /home/node/.zshrc

# Helper scripts and plugins
COPY --chown=node:node mcp-setup-bin.sh /tmp/mcp-setup-bin.sh
COPY --chown=node:node save-secrets.sh /tmp/save-secrets.sh
COPY --chown=node:node save-config.sh /tmp/save-config.sh
COPY --chown=node:node langfuse-setup.sh /tmp/langfuse-setup.sh
COPY --chown=node:node nmc-update.sh /tmp/nmc-update.sh
COPY --chown=node:node nmc-update.plugin.zsh /tmp/nmc-update.plugin.zsh
COPY --chown=node:node init-firewall.sh /tmp/init-firewall.sh
COPY --chown=node:node refresh-firewall-dns.sh /tmp/refresh-firewall-dns.sh
RUN sudo cp /tmp/mcp-setup-bin.sh /usr/local/bin/mcp-setup && \
    sudo cp /tmp/save-secrets.sh /usr/local/bin/save-secrets && \
    sudo cp /tmp/save-config.sh /usr/local/bin/save-config && \
    sudo cp /tmp/langfuse-setup.sh /usr/local/bin/langfuse-setup && \
    sudo cp /tmp/nmc-update.sh /usr/local/bin/nmc-update && \
    sudo cp /tmp/init-firewall.sh /usr/local/bin/init-firewall.sh && \
    sudo cp /tmp/refresh-firewall-dns.sh /usr/local/bin/refresh-firewall-dns.sh && \
    sudo chmod +x /usr/local/bin/mcp-setup \
                   /usr/local/bin/save-secrets \
                   /usr/local/bin/save-config \
                   /usr/local/bin/langfuse-setup \
                   /usr/local/bin/nmc-update \
                   /usr/local/bin/init-firewall.sh \
                   /usr/local/bin/refresh-firewall-dns.sh && \
    mkdir -p /home/node/.oh-my-zsh/custom/plugins/nmc-update && \
    cp /tmp/nmc-update.plugin.zsh /home/node/.oh-my-zsh/custom/plugins/nmc-update/nmc-update.plugin.zsh && \
    sed -i 's/plugins=(git fzf /plugins=(git fzf nmc-update /' /home/node/.zshrc && \
    rm /tmp/mcp-setup-bin.sh /tmp/save-secrets.sh /tmp/save-config.sh \
       /tmp/langfuse-setup.sh /tmp/nmc-update.sh /tmp/nmc-update.plugin.zsh \
       /tmp/init-firewall.sh /tmp/refresh-firewall-dns.sh
