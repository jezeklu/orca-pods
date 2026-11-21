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

> orca-pods is an independent project. It is not affiliated with or endorsed by the Orca authors and does not redistribute Orca: both roles download official releases and verify their checksums.

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
- [Server](#server): [configuration](#configuration), [install](#what-install-touches), [projects](#projects), [coding agents](#coding-agents), [skills](#skills), [Git and GitHub](#git-and-github), [containers inside](#containers-inside-the-server), [updates](#updates), [security boundary](#server-security-boundary)
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

Client, on a desktop with Wayland:

```bash
curl -fsSL -o ~/.local/bin/op-client https://github.com/jezeklu/orca-pods/releases/latest/download/op-client
chmod +x ~/.local/bin/op-client
op-client packages     # install what it prints, then
op-client install      # settings, the vault and Orca, asks for a new vault password
op-client              # start Orca
```

To keep the vault elsewhere than `~/.local/share/orca-pods/client-vault`, set `PODS_VAULT_BASE` in `~/.config/orca-pods/client.env` before `install`, see [First run](#first-run).

## Requirements

Supported hosts are Arch, Fedora, Debian 13 and Ubuntu 26.04 with rootless Podman 5.0 or newer. The client also needs Wayland. Ubuntu 24.04 ships Podman 4.9 and is not supported.

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
| `/opt/orca` | The current Orca release in `~/.local/share/orca-pods/client/orca`, which only a short update container writes | Read-only |
| `/wayland/wayland-0` | The Wayland socket of your session, with an ACL for the container user only | Read-write, a deliberate hole: the clipboard is shared |
| `/pulse/native` | Only with `PODS_AUDIO=1`: the pipewire-pulse socket of your session, with an ACL for the container user only | Read-write, a deliberate hole: microphone and speakers |
| `/dev/net/tun` | The TUN device, for Tailscale | Device |
| Environment | Only `XDG_RUNTIME_DIR=/tmp` and `WAYLAND_DISPLAY`, with `PODS_AUDIO=1` also `PULSE_SERVER` | |

**Both**

- The root file system is read-only, `/tmp` and `/run` are tmpfs.
- No capabilities except `NET_ADMIN` for Tailscale, and `no-new-privileges`. A server with `PODS_CONTAINERS=1` differs, see [Containers inside the server](#containers-inside-the-server).
- User IDs are mapped into your subordinate range, so `dev` in the container is not your host user.
- The firewall in the rootless network namespace allows only outbound TCP 443 and UDP, never the LAN, the VPN or the host. Neither container starts without it.

From your own home directory only three things reach a container: `~/.gitconfig` and the secrets folder on the server, the Wayland socket and, with `PODS_AUDIO=1`, the audio socket on the client. Everything else in the tables is data that belongs to the container.

## Client

### First run

Download `op-client` from the [latest release](https://github.com/jezeklu/orca-pods/releases/latest) into `~/.local/bin`, or build it from a checkout: `./build.sh` writes the standalone files `dist/op-client` and `dist/op-server`. Client settings live in `~/.config/orca-pods/client.env`, see `client.env.example`.

Audio is off by default, so Orca reports no microphone (`NotFoundError`). To use the microphone and speakers, set `PODS_AUDIO=1` in `client.env` and restart the client. It needs pipewire-pulse, which Fedora, Debian and Ubuntu desktops run by default, on Arch install `pipewire-pulse`. See [Client security boundary](#client-security-boundary) for what it exposes.

`op-client install` checks the requirements and creates `~/.config/orca-pods/client.env` with `PODS_VAULT_BASE="~/.local/share/orca-pods/client-vault"` unless the file exists. A missing vault is created in `$PODS_VAULT_BASE/vault`, with `vault-open` next to it as the mount point. It asks for the new password twice, once to create the vault and once to set it up. Store the password and the master key it prints safely, without them the data is lost. An existing vault is kept. Last, it installs the latest Orca.

`op-client uninstall` removes the images and Orca and keeps the settings and the vault, it prints where they are.

### Daily use

```bash
op-client            # pulls a new image, unlocks the vault, starts Orca, restores everything on exit
op-client login      # from a second terminal, first run only: Tailscale login
op-client status     # Orca versions of the client and of the paired servers
op-client shell      # a shell in the vault while the client is closed
op-client cleanup    # only after a crash or kill -9
```

Keep the terminal open. Every start pulls the newest image and removes the old one, offline starts use the last image. Images, state and Orca live in `~/.local/share/orca-pods/client`, no container survives the exit.

The client has its own Orca, independent of any Orca installed on the host, so it can stay on the version the server runs. The first start installs the latest release. Later versions come only on request, with the client closed:

```bash
op-client orca-update            # the latest release
op-client orca-update 1.4.255    # a given version, also the way back
```

`op-client status` shows which version the client runs and which is the latest. While the client runs, it also asks every paired server for its Orca version over Tailscale and prints the command that matches the client to it. The pairings live in the vault, so a closed client cannot reach the servers: start it, or run `op-server status` on the server.

A short container behind the same firewall downloads the release, checks its SHA-512 and extracts it, the host never runs the AppImage. The current and the previous version stay on disk. Orca's own update prompt cannot apply inside the container, use `orca-update` instead.

The vault is mounted only inside Podman's user namespace, so ordinary host processes see `vault-open/` empty. To look into it, close the client and run `op-client shell`, or `op-client shell -- ls -la` for one command. It asks for the vault password every time and starts a short container with the vault at `/home/dev`, without a network, capabilities or a writable system. The vault is locked again when the shell ends. While the client runs, the shell refuses to start.

Back up `vault/` through `podman unshare`, its files belong to mapped UIDs:

```bash
podman unshare tar -C "$PODS_VAULT_BASE" -czf /path/to/backup.tgz vault
```

Restore with `podman unshare tar -C "$PODS_VAULT_BASE" -xzpf /path/to/backup.tgz` and recreate `vault-open`. Without `gocryptfs.conf` and the password or master key the data is lost. A lost password is recovered with `gocryptfs -masterkey`.

### Client security boundary

Protected:

- LAN, VPN and host services from anything in the container. The firewall lives in a network namespace the container cannot reach, and the client does not start without it.
- Host files: the container sees only the vault, a read-only Orca, the Wayland socket and, with `PODS_AUDIO=1`, the audio socket. No container process runs as the host user.
- The locked vault and its backups from reading without the password.
- Other tailnet devices: the client reaches only port 6768 on the server and refuses incoming connections.

Not protected:

- **Processes running as the host user.** While the client runs, the vault is unlocked. Its files belong to a mapped UID, so an ordinary read from your account fails, but a script that uses `podman exec` or `podman unshare` reaches the vault and the pairing token without a password. The container stops accidental reads, not a targeted attack from your own account; only a separate host account would. A closed client leaves only the encrypted vault. Revoke the token if in doubt.
- Root on the host and kernel vulnerabilities: a container is not a VM.
- Wayland: the clipboard is shared and the socket is a deliberate hole. `label=disable` turns SELinux off for the container.
- Audio with `PODS_AUDIO=1`: anything in the container, agents and the built-in browser included, can record the microphone and play sound while the client runs. The PulseAudio protocol can also load modules into the sound server of your session, which runs as your host user outside the firewall. Turn it on only when you need it.
- The Chromium sandbox is off (`--no-sandbox`), the container is the boundary for the built-in browser.
- Credentials in the profile are stored unencrypted and protected only by the vault, which stays unlocked while the client runs.
- Internet: TCP 443 and UDP are allowed, so data can leave. The firewall cannot tell public addresses routed through a VPN apart.
- Own addresses of the host, a public one included, are blocked as they were at start. An address the host gets later, for example a new one from DHCP, is reachable on 443 and UDP until the next start.

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
op-server shell        # a shell as dev in the running server, or: op-server shell -- <command>
```

A local Orca on the same host pairs with the `127.0.0.1` code. Orca warns that the link points back to this device; turn on its option for an SSH tunnel, because the port is forwarded into the container in the same way. Remote clients and phones use the tailnet code.

`op-server status` lists the paired devices with their id, when they were last seen and how they connected: via the host port (the local Orca) or via Tailscale. Orca names every device `CLI <date>` and keeps no address or host name, so give each a name after pairing:

```sh
op-server rename 1a2b laptop     # id or its first characters, from status
op-server unpair 1a2b            # revoke it, its pairing code stops working
```

Both restart Orca for a moment, open terminals in the container keep running.

`op-server help` or `op-server` without arguments describes all commands, `op-client help` those of the client. `op-server uninstall` removes the service and keeps the data. When the distribution does not allow start at boot without `sudo`, `install` prints the `loginctl enable-linger` command.

### Configuration

Settings live in `~/.config/orca-pods/server.env`. To change any default, create the file **before** `install`:

```bash
mkdir -p ~/.config/orca-pods
curl -fsSL -o ~/.config/orca-pods/server.env https://raw.githubusercontent.com/jezeklu/orca-pods/main/server.env.example
```

Without the file, `install` creates it with `PODS_SECRETS_DIR` only. Later changes apply at the next start: `op-server restart`.

| Variable | Default | Meaning |
|---|---|---|
| `PODS_SECRETS_DIR` | `~/.local/share/orca-pods/secrets` | The only host folder you choose for the container, mounted read-only at `/secrets`. It holds the [GitHub tokens](#git-and-github). It must be an absolute path on a local file system with ACL support, not your home directory or above it, not inside `.ssh`, without `:` or `,`. `install` creates it and grants the container user read access. |
| `PODS_TOOLS` | empty | Optional tools installed into the container home at start, space-separated. Off by default. Supported: `agy` (Antigravity CLI) and `openspec` (OpenSpec CLI), see [Coding agents](#coding-agents). |
| `PODS_RUNTIMES` | empty | Runtimes next to the image Node, installed by mise at start, for example `node@24 python@3.13`. See [Node and other runtimes](#node-and-other-runtimes). |
| `PODS_PORT` | `6769` | Port on `127.0.0.1` for a local Orca. |
| `PODS_MEMORY` | `10g` | Memory limit of the container. |
| `PODS_CONTAINERS` | empty | `1` runs rootless Podman and a Docker API inside the server. Needs more subordinate IDs on the host, see [Containers inside the server](#containers-inside-the-server). |
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

### Containers inside the server

With `PODS_CONTAINERS=1`, `dev` can run rootless Podman inside the server: `podman` and `docker` commands, image builds, and a Docker API for testcontainers and devcontainers on `/run/user/30100/podman/podman.sock` (`DOCKER_HOST` points to it). The API listens on that unix socket only. It is the Podman of `dev` and gives nothing beyond what `dev` can do with `podman` directly. Without the setting, `podman` and `docker` only print a hint.

**Host setup.** Nested containers need 65 536 IDs of their own, so the server needs 165 536 subordinate IDs instead of 65 536:

| IDs in the server | Used by |
|---|---|
| 0 | container root, subordinate ID 1 on the host |
| 30100 | `dev` |
| 100000 to 165535 | the nested containers of `dev` |

`PODS_CONTAINERS=1 op-server doctor` checks this and prints the one command that adds a free range, for example `sudo usermod --add-subuids 165536-296607 --add-subgids 165536-296607 <user>`. Read it and run it yourself, `op-server` never uses `sudo`. Then the running user namespace has to grow:

1. Stop every rootless container of the user: all servers, the client and any other. A container that runs during the next step can no longer be stopped normally.
2. Run `podman system migrate`.
3. Set `PODS_CONTAINERS=1` in the settings and run `op-server restart`. `start` refuses to run while the range or the running map is too small, and `doctor` says why.

If a container was left running, `podman stop` fails with "operation not permitted". The way out without `sudo`: `nsenter -t <PID of its conmon> -U --preserve-credentials kill -9 <PID of the container>`, then `podman rm`.

On hosts where `nsswitch.conf` reads subordinate IDs or accounts from SSSD or LDAP, `doctor` cannot see every used ID and prints no command. Pick a range by hand that no user, group or other subordinate range uses, a multiple of 65 536 in size, below 524 288 unless `SUB_UID_MIN` starts above.

**What changes in the container.** Each point weakens the default isolation a little, the firewall and the user namespace stay as they are:

- No `no-new-privileges`, because `newuidmap` and `newgidmap` need their file capabilities. So the image has no setuid or setgid file, and `start` checks this before every new image. It runs `find` and `getcap` from the image itself, which guards against a mistake such as an own `PODS_IMAGE` with `sudo`, not against a hostile image. `start` also refuses a home that holds a setuid or setgid file of container root, and mounts `/state` with `nosuid,nodev`.
- Container root holds `SETUID` and `SETGID`. Treat it as reachable by an agent. It is still only a subordinate ID on the host, cannot change the firewall, and reads the Tailscale state in `/state`, so it can copy the node key. After a suspected compromise, remove the node in the Tailscale admin console and run `op-server login` again. Tagged nodes do not expire on their own.
- `/proc` is not masked, so nested containers can mount their own. The kernel still refuses writes outside the namespaces of the container, the isolation tests check this file by file. Readable now: `/proc/interrupts` of the host, whose interrupt counts are also in `/proc/stat`, and hardware details in `/proc/acpi`, `/proc/irq` and `/proc/scsi`. `start` repeats the write check at every start, because the kernel can change with any update. If container root can write a file outside the list, the server does not start. The exception is `kernel.cad_pid` on Ubuntu 26.04 kernels 7.0: container root can point Ctrl-Alt-Del of the host to its own process, so the keys on the console no longer reboot the host. Nothing else changes, the server starts with a warning that `status` and `doctor` repeat, because under systemd a start prints only to the journal.
- A seccomp profile of its own: the upstream default of Podman, pinned in `server/seccomp-default.json`, plus `sethostname`, `setdomainname` and `chroot`. The kernel still allows them only inside a nested namespace. The profile is part of the signed `op-server`.
- The firewall also allows plain HTTP on TCP 80, for `apt` in image builds, after every rule that blocks the LAN, the VPN and the host.
- `--pids-limit` is 16384. The memory and process limits of the server hold for all nested containers together. Their own `--memory` and `--pids-limit` are accepted and have no effect.

**Limits.** No container inside a nested container, no KVM, no FUSE. `/tmp` and the root file system stay as they are, nested images live in `/home/dev/.local/share/containers`. The home has no quota, so nested images can fill the disk of the host. On Debian and Ubuntu the AppArmor profile `pasta` of the host logs a refused signal when a nested network goes away, which is harmless.

**Turning it off.** Files of nested containers belong to IDs of the added range. Once the range is gone, only `sudo` can delete them. So in this order:

1. With the setting still on: `op-server shell -- podman system reset`.
2. Remove `PODS_CONTAINERS=1` and run `op-server restart`.
3. Only then remove the range: `sudo usermod --del-subuids 165536-296607 --del-subgids 165536-296607 <user>`, with the range `doctor` printed, and `podman system migrate` with every container stopped.

If the server no longer starts for step 1, delete the store from the host while the server is stopped. The check refuses a link in the path, which the container could have planted:

```sh
podman unshare sh -c 'cd "$1" && for d in .local .local/share; do [ -d "$d" ] && [ ! -L "$d" ] || exit 1; done && rm -rf .local/share/containers' sh ~/.local/share/orca-pods/server/home
```

### Updates

```sh
op-server update        # pulls the image, updates PODS_RUNTIMES and PODS_TOOLS, says what is left
op-server restart       # only after a new image: a short outage, the start installs the rest
op-server orca-update   # only when a newer Orca is available, terminals keep running
```

`update` changes nothing that would interrupt work. It ends with the running and the latest Orca version and the steps left, in this order. `status` shows the Orca versions too. The image and Orca are separate: an image never brings an Orca version, Orca lives in the container home and changes only through `orca-update`.

| What | When | How |
|---|---|---|
| Image | At boot, when newer | `op-server update` pulls it ahead, `op-server restart` switches to it |
| `PODS_RUNTIMES`, `PODS_TOOLS` | Whenever you want | `op-server update` on a running server with the current image, after a new image the restart installs them |
| Orca | Whenever you want | `op-server orca-update`, or `orca-update` in a container terminal |
| Orca rollback | After a bad version | `op-server orca-update <version>`, the previous version stays on disk |
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

On the host, after reviewing the code, run `./sign-release.sh ~/.ssh/<key>` and upload `dist/op-server`, `dist/op-server.sig` and `dist/op-client` to the release. The public key goes into `~/.config/orca-pods/allowed_signers`. For the releases of this repository it is:

```sh
mkdir -p ~/.config/orca-pods
echo 'orca-pods ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDXHD6ZeJbRTkk/Fz7VdrTl0q2ClEHgGQc8dhssmRAKv' >~/.config/orca-pods/allowed_signers
```

Its fingerprint is `SHA256:WKyUvoglDCAUU5y5ihiclriRkC22NoJ7nD4UOBT85oI`. Releases signed with your own key need your own line instead. The container never sees this file, so code written in the container cannot reach the host unsigned.

### Server security boundary

- The container cannot reach the host or the LAN, only outbound TCP 443 and UDP, with `PODS_CONTAINERS=1` also TCP 80. It does not start without the firewall.
- Nested containers are no boundary against an agent: `dev` can start them privileged. The boundary is the server container, see [Containers inside the server](#containers-inside-the-server).
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
PODS_CONTAINERS=1 ./test.sh server  # the same with containers inside, needs the larger range
PODS_CONTAINERS=1 ./test.sh vm-server [distro]  # the same in a VM, which adds the range doctor prints
./test.sh vm-server [distro]  # the same in a VM, including the systemd unit
./test.sh clean        # remove test images and VMs, leave other images alone
```

Downloaded images stay for the next run. The server role needs about 11 GB, `vm-server` up to 14 GB per running VM. VMs are deleted after the test, their base images stay in `.local/`.

`./test.sh vm` needs only QEMU from the distribution packages and `/dev/kvm`, for example `sudo pacman -S qemu-base` on Arch.

The VM has 2 CPUs, 4 GB of memory and a 20 GB disk. `PODS_VM_CPUS`, `PODS_VM_MEMORY` and `PODS_VM_DISK` change that, for example `PODS_VM_MEMORY=8G PODS_VM_DISK=40G ./test.sh vm-server`. The disk is sparse and only grows with use. `PODS_VM_DIR` puts the VMs and their images in another absolute path. With `PODS_VM_KEEP=1` the VM keeps running after the test and the script prints the `ssh` command to log in. The VM is deleted when it shuts down or on Ctrl-C.

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
