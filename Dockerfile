# Client: only system libraries and Tailscale, Orca comes from the host AppImage at runtime.
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

FROM base AS client
CMD ["tailscaled", "--statedir=/state"]
