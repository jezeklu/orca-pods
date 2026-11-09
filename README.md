# orca-pods

[![image](https://github.com/jezeklu/orca-pods/actions/workflows/image.yml/badge.svg)](https://github.com/jezeklu/orca-pods/actions/workflows/image.yml)
[![client image](https://img.shields.io/docker/image-size/jezeklu/orca-pods/latest?label=client%20image)](https://hub.docker.com/r/jezeklu/orca-pods/tags?name=latest)
[![server image](https://img.shields.io/docker/image-size/jezeklu/orca-pods/server?label=server%20image)](https://hub.docker.com/r/jezeklu/orca-pods/tags?name=server)
[![Podman](https://img.shields.io/badge/podman-rootless%2C%205.0%2B-892CA0?logo=podman&logoColor=white)](https://podman.io)
[![Tailscale](https://img.shields.io/badge/network-Tailscale-242424?logo=tailscale&logoColor=white)](https://tailscale.com)
[![Linux](https://img.shields.io/badge/platform-Linux-FCC624?logo=linux&logoColor=black)](#requirements)
[![release](https://img.shields.io/github/v/release/jezeklu/orca-pods?label=release)](https://github.com/jezeklu/orca-pods/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Isolated Orca ADE pods: GUI client and headless server in hardened containers, connected over Tailscale.

Two roles, one standalone script each:

- **`op-client`:** a separate Orca instance in a rootless container that talks to the server only over Tailscale. It shares no state with the host or with a native Orca installation.
- **`op-server`:** a headless Orca in a rootless container with your projects, coding agents and Tailscale. The host passes in only what you choose and never executes anything the container wrote. The image is built for Node.js projects, other languages come through mise, see [Node and other runtimes](#node-and-other-runtimes).

> orca-pods is an independent project. It is not affiliated with or endorsed by the Orca authors and does not redistribute Orca: the client runs your own AppImage, the server downloads official releases and verifies their checksums.

```text
Host
├── Orca desktop ── local client → 127.0.0.1:6769 ──┐
├── $PODS_SECRETS_DIR (read-only) ──────────────────┤
├── ~/.gitconfig (read-only) ───────────────────────┤
└── ~/.local/share/orca-pods/server                 │
      ├── home (projects, agent logins)             │
      └── state (tailscaled)                        │
                                                    ▼
Rootless network namespace + firewall ── orca-pods-server container
                                           ├── orca-ide serve :6768
                                           ├── tailscaled ── tailnet ── remote client, phone
                                           └── outbound TCP 443 and UDP only, no LAN, no host
```

## Contents

- [Quick start](#quick-start)
- [Requirements](#requirements)
- [What the containers get from the host](#what-the-containers-get-from-the-host)
- [Client](#client): [first run](#first-run), [daily use](#daily-use), [security boundary](#client-security-boundary)
- [Tailscale policy](#tailscale-policy)
- [Server](#server): [configuration](#configuration), [install](#what-install-touches), [projects](#projects), [coding agents](#coding-agents), [skills](#skills), [Git and GitHub](#git-and-github), [updates](#updates), [security boundary](#server-security-boundary)
- [Development](#development), [Tests](#tests), [CI/CD](#cicd)
- [Contributing and security](#contributing-and-security), [License](#license)

## Quick start

Apply the [Tailscale policy](#tailscale-policy) first, then pick a role. `packages` prints the install command for your distribution, `doctor` checks the host.

Server, on the machine that keeps your projects. Settings must be in place **before** `op-server install`: the defaults work without a settings file, anything else such as your own secrets folder or optional tools goes into `~/.config/orca-pods/server.env` first, see [Configuration](#configuration).

```bash
curl -fsSL -o ~/.local/bin/op-server https://github.com/jezeklu/orca-pods/releases/latest/download/op-server
chmod +x ~/.local/bin/op-server
op-server packages      # install what it prints, then
op-server doctor
# optional, before install: settings, see Configuration
#   mkdir -p ~/.config/orca-pods
#   curl -fsSL -o ~/.config/orca-pods/server.env https://raw.githubusercontent.com/jezeklu/orca-pods/main/server.env.example
#   then edit PODS_SECRETS_DIR, PODS_TOOLS, …
op-server install       # image, Orca, start at boot
op-server login         # Tailscale
op-server pair          # pairing codes for the client
```

Client, on a desktop with Wayland and the Orca AppImage:

```bash
curl -fsSL -o ~/.local/bin/op-client https://github.com/jezeklu/orca-pods/releases/latest/download/op-client
chmod +x ~/.local/bin/op-client
op-client packages     # install what it prints, then
op-client doctor
```

Then set `PODS_APPIMAGE` and `PODS_VAULT_BASE` in `~/.config/orca-pods/client.env`, create the vault as described in [First run](#first-run) and start `op-client`.

## Requirements

Supported hosts are Arch, Fedora, Debian 13 and Ubuntu 26.04 with rootless Podman 5.0 or newer. The client also needs Wayland and Orca as an AppImage. Ubuntu 24.04 ships Podman 4.9 and is not supported.

`op-client packages` and `op-server packages` print the install command for your distribution, `doctor` checks that everything is in place. Nothing is installed outside the package manager and nothing needs root at runtime.

## What the containers get from the host

This is the whole interface between the host and each container. Nothing else from the host is visible inside: not your home directory, `~/.ssh`, the GPG agent, the Docker or Podman socket, or any credentials. The isolation tests check this.

**Server**

| In the container | From the host | Mode |
|---|---|---|
| `/home/dev` | `~/.local/share/orca-pods/<instance>/home`: projects, agent logins, Orca, skills, runtimes | Read-write, belongs to the container only |
| `/state` | `~/.local/share/orca-pods/<instance>/state`: Tailscale state | Read-write, belongs to the container only |
| `/secrets` | `$PODS_SECRETS_DIR`: GitHub tokens | Read-only, `noexec,nosuid,nodev` |
| `/etc/orca-pods/host.gitconfig` | `~/.gitconfig`, when it exists | Read-only, `noexec,nosuid,nodev` |
| `/etc/machine-id`, `/var/lib/dbus/machine-id` | `~/.local/share/orca-pods/<instance>/machine-id`, a random id the script creates | Read-only |
| `/dev/net/tun` | The TUN device, for Tailscale | Device |
| Port 6768 | Published only on `127.0.0.1:6769` of the host | Network |

**Client**

| In the container | From the host | Mode |
|---|---|---|
| `/home/dev` | `$PODS_VAULT_BASE/vault-open/home`: the unlocked gocryptfs vault | Read-write |
| `/state` | `$PODS_VAULT_BASE/vault-open/state`: Tailscale state in the vault | Read-write |
| `/opt/orca` | The AppImage from `PODS_APPIMAGE`, extracted into `~/.local/share/orca-pods/client/app` | Read-only |
| `/wayland/wayland-0` | The Wayland socket of your session, with an ACL for the container user only | Read-write, a deliberate hole: the clipboard is shared |
| `/dev/net/tun` | The TUN device, for Tailscale | Device |
| Environment | Only `XDG_RUNTIME_DIR=/tmp` and `WAYLAND_DISPLAY` | |

**Both**

- The root file system is read-only, `/tmp` and `/run` are tmpfs.
- No capabilities except `NET_ADMIN` for Tailscale, and `no-new-privileges`.
- User IDs are mapped into your subordinate range, so `dev` in the container is not your host user.
- The firewall in the rootless network namespace allows only outbound TCP 443 and UDP, never the LAN, the VPN or the host. Neither container starts without it.

From your own home directory only three things reach a container: `~/.gitconfig` and the secrets folder on the server, the Wayland socket on the client. Everything else in the tables is data that belongs to the container.

## Client

### First run

Download `op-client` from the [latest release](https://github.com/jezeklu/orca-pods/releases/latest) into `~/.local/bin`, or build it from a checkout: `./build.sh` writes the standalone files `dist/op-client` and `dist/op-server`. Client settings live in `~/.config/orca-pods/client.env`, see `client.env.example`.

Create the vault once. Store the password and the master key safely, without them the data is lost. `PODS_VAULT_BASE` is the directory from `client.env`.

```bash
cd "$PODS_VAULT_BASE"
mkdir vault vault-open
gocryptfs -init vault
podman unshare gocryptfs -allow_other "$PWD/vault" "$PWD/vault-open"
podman unshare sh -c 'cd vault-open && mkdir home state \
  && chown 30101:30101 home && chown 1:1 state && chmod 700 home state'
podman unshare umount "$PWD/vault-open"
```

### Daily use

```bash
op-client            # pulls a new image, unlocks the vault, starts Orca, restores everything on exit
op-client login      # from a second terminal, first run only: Tailscale login
op-client cleanup    # only after a crash or kill -9
```

Keep the terminal open. Every start pulls the newest image and removes the old one, offline starts use the last image. Images and state live in `~/.local/share/orca-pods/client`, no container survives the exit. A new Orca version is picked up from `PODS_APPIMAGE` at the next start.

The vault is mounted only inside Podman's user namespace, so ordinary host processes see `vault-open/` empty. While the client runs, the content is visible with:

```bash
podman unshare ls -la "$PODS_VAULT_BASE/vault-open"
```

Back up `vault/` through `podman unshare`, its files belong to mapped UIDs:

```bash
podman unshare tar -C "$PODS_VAULT_BASE" -czf /path/to/backup.tgz vault
```

Restore with `podman unshare tar -C "$PODS_VAULT_BASE" -xzpf /path/to/backup.tgz` and recreate `vault-open`. Without `gocryptfs.conf` and the password or master key the data is lost. A lost password is recovered with `gocryptfs -masterkey`.

### Client security boundary

Protected:

- LAN, VPN and host services from anything in the container. The firewall lives in a network namespace the container cannot reach, and the client does not start without it.
- Host files: the container sees only the vault, a read-only Orca and the Wayland socket. No container process runs as the host user.
- The locked vault and its backups from reading without the password.
- Other tailnet devices: the client reaches only port 6768 on the server and refuses incoming connections.

Not protected:

- **Processes running as the host user.** They can use `podman exec`, `podman unshare` or replace the AppImage and reach the running client and its pairing token. The container stops accidental reads, not a targeted attack from your own account. Revoke the token if in doubt.
- Root on the host and kernel vulnerabilities: a container is not a VM.
- Wayland: the clipboard is shared and the socket is a deliberate hole. `label=disable` turns SELinux off for the container.
- The Chromium sandbox is off (`--no-sandbox`), the container is the boundary for the built-in browser.
- Credentials in the profile are stored unencrypted and protected only by the vault, which stays unlocked while the client runs.
- Internet: TCP 443 and UDP are allowed, so data can leave. The firewall cannot tell public addresses routed through a VPN apart.

After `kill -9` of the script the client keeps running and the vault stays unlocked, run `op-client cleanup`.

## Tailscale policy

Paste `acl.hujson` into the Tailscale admin console before the first login. It replaces the default allow-all policy, no other rule with `*` may remain. Its tests reject a policy that breaks the isolation.

## Server

The host needs rootless Podman, `nft`, `acl` and `pasta`, `op-server packages` prints the command.

```bash
curl -fsSL -o ~/.local/bin/op-server https://github.com/jezeklu/orca-pods/releases/latest/download/op-server
chmod +x ~/.local/bin/op-server
op-server install      # image, Orca, start at boot, no root
op-server login        # Tailscale with tag:orca-server
op-server pair         # pairing codes for 127.0.0.1 and for the tailnet
```

A local Orca on the same host pairs with the `127.0.0.1` code. Orca warns that the link points back to this device; turn on its option for an SSH tunnel, because the port is forwarded into the container in the same way. Remote clients and phones use the tailnet code.

`op-server status` lists the paired devices with their id, when they were last seen and how they connected: via the host port (the local Orca) or via Tailscale. Orca names every device `CLI <date>` and keeps no address or host name, so give each a name after pairing:

```sh
op-server rename 1a2b laptop     # id or its first characters, from status
op-server unpair 1a2b            # revoke it, its pairing code stops working
```

Both restart Orca for a moment, open terminals in the container keep running.

`op-server` without arguments lists all commands, `op-server uninstall` removes the service and keeps the data. When the distribution does not allow start at boot without `sudo`, `install` prints the `loginctl enable-linger` command.

### Configuration

Settings live in `~/.config/orca-pods/server.env`. To change any default, create the file **before** `install`:

```bash
mkdir -p ~/.config/orca-pods
curl -fsSL -o ~/.config/orca-pods/server.env https://raw.githubusercontent.com/jezeklu/orca-pods/main/server.env.example
```

Without the file, `install` creates it with `PODS_SECRETS_DIR` only. Later changes apply at the next start: `op-server stop && op-server start`.

| Variable | Default | Meaning |
|---|---|---|
| `PODS_SECRETS_DIR` | `~/.local/share/orca-pods/secrets` | The only host folder you choose for the container, mounted read-only at `/secrets`. It holds the [GitHub tokens](#git-and-github). It must be an absolute path on a local file system with ACL support, not your home directory or above it, not inside `.ssh`, without `:` or `,`. `install` creates it and grants the container user read access. |
| `PODS_TOOLS` | empty | Optional tools installed into the container home at start, space-separated. Off by default. Supported: `agy` (Antigravity CLI) and `openspec` (OpenSpec CLI), see [Coding agents](#coding-agents). |
| `PODS_RUNTIMES` | empty | Runtimes next to the image Node, installed by mise at start, for example `node@24 python@3.13`. See [Node and other runtimes](#node-and-other-runtimes). |
| `PODS_PORT` | `6769` | Port on `127.0.0.1` for a local Orca. |
| `PODS_MEMORY` | `10g` | Memory limit of the container. |
| `PODS_IMAGE` | `docker.io/jezeklu/orca-pods:server` | Image to run, for forks. |
| `PODS_PULL` | `1` | `0` starts with the local image without pulling a new one. |
| `PODS_STORE` | `~/.local/share/orca-pods` | Where instance data lives, one subfolder per instance. |

Besides `PODS_SECRETS_DIR`, the container gets only `~/.gitconfig` from the host, read-only and only when it exists. Skills are not shared with the host, see [Skills](#skills) and [What the containers get from the host](#what-the-containers-get-from-the-host).

**Several instances.** Each instance has its own store, network namespace, firewall and systemd unit. A second one needs its own settings file with `PODS_INSTANCE` and a different `PODS_PORT`, passed through `PODS_CONFIG`:

```bash
printf 'PODS_INSTANCE=work\nPODS_PORT=6770\nPODS_SECRETS_DIR="%s"\n' "$HOME/.local/share/orca-pods/secrets-work" >~/.config/orca-pods/work.env
PODS_CONFIG=~/.config/orca-pods/work.env op-server install
```

### What `install` touches

| Step | Where | Root |
|---|---|---|
| Check Podman, `nft`, `acl`, subuid | Nothing written | No |
| Settings | `~/.config/orca-pods/server.env` | No |
| Instance data and image | `~/.local/share/orca-pods/<instance>/` | No |
| Secrets | `$PODS_SECRETS_DIR` with an ACL for the container user | No |
| Orca | Latest release into `/home/dev/.local/share/orca-server` | No |
| Start at boot | `~/.config/systemd/user/orca-pods-<instance>.service`, linger | No |

Nothing goes into `/usr` or `/etc`.

### Projects

Projects live only in the container, in `/home/dev/projects`. The desktop app clones only to the local machine, but the Orca CLI on the host clones straight onto the server. First find the id of the paired server:

```bash
orca environment list
# f194d602-…  orca-pods-server on myhost  ws://127.0.0.1:6769
```

Then clone with that id as `runtime:<id>`. The clone runs in the container with its git and token, and the project shows up under the server in Orca:

```bash
orca project setup-clone --project github:<owner>/<repo> \
  --host runtime:<environment id> \
  --url https://github.com/<owner>/<repo>.git \
  --destination /home/dev/projects
```

`orca host list` shows every target Orca can clone to, including the server. Use HTTPS URLs, SSH remotes are rewritten to HTTPS in the container anyway. Install dependencies from a terminal of that project in Orca, which runs in the container.

### Coding agents

Each agent logs in separately inside the container:

| Agent | Configuration in the container |
|---|---|
| Claude Code | `/home/dev/.claude`, `/home/dev/.claude.json` |
| Codex | `/home/dev/.codex` |
| OpenCode | `/home/dev/.config/opencode`, `/home/dev/.local/share/opencode` |
| Antigravity CLI (`agy`) | `/home/dev/.gemini` |

Claude Code, Codex and OpenCode come with the image. `agy` is not on npm and updates itself, so it is optional: set `PODS_TOOLS="agy"` and it is installed at the next start into `/home/dev/.local/bin/agy`, inside the container only. The installer comes from Google and checks a SHA-512 from the same server, which guards against broken downloads, not against a compromised source.

`PODS_TOOLS="openspec"` installs the [OpenSpec](https://github.com/Fission-AI/OpenSpec) CLI from npm into `/home/dev/.local`, `op-server update` updates it. Its skills and commands belong to the project: `openspec init` writes them into the repository, so they arrive with the clone.

### Skills

Skills live in the container home, `/home/dev/.agents/skills` and the folders of each agent, and nothing comes from the host. The server installs the Orca skills `orca-cli` and `orchestration` from its own Orca, so they match its version, and updates them after each `orca-update`. A skill you remove stays removed, a copy you changed is never replaced. Add more with `orca skills install --skill <name>` in a container terminal, `orca skills list` shows what this Orca ships.

### Git and GitHub

Git and `gh` in the container pick a token by the repository owner from `$PODS_SECRETS_DIR/github/<owner>.token`, owner in lowercase. `gh` falls back to `default.token` when the owner is unknown, git never does. Commits are unsigned and SSH remotes are rewritten to HTTPS.

Create one fine-grained token per owner at **Settings → Developer settings → Personal access tokens → Fine-grained tokens**:

| Field | Value |
|---|---|
| Resource owner | The user or organization |
| Expiration | 90 days |
| Repository access | Only select repositories |
| Contents, Pull requests, Issues | Read and write |
| Actions, Commit statuses | Read-only |
| Workflows | **No access** |

Without `Workflows` nothing in the container can change `.github/workflows`, so an agent cannot run new code in CI with the repository secrets. `Contents: write` still allows pushing tags: if a tag triggers a release, treat releases as untrusted until you have checked them.

Save the value without the shell history:

```bash
. ~/.config/orca-pods/server.env
install -d -m 700 "$PODS_SECRETS_DIR" "$PODS_SECRETS_DIR/github"
install -m 600 /dev/null "$PODS_SECRETS_DIR/github/<owner>.token"
nano "$PODS_SECRETS_DIR/github/<owner>.token"
```

A renewed token goes into the same file, no restart needed.

### Node and other runtimes

The server image is made for Node.js projects. It ships the current Node release in `/opt/node` with npm and pnpm, the system libraries for Playwright's Chromium, and build tools for native modules (`gcc`, `make`, `python3`). Other languages are not in the image, mise installs them into the home directory.

[mise](https://mise.jdx.dev) picks the versions on every `cd`: `.nvmrc`, `.node-version`, `.tool-versions` or `mise.toml`, also from a parent folder. A folder without them gets the image Node. Shells without the mise hook, such as the commands of coding agents, get the same versions through the mise shims on the `PATH`. The image Node is linked into mise, so a project asking for its major downloads nothing.

Other versions and languages live in `/home/dev/.local/share/mise` and survive a new image. `PODS_RUNTIMES="node@24 python@3.13"` installs them at the next start and `op-server update` moves them to their newest release. A project that asks for something missing gets it on the first command, or run `mise install` in its folder. mise never stops a shell at a question: project configuration under `/home/dev` is trusted, because projects in the container run their own code anyway. Languages that compile from source, such as Ruby, may need build libraries from the `Dockerfile`.

`npm install -g --prefix ~/.local <package>` and `uv tool install <package>` put tools into `/home/dev/.local/bin`. The system is read-only and there is no `sudo`, so a package from the distribution goes into the `Dockerfile` and comes with the next image. Forks set their own image with `PODS_IMAGE`.

### Updates

| What | When | How |
|---|---|---|
| Orca | Whenever you want | `orca-update` in a container terminal, terminals keep running |
| Orca rollback | After a bad version | `orca-update <version>`, the previous version stays on disk |
| Image | At boot, when newer | `op-server start`, or pull ahead with `op-server update` |
| `PODS_RUNTIMES`, `PODS_TOOLS` | Whenever you want | `op-server update` on a running server with the current image. After a new image it asks for a restart first |
| Host script | When you release it | `op-server self-update`, changes nothing without a valid signature |

### Data lifetime

| What | Path in the container | Survives a new image | Removed by |
|---|---|---|---|
| Node from the image | Image | No | Image update |
| Runtimes from mise | `/home/dev/.local/share/mise` | Yes | `mise uninstall` |
| pnpm store | `/home/dev/.local/share/pnpm` | Yes | `pnpm store prune` |
| Projects, `node_modules` | `/home/dev/projects` | Yes | You |
| Agent logins | `/home/dev` | Yes | You |
| Orca | `/home/dev/.local/share/orca-server` | Yes | `orca-update`, keeps one older version |
| `/tmp` | tmpfs | No | Container restart |

`stop`, `cleanup` and `update` never delete the home directory.

### Release signing

On the host, after reviewing the code, run `./sign-release.sh ~/.ssh/<key>` and upload `dist/op-server`, `dist/op-server.sig` and `dist/op-client` to the release. The public key goes into `~/.config/orca-pods/allowed_signers` as `orca-pods ssh-ed25519 …`. The container never sees this file, so code written in the container cannot reach the host unsigned.

### Server security boundary

- The container cannot reach the host or the LAN, only outbound TCP 443 and UDP. It does not start without the firewall.
- The port for a local Orca listens only on `127.0.0.1` and requires a pairing code.
- Projects in the container see each other. An agent can change anything in `/home/dev`, including Orca, but nothing outside the container.
- An agent can read the secrets in `/secrets` and send them out over HTTPS. Put there only what agents need.
- The disk is not encrypted, the server has to boot without a password.
- Data in `~/.local/share/orca-pods` belongs to a mapped UID and ordinary backups cannot read it. Anything outside git and `PODS_SECRETS_DIR` is not backed up.
- Never run on the host what was created in the container, not even after `git pull`, without reviewing it first.

## Development

`dev.sh` reuses `op-client.sh` with an image built locally in `.local/` and paths from `client.env` (see `client.env.example`, ignored by git).

```bash
./dev.sh build
./dev.sh test [URL]   # isolation tests after firewall or network changes; URL is an internal target, never stored
./dev.sh
```

## Tests

Everything runs locally, GitHub Actions runs checks on pull requests and VM tests on demand.

```sh
./test.sh              # unit tests, four distributions in containers, isolation tests on this machine
./test.sh unit         # unit tests only
./test.sh vm [distro]  # isolation tests in a VM: fedora (default), debian, ubuntu, archlinux
./test.sh server       # server role: image, isolation tests, a real Orca in the container
./test.sh vm-server [distro]  # the same in a VM, including the systemd unit
./test.sh clean        # remove test images and VMs, leave other images alone
```

Downloaded images stay for the next run. The server role needs about 11 GB, `vm-server` up to 14 GB per running VM. VMs are deleted after the test, their base images stay in `.local/`.

`./test.sh vm` needs only QEMU from the distribution packages and `/dev/kvm`, for example `sudo pacman -S qemu-base` on Arch.

## CI/CD

`.github/workflows/image.yml` builds both images, smoke-tests them and publishes them to Docker Hub with the tags `latest`, `server` and a date. Set these repository secrets:

| Name | Value |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub user |
| `DOCKERHUB_TOKEN` | Access token with Read & Write |

Forks publish elsewhere by changing `IMAGE` in the workflow and setting `PODS_IMAGE` on the host.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for the commit format and tests, and [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## License

[MIT](LICENSE)
