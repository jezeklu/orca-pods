#!/bin/sh
# Isolated Orca client: starts Orca in a rootless container and undoes everything when it exits.
#
# Usage:
#   op-client           start Orca, the first start installs the latest Orca
#   op-client login     log the running client in to Tailscale, from a second terminal
#   op-client orca-update [version]  switch to the latest or the given Orca while the client is closed
#   op-client cleanup   manual cleanup after a crash or kill -9
#   op-client doctor    check requirements
#   op-client packages  print the command that installs the packages
#
# Settings: ~/.config/orca-pods/client.env, see client.env.example.

ROLE=client
# @include common.sh
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

VAULT_BASE="${PODS_VAULT_BASE:-}"
[ -z "${PODS_APPIMAGE:-}" ] || echo "WARNING: PODS_APPIMAGE is no longer used, the client installs Orca releases itself: $prog orca-update" >&2
VAULT="$VAULT_BASE/vault"
OPEN="$VAULT_BASE/vault-open"
# Orca versions, written only by dev in a short container, mounted read-only into the client.
ORCA_DIR="$STORE/orca"
SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}"

require_free() {
  [ ! -e "$RUNROOT" ] || { echo "The client is running or left state behind. Check, then run: $0 cleanup" >&2; exit 1; }
}

# Idempotent and never stops at the first failure: everything that can be undone must be.
teardown() {
  # Closing a terminal delivers more than one signal, none of them may cut the cleanup short.
  trap '' INT TERM HUP PIPE
  set +e
  bad=0
  remove_containers 0 orca-pods-client orca-pods-update orca-pods-fw || { echo "WARNING: could not remove the containers" >&2; bad=1; }
  if pod network exists orca-pods-net 2>/dev/null; then
    pod network rm orca-pods-net >/dev/null 2>&1 || { echo "WARNING: could not remove the orca-pods-net network" >&2; bad=1; }
  fi
  if [ -f "$RUNROOT/wayland.acl" ] && [ -S "$SOCK" ]; then
    setfacl --set-file="$RUNROOT/wayland.acl" "$SOCK" || { echo "WARNING: could not restore the Wayland socket ACL" >&2; bad=1; }
  fi
  if [ -d "$OPEN" ] && pod unshare mountpoint -q "$OPEN"; then
    pod unshare umount "$OPEN" || { echo "WARNING: could not unmount the vault" >&2; bad=1; }
  fi
  rm -rf "$RUNROOT"
  sleep 1
  if ip -br link | grep -q br-orca-pods; then echo "WARNING: interface br-orca-pods is still present" >&2; bad=1; fi
  if [ "$bad" -eq 0 ]; then echo "Host restored."; else echo "Cleanup incomplete, see the warnings above." >&2; fi
  return "$bad"
}

start_client() {
  pod run -d --rm --name orca-pods-client --hostname orca-pods-client \
    --network orca-pods-net --dns 1.1.1.1 --dns 9.9.9.9 \
    --uidmap 0:1:65536 --gidmap 0:1:65536 \
    --device /dev/net/tun --cap-drop=all --cap-add=NET_ADMIN \
    --security-opt no-new-privileges --security-opt label=disable \
    --read-only --tmpfs /tmp --tmpfs /run "$@" orca-pods >/dev/null
}

check_requirements() {
  [ -n "$VAULT_BASE" ] || { echo "Set PODS_VAULT_BASE in $CONFIG." >&2; exit 1; }
  doctor gocryptfs >/dev/null || { doctor gocryptfs >&2 || true; exit 1; }
  [ -f "$VAULT/gocryptfs.conf" ] || { echo "Vault $VAULT does not exist, see README." >&2; exit 1; }
  [ -d "$OPEN" ] || { echo "Directory $OPEN is missing, see README." >&2; exit 1; }
  [ -S "$SOCK" ] || { echo "Wayland socket $SOCK is missing." >&2; exit 1; }
}

# Downloads and extracts in the container behind the firewall, the host never runs the AppImage.
# Needs the network from net_up.
fetch_orca() { # [version]
  mkdir -p "$ORCA_DIR"
  pod unshare chown "$DEV_IN_NS:$DEV_IN_NS" "$ORCA_DIR"
  pod run --rm --name orca-pods-update --network orca-pods-net --dns 1.1.1.1 --dns 9.9.9.9 \
    --uidmap 0:1:65536 --gidmap 0:1:65536 --user dev --cap-drop=all \
    --security-opt no-new-privileges --security-opt label=disable --read-only --tmpfs /tmp \
    --mount "type=bind,src=$ORCA_DIR,dst=/orca" orca-pods orca-release switch /orca ${1:+"$1"}
}

orca_update() { # [version]
  case "${1:-}" in
    *[!0-9.]*|.*|*.|*..*) echo "Usage: $prog orca-update [version such as 1.4.255]" >&2; exit 1 ;;
  esac
  require_free
  trap 'teardown >/dev/null' EXIT
  trap 'exit 130' INT TERM HUP
  update_image
  pod image exists orca-pods || { echo "Image orca-pods is missing." >&2; exit 1; }
  net_up
  firewall_rules | load_fw
  echo "Installing Orca ${1:-latest}..."
  version=$(fetch_orca "$@")
  echo "Orca $version installed, the client uses it at the next start."
}

tailscale_state() {
  pod exec orca-pods-client tailscale status --json 2>/dev/null \
    | sed -n 's/.*"BackendState": *"\([A-Za-z]*\)".*/\1/p'
}

run_client() {
  check_requirements
  require_free
  trap 'teardown' EXIT
  trap 'exit 130' INT TERM HUP

  update_image
  pod image exists orca-pods || { echo "Image orca-pods is missing." >&2; exit 1; }

  net_up
  firewall_rules | load_fw
  if [ ! -e "$ORCA_DIR/current" ]; then
    echo "Installing the latest Orca, the first start takes a few minutes..."
    fetch_orca >/dev/null
  fi

  pod unshare gocryptfs -q -allow_other "$VAULT" "$OPEN"
  pod unshare test -d "$OPEN/home" || { echo "The vault has no home directory, see README." >&2; exit 1; }
  pod unshare test -d "$OPEN/state" || { echo "The vault has no state directory, see README." >&2; exit 1; }

  mkdir -p "$RUNROOT"
  getfacl -cp "$SOCK" >"$RUNROOT/wayland.acl"
  setfacl -m "u:$(dev_host_uid):rwx" "$SOCK"

  start_client -e XDG_RUNTIME_DIR=/tmp -e WAYLAND_DISPLAY=/wayland/wayland-0 \
    --mount "type=bind,src=$OPEN/home,dst=/home/dev" \
    --mount "type=bind,src=$OPEN/state,dst=/state" \
    --mount "type=bind,src=$(readlink -f "$ORCA_DIR/current"),dst=/opt/orca,readonly" \
    --mount "type=bind,src=$SOCK,dst=/wayland/wayland-0"

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    state=$(tailscale_state || true)
    case "$state" in Running|NeedsLogin|NeedsMachineAuth|Stopped) break ;; esac
    sleep 1
  done
  [ "$state" = Running ] || echo "Tailscale: state '$state'. Log in from a second terminal: $0 login"

  # In the background so that a signal reaches the trap at once instead of after Orca exits.
  pod exec -u dev -w /home/dev orca-pods-client /opt/orca/AppRun --ozone-platform=wayland --no-sandbox &
  wait "$!"
}

tailscale_login() {
  pod exec orca-pods-client tailscale up --hostname=orca-pods-client \
    --advertise-tags=tag:orca-client --accept-dns=false --shields-up
}

main() {
  case "${1:-}" in
    doctor) doctor gocryptfs; return ;;
    packages) packages_cmd gocryptfs; return ;;
  esac
  require_user
  prepare_store
  case "${1:-}" in
    "") run_client ;;
    login) tailscale_login ;;
    orca-update) shift; orca_update "$@" ;;
    cleanup) teardown ;;
    *) echo "Usage: $prog [login|orca-update|cleanup|doctor|packages]" >&2; exit 1 ;;
  esac
}

# dev.sh loads this file for its functions.
[ "${PODS_SOURCED:-}" = 1 ] || main "$@"
