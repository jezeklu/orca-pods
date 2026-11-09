# shellcheck shell=sh
# Shared by op-client and op-server. The caller sets ROLE before this file is loaded.

set -eu

# Debian keeps nft in /usr/sbin, which is not on the PATH of every session.
PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"
export PATH

MIN_PODMAN=5.0.0

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

case "$ROLE" in
  server) tag=server ;;
  *) tag=latest ;;
esac
IMAGE="${PODS_IMAGE:-docker.io/jezeklu/orca-pods:$tag}"
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

# dev (UID 30100 in the container, see --uidmap) as seen by the host.
dev_host_uid() {
  start=$(awk -F: -v u="$(id -un)" '$1 == u { print $2 }' /etc/subuid)
  echo $((start + 30100))
}

firewall_rules() {
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
    tcp dport 443 accept
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
