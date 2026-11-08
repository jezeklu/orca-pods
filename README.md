# orca-pods

Isolated Orca ADE pods: GUI client and headless server in hardened containers, connected over Tailscale.

Two roles, one standalone script each:

- **`orca-client`:** a separate Orca instance in a rootless container that talks to the server only over Tailscale. It shares no state with the host or with a native Orca installation.
- **`orca-server`:** a headless Orca in a rootless container with your projects, coding agents and Tailscale. The host passes in only what you choose and never executes anything the container wrote.

> orca-pods is an independent project. It is not affiliated with or endorsed by the Orca authors and does not redistribute Orca: the client runs your own AppImage, the server downloads official releases and verifies their checksums.

```text
Host
├── Orca desktop ── local client → 127.0.0.1:6769 ──┐
├── $PODS_SECRETS_DIR (read-only) ──────────────────┤
├── ~/.agents/skills, ~/.claude/skills (read-only) ─┤
└── ~/.local/share/orca-pods/server                 │
      ├── home (projects, agent logins)             │
      └── state (tailscaled)                        │
                                                    ▼
Rootless network namespace + firewall ── orca-server container
                                           ├── orca-ide serve :6768
                                           ├── tailscaled ── tailnet ── remote client, phone
                                           └── outbound TCP 443 and UDP only, no LAN, no host
```

## Requirements

Supported hosts are Arch, Fedora, Debian 13 and Ubuntu 26.04 with rootless Podman 5.0 or newer. The client also needs Wayland and Orca as an AppImage. Ubuntu 24.04 ships Podman 4.9 and is not supported.

`orca-client packages` and `orca-server packages` print the install command for your distribution, `doctor` checks that everything is in place. Nothing is installed outside the package manager and nothing needs root at runtime.

## Client

### First run

`./build.sh` builds the standalone files `dist/orca-client` and `dist/orca-server`. Copy the one you need into `~/.local/bin`. Client settings live in `~/.config/orca-pods/client.env`, see `client.env.example`.

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
orca-client          # pulls a new image, unlocks the vault, starts Orca, restores everything on exit
orca-client login    # from a second terminal, first run only: Tailscale login
orca-client cleanup  # only after a crash or kill -9
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

After `kill -9` of the script the client keeps running and the vault stays unlocked, run `orca-client cleanup`.

## Tailscale policy

Paste `acl.hujson` into the Tailscale admin console before the first login. It replaces the default allow-all policy, no other rule with `*` may remain. Its tests reject a policy that breaks the isolation.

## Server

The host needs rootless Podman, `nft`, `acl` and `pasta`, `orca-server packages` prints the command.

```bash
curl -fsSL -o ~/.local/bin/orca-server https://github.com/jezeklu/orca-pods/releases/latest/download/orca-server
chmod +x ~/.local/bin/orca-server
orca-server install    # image, Orca, agy, start at boot, no root
orca-server login      # Tailscale with tag:orca-server
orca-server pair       # pairing codes for 127.0.0.1 and for the tailnet
```

Settings live in `~/.config/orca-pods/server.env`, see `server.env.example`. `orca-server` without arguments lists all commands, `orca-server uninstall` removes the service and keeps the data. When the distribution does not allow start at boot without `sudo`, `install` prints the `loginctl enable-linger` command.

`PODS_INSTANCE` selects an instance. Each one has its own store, network namespace, firewall and systemd unit, so several servers can run side by side.

### What `install` touches

| Step | Where | Root |
|---|---|---|
| Check Podman, `nft`, `acl`, subuid | Nothing written | No |
| Settings | `~/.config/orca-pods/server.env` | No |
| Instance data and image | `~/.local/share/orca-pods/<instance>/` | No |
| Secrets | `$PODS_SECRETS_DIR` with an ACL for the container user | No |
| Orca | Latest release into `/home/dev/.local/share/orca-server` | No |
| Start at boot | `~/.config/systemd/user/orca-<instance>.service`, linger | No |

Nothing goes into `/usr` or `/etc`.

### Paths in the container

| Path | Host source | Mode |
|---|---|---|
| `/home/dev` | `~/.local/share/orca-pods/<instance>/home` | Read-write |
| `/home/dev/projects` | Part of `home` | Read-write |
| `/state` | `~/.local/share/orca-pods/<instance>/state` | Read-write |
| `/home/dev/.local/share/orca-server` | Part of `home`, Orca versions and the `current` link | Read-write |
| `/secrets` | `$PODS_SECRETS_DIR` | Read-only, `noexec,nosuid,nodev` |
| `/home/dev/.agents/skills` | `~/.agents/skills` | Read-only |
| `/home/dev/.claude/skills` | `~/.claude/skills` | Read-only |
| `/etc/orca-pods/host.gitconfig` | `~/.gitconfig` | Read-only |

Symlinks in `~/.claude/skills` must be relative (`../../.agents/skills/…`) to resolve in the container.

### Coding agents

Each agent logs in separately inside the container:

| Agent | Configuration in the container |
|---|---|
| Claude Code | `/home/dev/.claude`, `/home/dev/.claude.json` |
| Codex | `/home/dev/.codex` |
| OpenCode | `/home/dev/.config/opencode`, `/home/dev/.local/share/opencode` |
| Antigravity CLI (`agy`) | `/home/dev/.gemini` |

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

### Node

The image ships the current Node release. Extra major versions go into `PODS_NODE_VERSIONS`, they stay in the home directory and `.nvmrc` switches between them.

### Updates

| What | When | How |
|---|---|---|
| Orca | Whenever you want | `orca-update` in a container terminal, terminals keep running |
| Orca rollback | After a bad version | `orca-update <version>`, the previous version stays on disk |
| Image | At boot, when newer | `orca-server start`, or pull ahead with `orca-server update` |
| Host script | When you release it | `orca-server self-update`, changes nothing without a valid signature |

### Data lifetime

| What | Path in the container | Survives a new image | Removed by |
|---|---|---|---|
| Node from the image | Image | No | Image update |
| Extra Node versions | `/home/dev/.local/share/fnm` | Yes | `fnm uninstall` |
| pnpm store | `/home/dev/.local/share/pnpm` | Yes | `pnpm store prune` |
| Projects, `node_modules` | `/home/dev/projects` | Yes | You |
| Agent logins | `/home/dev` | Yes | You |
| Orca | `/home/dev/.local/share/orca-server` | Yes | `orca-update`, keeps one older version |
| `/tmp` | tmpfs | No | Container restart |

`stop`, `cleanup` and `update` never delete the home directory.

### Release signing

On the host, after reviewing the code, run `./sign-release.sh ~/.ssh/<key>` and upload both files from `dist/` to the release. The public key goes into `~/.config/orca-pods/allowed_signers` as `orca-pods ssh-ed25519 …`. The container never sees this file, so code written in the container cannot reach the host unsigned.

### Server security boundary

- The container cannot reach the host or the LAN, only outbound TCP 443 and UDP. It does not start without the firewall.
- The port for a local Orca listens only on `127.0.0.1` and requires a pairing code.
- Projects in the container see each other. An agent can change anything in `/home/dev`, including Orca, but nothing outside the container.
- An agent can read the secrets in `/secrets` and send them out over HTTPS. Put there only what agents need.
- The disk is not encrypted, the server has to boot without a password.
- Data in `~/.local/share/orca-pods` belongs to a mapped UID and ordinary backups cannot read it. Anything outside git and `PODS_SECRETS_DIR` is not backed up.
- Never run on the host what was created in the container, not even after `git pull`, without reviewing it first.

## Development

`dev.sh` reuses `orca-client.sh` with an image built locally in `.local/` and paths from `client.env` (see `client.env.example`, ignored by git).

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
