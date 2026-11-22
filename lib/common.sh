# shellcheck shell=sh
# Shared by op-client and op-server. The caller sets ROLE before this file is loaded.

set -eu

# Debian keeps nft in /usr/sbin, which is not on the PATH of every session.
PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"
export PATH

MIN_PODMAN=5.0.0
# build.sh writes the release tag here.
VERSION=dev
RELEASES=https://github.com/jezeklu/orca-pods/releases

prog=${0##*/}

CONFIG="${PODS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/orca-pods/$ROLE.env}"
if [ -f "$CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG"
fi

INSTANCE="${PODS_INSTANCE:-$ROLE}"
case "$INSTANCE" in
  ""|*[!a-z0-9-]*|-*|secrets) echo "Invalid instance name '$INSTANCE', use lowercase letters, digits and dashes." >&2; exit 1 ;;
esac

IMAGE="${PODS_IMAGE:-docker.io/jezeklu/orca-pods:$ROLE}"
PULL="${PODS_PULL:-1}"
STORE="${PODS_STORE:-${XDG_DATA_HOME:-$HOME/.local/share}/orca-pods}/$INSTANCE"
# Must stay under /run/user, pasta cannot open a runroot from /home under SELinux.
# Own root and runroot per instance also mean own network namespace and firewall.
RUNROOT="/run/user/$(id -u)/orca-pods-$INSTANCE"

require_user() {
  [ "$(id -u)" -ne 0 ] || { echo "Run without sudo, $prog is rootless." >&2; exit 1; }
}

pod() {
  podman --root "$STORE/podman" --runroot "$RUNROOT" \
    --network-config-dir "$STORE/networks" "$@"
}

prepare_store() {
  mkdir -p "$STORE/podman" "$STORE/networks"
  # Set only here: Podman refuses to start when the file is missing, doctor runs before it exists.
  CONTAINERS_CONF_OVERRIDE="$STORE/containers.conf"
  export CONTAINERS_CONF_OVERRIDE
  # Explicit, because the firewalld driver would change firewalld on the host.
  printf '[network]\nfirewall_driver = "nftables"\n' >"$CONTAINERS_CONF_OVERRIDE"
}

# SELinux: every container runs with label=disable. The private store sits in the home directory,
# where the host policy would refuse to execute it, and relabelling needs root. Isolation comes from
# the user namespace, seccomp, dropped capabilities and the firewall.

# dev in a user namespace of the store: container UID n is n + 1, see --uidmap.
DEV_IN_NS=30101

# dev (UID 30100 in the container, see --uidmap) as seen by the host. The running user namespace
# comes first: the ACLs must match it, and it stays older than /etc/subuid until the pause process ends.
# Otherwise the lines of the user in file order, the way Podman builds the map.
SUBUID_FILE=/etc/subuid
dev_host_uid() {
  pod unshare cat /proc/self/uid_map 2>/dev/null | ns_to_host && return 0
  awk -F: -v u="$(id -un)" -v n="$(id -u)" 'BEGIN { at = 1 } $1 == u || $1 == n { print at, $2, $3; at += $3 }' \
    "$SUBUID_FILE" | ns_to_host && return 0
  echo "Cannot find the host UID of dev: $SUBUID_FILE needs at least $DEV_IN_NS subordinate IDs for $(id -un)." >&2
  return 1
}

ns_to_host() { # uid_map lines on stdin
  awk -v id="$DEV_IN_NS" '$1 <= id && id < $1 + $3 { print $2 + id - $1; found = 1; exit } END { exit !found }'
}

# Global IPv4 addresses of the host, read once at start. IPv6 is dropped as a whole.
host_addresses() {
  ip -4 -o addr show scope global | awk '{ sub("/.*", "", $4); print $4 }' | sort -u
}

# For the isolation tests: host addresses with a service on 443, which the firewall otherwise lets through.
# Not the one pasta copies into the namespace (argument), traffic to it never leaves.
host_443_targets() { # address-of-the-default-route
  for a in $(host_addresses); do
    [ "$a" != "$1" ] || continue
    ! curl -sS -m 3 -o /dev/null "http://$a:443/" 2>/dev/null || echo "$a"
  done
}

# The own addresses of the host get a rule of their own: a public one is in no private range, and
# nft refuses overlapping elements in one set.
firewall_rules() {
  own=$(host_addresses | paste -sd, - | sed 's/,/, /g')
  cat <<'NFT'
destroy table inet orca_pods

table inet orca_pods {
  chain forward {
    type filter hook forward priority filter - 10; policy accept;
    iifname != "br-orca-pods" return
    meta nfproto ipv6 drop
    ip daddr {
      0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16,
      172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15,
      224.0.0.0/4, 240.0.0.0/4
    } drop
NFT
  [ -z "$own" ] || echo "    ip daddr { $own } drop"
  echo "    tcp dport 443 accept"
  # Plain HTTP for apt and image builds in a server with containers inside, after every drop.
  [ "$ROLE" != server ] || [ "${CONTAINERS:-}" != 1 ] || echo "    tcp dport 80 accept"
  cat <<'NFT'
    meta l4proto udp accept
    drop
  }
  chain input {
    type filter hook input priority filter - 10; policy accept;
    iifname "br-orca-pods" drop
  }
}
NFT
}

# Inside a server with PODS_CONTAINERS=1 its firewall blocks the same targets, so a pass proves less.
NESTED_MARKER=/run/orca-pods/nested
nested_note() {
  [ ! -e "$NESTED_MARKER" ] || echo "WARNING: inside a server with containers the outer firewall also blocks the LAN and the host, so these checks prove less. The firewall test that counts is ./test.sh vm."
}

# Holds the rootless network namespace open, so the firewall exists before the workload starts.
net_up() {
  pod network exists orca-pods-net || pod network create --disable-dns --interface-name br-orca-pods orca-pods-net >/dev/null
  pod run -d --rm --name orca-pods-fw --network orca-pods-net --read-only --cap-drop=all \
    --security-opt no-new-privileges --security-opt label=disable orca-pods sleep infinity >/dev/null
}

# Reads rules from stdin (nft accepts only a pipe in this context). Fails unless the table is really loaded.
# Callers must not start the workload after a failure.
load_fw() {
  pod unshare --rootless-netns nft -f - || return 1
  pod unshare --rootless-netns nft list table inet orca_pods >/dev/null
}

# Ubuntu's AppArmor profile lets pasta refuse a signal from the podman profile, so the last container
# cannot be removed. A plain shell is allowed to send it, then removal works.
remove_containers() { # seconds names...
  wait=$1; shift
  out=$(pod rm -f -t "$wait" "$@" 2>&1) && return 0
  case "$out" in
    *"kill network process"*) ;;
    *) echo "$out" >&2; return 1 ;;
  esac
  pidfile=$(find "$RUNROOT" -name rootless-netns-conn.pid 2>/dev/null | head -n 1)
  [ -z "$pidfile" ] || kill "$(cat "$pidfile")" 2>/dev/null || true
  sleep 1
  pod rm -f -t 0 "$@" >/dev/null 2>&1
}

pull_image() {
  err=$(pod pull -q "$IMAGE" 2>&1 >/dev/null) && return 0
  case "$err" in
    *unauthorized*|*"authentication required"*) ;;
    *) return 1 ;;
  esac
  # A stale saved registry login breaks even a public image, so retry without any login.
  anon=$(mktemp)
  echo '{}' >"$anon"
  if err=$(pod pull -q --authfile "$anon" "$IMAGE" 2>&1 >/dev/null); then
    echo "WARNING: the saved login for the registry was rejected, pulled without it. Renew or remove that login." >&2
    rm -f "$anon"
    return 0
  fi
  rm -f "$anon"
  return 1
}

# Offline start keeps working with the last image. The store is private, so pruning cannot touch other images.
update_image() {
  [ "$PULL" = 1 ] || return 0
  echo "Pulling $IMAGE, a new image takes a few minutes..." >&2
  if pull_image; then
    pod tag "$IMAGE" orca-pods
    pod image prune -f >/dev/null
  elif pod image exists orca-pods; then
    echo "WARNING: could not pull a new image, using the last one: ${err##*Error: }" >&2
  else
    echo "Cannot pull $IMAGE and no local image exists: ${err##*Error: }" >&2
    exit 1
  fi
}

# The tag of the latest published release, read from a redirect. Short timeouts, a start may be offline.
latest_release() {
  url=$(curl -fsS --connect-timeout 2 -m 4 -o /dev/null -w '%{redirect_url}' "$RELEASES/latest" 2>/dev/null) || return 1
  case "${url##*/}" in
    v[0-9]*) echo "${url##*/}" ;;
    *) return 1 ;;
  esac
}

release_line() { # latest
  if [ "$VERSION" = dev ]; then
    echo "Script: built from a checkout${1:+, the latest release is $1}."
  elif [ -z "$1" ]; then
    echo "Script: $VERSION, the latest release is unknown."
  elif [ "$1" = "$VERSION" ]; then
    echo "Script: $VERSION, the latest release."
  else
    echo "Script: $VERSION, release $1 is available: $prog self-update"
  fi
}

# True when the registry holds another image than the local one, such as the weekly rebuild with
# security updates. Reads only the manifest list, which names the digest a pull would store.
image_outdated() {
  digest=$(pod image inspect -f '{{.Digest}}' orca-pods 2>/dev/null) || return 1
  list=$(timeout 10 podman manifest inspect "$IMAGE" 2>/dev/null) || return 1
  case "$list" in
    *'"manifests"'*) ;;
    *) return 1 ;;
  esac
  case "$list" in
    *"\"$digest\""*) return 1 ;;
  esac
}

# Signature first, the new file is never run before it. The trusted key stays on the host,
# the container cannot reach it, so code from the container does not get here unsigned.
self_update() {
  name=op-$ROLE
  signers=$(dirname "$CONFIG")/allowed_signers
  [ -f "$signers" ] || { echo "$signers with the signing public key is missing, see README." >&2; exit 1; }
  self=$(readlink -f "$0")
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  if [ -n "${PODS_RELEASE_DIR:-}" ]; then
    cp "$PODS_RELEASE_DIR/$name" "$PODS_RELEASE_DIR/$name.sig" "$work/"
  else
    for file in "$name" "$name.sig"; do
      curl -fsSL -o "$work/$file" "$RELEASES/latest/download/$file"
    done
  fi
  if ! ssh-keygen -Y verify -f "$signers" -I orca-pods -n orca-pods -s "$work/$name.sig" \
    <"$work/$name" >/dev/null 2>&1; then
    echo "Invalid signature, nothing changed." >&2
    exit 1
  fi
  chmod +x "$work/$name"
  mv "$work/$name" "$self"
  echo "Script updated from a signed release: $("$self" version)"
}

os_family() {
  file="${OS_RELEASE:-/etc/os-release}"
  [ -r "$file" ] || { echo unknown; return; }
  # shellcheck disable=SC1090
  ids=$(. "$file"; echo "${ID:-} ${ID_LIKE:-}")
  for id in $ids; do
    case "$id" in
      arch|fedora|debian) echo "$id"; return ;;
      ubuntu) echo debian; return ;;
      rhel|centos) echo fedora; return ;;
    esac
  done
  echo unknown
}

packages_cmd() {
  extra=${1:-}
  case "$(os_family)" in
    arch) echo "sudo pacman -S --needed podman passt nftables acl $extra" ;;
    fedora) echo "sudo dnf install podman passt nftables acl $extra" ;;
    # dbus-user-session: without it Debian has no user session bus and Podman cannot create cgroups.
    debian) echo "sudo apt install podman passt nftables acl uidmap dbus-user-session $extra" ;;
    *) echo "Install: podman, passt, nftables, acl $extra" ;;
  esac
}

version_ok() {
  [ "$(printf '%s\n%s\n' "$MIN_PODMAN" "$1" | sort -V | head -n 1)" = "$MIN_PODMAN" ]
}

# Arguments: extra tools the role needs.
doctor() {
  bad=0
  for tool in podman pasta nft setfacl getfacl "$@"; do
    if ! command -v "$tool" >/dev/null; then
      echo "FAIL  missing $tool"
      bad=1
    fi
  done
  if command -v podman >/dev/null; then
    version=$(podman --version | awk '{print $NF}')
    if version_ok "$version"; then
      echo "OK    Podman $version"
    else
      echo "FAIL  Podman $version, need at least $MIN_PODMAN"
      bad=1
    fi
  fi
  if ! grep -q "^$(id -un):" /etc/subuid 2>/dev/null; then
    echo "FAIL  user $(id -un) has no entry in /etc/subuid"
    bad=1
  fi
  [ "$bad" -eq 0 ] || return 1
  echo "OK    all requirements met"
}
