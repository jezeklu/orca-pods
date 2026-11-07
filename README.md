# orca-pods

Isolated Orca ADE client in a hardened rootless container, connected over Tailscale.

A separate Orca instance in a rootless container that talks to an Orca server only over Tailscale. It shares no state with the host or with a native Orca installation.

> orca-pods is an independent project. It is not affiliated with or endorsed by the Orca authors and does not redistribute Orca: the client runs your own AppImage.

## Requirements

Supported hosts are Arch, Fedora, Debian 13 and Ubuntu 26.04 with rootless Podman 5.0 or newer, Wayland and Orca as an AppImage. Ubuntu 24.04 ships Podman 4.9 and is not supported.

`orca-client packages` prints the install command for your distribution, `doctor` checks that everything is in place. Nothing is installed outside the package manager and nothing needs root at runtime.

## Client

### First run

`./build.sh` builds the standalone file `dist/orca-client`. Copy it into `~/.local/bin`. Client settings live in `~/.config/orca-pods/client.env`, see `client.env.example`.

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
./test.sh clean        # remove test images and VMs, leave other images alone
```

Downloaded images stay for the next run. VMs are deleted after the test, their base images stay in `.local/`.

`./test.sh vm` needs only QEMU from the distribution packages and `/dev/kvm`, for example `sudo pacman -S qemu-base` on Arch.

## CI/CD

`.github/workflows/image.yml` builds the image, smoke-tests it and publishes it to Docker Hub with the tags `latest` and a date. Set these repository secrets:

| Name | Value |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub user |
| `DOCKERHUB_TOKEN` | Access token with Read & Write |

Forks publish elsewhere by changing `IMAGE` in the workflow and setting `PODS_IMAGE` on the host.

## License

[MIT](LICENSE)
