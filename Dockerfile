# Client: only system libraries and Tailscale, Orca comes from the host AppImage at runtime.
# Server: tools for the projects, Orca lives in the home directory, see server/bin/orca-update.
FROM debian:trixie-slim AS base
RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && curl -fsSLo /usr/share/keyrings/tailscale-archive-keyring.gpg \
      https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian trixie main" \
      > /etc/apt/sources.list.d/tailscale.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      tailscale iproute2 iptables openssh-client git \
      libgtk-3-0t64 libnss3 libnspr4 libasound2t64 libgbm1 libdrm2 \
      libatk-bridge2.0-0t64 libatspi2.0-0t64 libcups2t64 libdbus-1-3 \
      libxcomposite1 libxdamage1 libxrandr2 libxkbcommon0 \
      libwayland-client0 libwayland-cursor0 libwayland-egl1 fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 30100 dev

FROM base AS server
ARG UV_VERSION=0.13.7
ARG FNM_VERSION=1.39.0
ARG FNM_SHA256=7807664f39d39fc518da1c35ba0181e4b3267603c4b1dedeb4b5fc6ae440a224
RUN curl -fsSLo /usr/share/keyrings/githubcli-archive-keyring.gpg \
      https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      gh mc htop jq ripgrep build-essential python3 xvfb xauth dbus-x11 procps less nano \
      unzip xz-utils file openssl libxss1 libxfixes3 \
    && curl -fsSL "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz" -o /tmp/uv.tar.gz \
    && echo "$(curl -fsSL "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz.sha256" | cut -d" " -f1)  /tmp/uv.tar.gz" | sha256sum -c - \
    && tar xzf /tmp/uv.tar.gz --strip-components=1 -C /usr/local/bin \
    && curl -fsSL "https://github.com/Schniz/fnm/releases/download/v$FNM_VERSION/fnm-linux.zip" -o /tmp/fnm.zip \
    && echo "$FNM_SHA256  /tmp/fnm.zip" | sha256sum -c - \
    && unzip -q /tmp/fnm.zip -d /usr/local/bin && chmod +x /usr/local/bin/fnm \
    && NODE=$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.version | startswith("v26."))][0].version') \
    && curl -fsSL "https://nodejs.org/dist/$NODE/node-$NODE-linux-x64.tar.xz" -o "/tmp/node-$NODE-linux-x64.tar.xz" \
    && curl -fsSL "https://nodejs.org/dist/$NODE/SHASUMS256.txt" | grep " node-$NODE-linux-x64.tar.xz$" | (cd /tmp && sha256sum -c -) \
    && mkdir /opt/node && tar xJf "/tmp/node-$NODE-linux-x64.tar.xz" --strip-components=1 -C /opt/node \
    && export PATH="/opt/node/bin:$PATH" \
    && npm install -g --prefix /usr/local pnpm @anthropic-ai/claude-code @openai/codex opencode-ai \
    && npx -y playwright install-deps chromium \
    && rm -rf /var/lib/apt/lists/* /tmp/* /root/.npm /root/.cache \
    && mkdir -p /etc/orca-pods /secrets && touch /etc/orca-pods/host.gitconfig \
    && echo 'eval "$(fnm env --use-on-cd --version-file-strategy=recursive --shell bash)"' >> /etc/bash.bashrc
COPY server/bin/ /usr/local/bin/
COPY server/gitconfig /etc/gitconfig
COPY server/profile.sh /etc/profile.d/orca-pods.sh
ENV PATH=/home/dev/.local/bin:/opt/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV FNM_DIR=/home/dev/.local/share/fnm
ENV PNPM_HOME=/home/dev/.local/share/pnpm
CMD ["/usr/local/bin/orca-server-init"]

# Last, so a plain build keeps producing the client.
FROM base AS client
CMD ["tailscaled", "--statedir=/state"]
