#!/bin/sh
# Isolated Orca client: starts Orca in a rootless container and undoes everything when it exits.
# Run it with help for the commands.

ROLE=client
# @include common.sh
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

DEFAULT_VAULT_BASE="${XDG_DATA_HOME:-$HOME/.local/share}/orca-pods/client-vault"
VAULT_BASE="${PODS_VAULT_BASE:-}"
[ -z "${PODS_APPIMAGE:-}" ] || echo "WARNING: PODS_APPIMAGE is no longer used, the client installs Orca releases itself: $prog orca-update" >&2
VAULT="$VAULT_BASE/vault"
OPEN="$VAULT_BASE/vault-open"
# Orca versions, written only by dev in a short container, mounted read-only into the client.
ORCA_DIR="$STORE/orca"
SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}"
# Opt-in, a second deliberate hole: the container can record the microphone while Orca runs.
AUDIO="${PODS_AUDIO:-0}"
case "$AUDIO" in 0|1) ;; *) echo "PODS_AUDIO must be 0 or 1." >&2; exit 1 ;; esac
PULSE_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native"

require_free() {
  [ ! -e "$RUNROOT" ] || { echo "The client is running or left state behind. Check, then run: $0 cleanup" >&2; exit 1; }
}

# Idempotent and never stops at the first failure: everything that can be undone must be.
teardown() {
  # Closing a terminal delivers more than one signal, none of them may cut the cleanup short.
  trap '' INT TERM HUP PIPE
  set +e
  bad=0
  remove_containers 0 orca-pods-client orca-pods-update orca-pods-shell orca-pods-fw || { echo "WARNING: could not remove the containers" >&2; bad=1; }
  if pod network exists orca-pods-net 2>/dev/null; then
    pod network rm orca-pods-net >/dev/null 2>&1 || { echo "WARNING: could not remove the orca-pods-net network" >&2; bad=1; }
  fi
  if [ -f "$RUNROOT/wayland.acl" ] && [ -S "$SOCK" ]; then
    setfacl --set-file="$RUNROOT/wayland.acl" "$SOCK" || { echo "WARNING: could not restore the Wayland socket ACL" >&2; bad=1; }
  fi
  if [ -f "$RUNROOT/pulse.acl" ] && [ -S "$PULSE_SOCK" ]; then
    setfacl --set-file="$RUNROOT/pulse.acl" "$PULSE_SOCK" || { echo "WARNING: could not restore the audio socket ACL" >&2; bad=1; }
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
  [ "$AUDIO" = 0 ] || [ -S "$PULSE_SOCK" ] || { echo "Audio socket $PULSE_SOCK is missing, PODS_AUDIO=1 needs pipewire-pulse." >&2; exit 1; }
}

# Does nothing without PODS_AUDIO=1. Needs the runroot for the saved ACL.
share_audio() {
  [ "$AUDIO" = 1 ] || return 0
  uid=$(dev_host_uid) || return 1
  getfacl -cp "$PULSE_SOCK" >"$RUNROOT/pulse.acl"
  setfacl -m "u:$uid:rwx" "$PULSE_SOCK"
}

# Downloads and extracts in the container behind the firewall, the host never runs the AppImage.
# Needs the network from net_up.
release() { # orca-release arguments
  mkdir -p "$ORCA_DIR"
  pod unshare chown "$DEV_IN_NS:$DEV_IN_NS" "$ORCA_DIR"
  pod run --rm --name orca-pods-update --network orca-pods-net --dns 1.1.1.1 --dns 9.9.9.9 \
    --uidmap 0:1:65536 --gidmap 0:1:65536 --user dev --cap-drop=all \
    --security-opt no-new-privileges --security-opt label=disable --read-only --tmpfs /tmp \
    --mount "type=bind,src=$ORCA_DIR,dst=/orca" orca-pods orca-release "$@"
}

fetch_orca() { # [version]
  release switch /orca ${1:+"$1"}
}

# For the short containers while the client is closed, behind the same firewall.
# Callers run require_free before any Podman command, Podman creates the runroot.
closed_client_net() {
  trap 'teardown >/dev/null' EXIT
  trap 'exit 130' INT TERM HUP
  pod image exists orca-pods || { echo "Image orca-pods is missing, start the client once." >&2; exit 1; }
  net_up
  firewall_rules | load_fw
}

orca_update() { # [version]
  case "${1:-}" in
    *[!0-9.]*|.*|*.|*..*) echo "Usage: $prog orca-update [version such as 1.4.255]" >&2; exit 1 ;;
  esac
  require_free
  update_image
  closed_client_net
  echo "Installing Orca ${1:-latest}..."
  version=$(fetch_orca "$@")
  echo "Orca $version installed, the client uses it at the next start."
}

orca_line() { # installed latest
  if [ -z "$1" ]; then
    echo "Orca: not installed${2:+, $2 available}. The next start installs the latest, or: $prog orca-update <version>"
  elif [ -z "$2" ]; then
    echo "Orca: $1, the latest version is unknown."
  elif [ "$1" = "$2" ]; then
    echo "Orca: $1, the latest version."
  else
    echo "Orca: $1, $2 available. Switch with the client closed: $prog orca-update"
  fi
}

# The pairings live in the vault, so the servers are known only while the client runs.
paired_servers() {
  pod exec -u dev orca-pods-client sh -c '
    cli=/opt/orca/resources/bin/orca-ide
    $cli environment list --json 2>/dev/null \
      | jq -r ".result.environments[]? | [.id, (.name | gsub(\"[[:cntrl:]]\"; \"\"))] | @tsv" \
      | while IFS="$(printf "\t")" read -r id name; do
          version=$($cli status --environment "$id" --json 2>/dev/null | jq -r ".result.runtime.appVersion // empty")
          printf "%s\t%s\n" "${version:-unreachable}" "$name"
        done'
}

show_status() {
  installed=$(readlink "$ORCA_DIR/current" 2>/dev/null || true)
  if [ ! -e "$RUNROOT" ]; then
    echo "The client is not running."
    closed_client_net
    orca_line "$installed" "$(release version 2>/dev/null || true)"
    echo "Servers: their pairings are in the vault, start the client or run op-server status on the server."
    return 0
  fi
  [ "$(pod container inspect --format '{{.State.Running}}' orca-pods-client 2>/dev/null)" = true ] || require_free
  echo "The client is running."
  echo "Tailscale: $(tailscale_state || true)"
  orca_line "$installed" "$(pod exec orca-pods-client orca-release version 2>/dev/null || true)"
  servers=$(paired_servers || true)
  [ -n "$servers" ] || { echo "Servers: none paired."; return 0; }
  printf '%s\n' "$servers" | while IFS="$(printf '\t')" read -r version name; do
    case "$version" in
      unreachable) echo "Server $name: unreachable" ;;
      "$installed") echo "Server $name: Orca $version, the same as the client" ;;
      *) echo "Server $name: Orca $version. Match it with the client closed: $prog orca-update $version" ;;
    esac
  done
}

# The password is asked for twice, once to create the vault and once to set it up.
create_vault() {
  mkdir -p "$VAULT" "$OPEN"
  echo "Creating the vault $VAULT. Store the password and the master key it prints safely, without them the data is lost."
  gocryptfs -init -q "$VAULT"
  echo "Unlocking the new vault to set it up."
  pod unshare gocryptfs -q -allow_other "$VAULT" "$OPEN"
  pod unshare sh -c 'cd "$1" && mkdir home state && chown "$2:$2" home && chown 1:1 state && chmod 700 home state' \
    sh "$OPEN" "$DEV_IN_NS"
  pod unshare umount "$OPEN"
}

install_client() {
  doctor gocryptfs
  require_free
  trap 'teardown >/dev/null' EXIT
  trap 'exit 130' INT TERM HUP
  if [ ! -f "$CONFIG" ]; then
    mkdir -p "$(dirname "$CONFIG")"
    printf 'PODS_VAULT_BASE="%s"\n' "$DEFAULT_VAULT_BASE" >"$CONFIG"
    echo "Created $CONFIG."
    VAULT_BASE=$DEFAULT_VAULT_BASE VAULT=$DEFAULT_VAULT_BASE/vault OPEN=$DEFAULT_VAULT_BASE/vault-open
  fi
  [ -n "$VAULT_BASE" ] || { echo "Set PODS_VAULT_BASE in $CONFIG." >&2; exit 1; }
  if [ -f "$VAULT/gocryptfs.conf" ]; then echo "Vault $VAULT exists, kept."; else create_vault; fi
  update_image
  closed_client_net
  echo "Installing the latest Orca..."
  echo "Orca $(fetch_orca) installed. Next: $prog, then $prog login from a second terminal."
}

uninstall_client() {
  require_free
  case "$(readlink -m "$VAULT_BASE")/" in
    "$(readlink -m "$STORE")"/*) echo "The vault lies inside $STORE, nothing removed. Move it first." >&2; exit 1 ;;
  esac
  # Images and Orca belong to mapped users.
  pod unshare rm -rf "$STORE"
  rm -rf "$RUNROOT"
  echo "Images and Orca removed. Kept: the settings in $CONFIG${VAULT_BASE:+ and the vault in $VAULT}."
}

# Only while the client is closed: a running client would share the unlocked vault with the shell,
# and a separate password prompt keeps every look into the vault deliberate.
vault_shell() { # [-- command]
  [ "${1:-}" != -- ] || shift
  [ -n "$VAULT_BASE" ] || { echo "Set PODS_VAULT_BASE in $CONFIG." >&2; exit 1; }
  [ -f "$VAULT/gocryptfs.conf" ] || { echo "Vault $VAULT does not exist, run: $prog install" >&2; exit 1; }
  [ ! -e "$RUNROOT" ] || { echo "The client is running or left state behind. Close it first, the shell needs the vault to itself." >&2; exit 1; }
  trap 'teardown >/dev/null' EXIT
  trap 'exit 130' INT TERM HUP
  pod image exists orca-pods || { echo "Image orca-pods is missing, run: $prog install" >&2; exit 1; }
  pod unshare gocryptfs -q -allow_other "$VAULT" "$OPEN"
  tty=-i
  [ ! -t 0 ] || [ ! -t 1 ] || tty=-it
  [ "$#" -gt 0 ] || set -- bash -l
  pod run --rm "$tty" --name orca-pods-shell --hostname orca-pods-shell --network none \
    --uidmap 0:1:65536 --gidmap 0:1:65536 --user dev --workdir /home/dev --cap-drop=all \
    --security-opt no-new-privileges --security-opt label=disable --read-only --tmpfs /tmp \
    --mount "type=bind,src=$OPEN/home,dst=/home/dev" orca-pods "$@"
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

  uid=$(dev_host_uid) || exit 1
  mkdir -p "$RUNROOT"
  getfacl -cp "$SOCK" >"$RUNROOT/wayland.acl"
  setfacl -m "u:$uid:rwx" "$SOCK"
  share_audio || exit 1
  set --
  [ "$AUDIO" = 0 ] || set -- -e PULSE_SERVER=unix:/pulse/native --mount "type=bind,src=$PULSE_SOCK,dst=/pulse/native"

  start_client -e XDG_RUNTIME_DIR=/tmp -e WAYLAND_DISPLAY=/wayland/wayland-0 "$@" \
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

usage() {
  cat <<USAGE
$prog: Orca in a rootless Podman container, with its data in an encrypted vault.
Everything it starts is removed when Orca exits.

  (no command)        Start Orca. Asks for the vault password, loads the firewall,
                      and on the first start installs the latest Orca.
  install             Check requirements, create the settings and the vault (asks
                      for a new password), pull the image and install Orca.
  uninstall           Remove the image and the installed Orca. The settings and
                      the vault stay.

While the client runs, from a second terminal
  login               Log the client in to Tailscale as orca-pods-$INSTANCE.
  status              Orca versions of the client and of the paired servers.

While the client is closed
  status              Orca version of the client.
  orca-update [VER]   Switch to the latest or the given Orca, for example the
                      version a server runs. The previous version stays.
  shell [-- CMD]      Open the vault and start a shell in it with no network,
                      or run CMD. The vault locks again on exit.

Maintenance
  cleanup             Remove leftovers after a crash or kill -9.
  doctor              Check the requirements of this machine.
  packages            Print the command that installs the missing packages.
  help                This help.

Settings  $CONFIG
          PODS_VAULT_BASE: the folder with the vault
          PODS_AUDIO=1: share the microphone and speakers, see README
Data      $STORE (image, Orca), the vault in PODS_VAULT_BASE
More      https://github.com/jezeklu/orca-pods#readme
USAGE
}

main() {
  case "${1:-}" in
    help|-h|--help) usage; return ;;
    doctor) doctor gocryptfs; return ;;
    packages) packages_cmd gocryptfs; return ;;
  esac
  require_user
  prepare_store
  case "${1:-}" in
    "") run_client ;;
    install) install_client ;;
    uninstall) uninstall_client ;;
    shell) shift; vault_shell "$@" ;;
    login) tailscale_login ;;
    orca-update) shift; orca_update "$@" ;;
    status) show_status ;;
    cleanup) teardown ;;
    *) echo "Unknown command: $1. Run: $prog help" >&2; exit 1 ;;
  esac
}

# dev.sh loads this file for its functions.
[ "${PODS_SOURCED:-}" = 1 ] || main "$@"
