#!/bin/sh
# Isolated Orca server in a rootless container.
# Run it with help for the commands.

ROLE=server
# @include common.sh
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

PORT="${PODS_PORT:-6769}"
DEFAULT_SECRETS="${XDG_DATA_HOME:-$HOME/.local/share}/orca-pods/secrets"
SECRETS="${PODS_SECRETS_DIR:-}"
RUNTIMES="${PODS_RUNTIMES:-}"
case "$RUNTIMES" in
  *[!a-z0-9@.\ -]*) echo "PODS_RUNTIMES is a space-separated list such as \"node@24 python@3.13\"." >&2; exit 1 ;;
esac
[ -z "${PODS_NODE_VERSIONS:-}" ] || echo "WARNING: PODS_NODE_VERSIONS is replaced by PODS_RUNTIMES, for example PODS_RUNTIMES=\"node@24\"." >&2
TOOLS="${PODS_TOOLS:-}"
case "$TOOLS" in
  *[!a-z0-9\ -]*) echo "PODS_TOOLS is a space-separated list of tool names." >&2; exit 1 ;;
esac
MEMORY="${PODS_MEMORY:-10g}"
CONTAINERS="${PODS_CONTAINERS:-}"
case "$CONTAINERS" in
  ""|0|1) ;;
  *) echo "PODS_CONTAINERS is 0 or 1." >&2; exit 1 ;;
esac
# A nested start replaces the tag with the ID it checked.
SERVER_IMAGE=orca-pods
HOME_DIR="$STORE/home"
STATE_DIR="$STORE/state"
UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/orca-pods-$INSTANCE.service"

# The image PATH starts in the home of dev, which dev controls. Root gets a fixed one.
ROOT_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
root_exec() { # command...
  pod exec --env "PATH=$ROOT_PATH" orca-pods-server "$@"
}

running() {
  [ "$(pod container inspect --format '{{.State.Running}}' orca-pods-server 2>/dev/null)" = true ]
}

require_running() {
  running || { echo "The server is not running. Run: $prog start" >&2; exit 1; }
}

# Refuses anything wider than one dedicated folder, the path goes into the container.
check_secrets() {
  [ -n "$SECRETS" ] || { echo "Set PODS_SECRETS_DIR in $CONFIG." >&2; return 1; }
  case "$SECRETS" in
    /*) ;;
    *) echo "PODS_SECRETS_DIR must be an absolute path." >&2; return 1 ;;
  esac
  case "$SECRETS" in
    *:*|*,*) echo "PODS_SECRETS_DIR must not contain a colon or a comma." >&2; return 1 ;;
  esac
  real=$(readlink -m "$SECRETS")
  case "$real/" in
    */.ssh/*) echo "PODS_SECRETS_DIR must not contain .ssh." >&2; return 1 ;;
  esac
  case "$HOME/" in
    "$real"/*) echo "PODS_SECRETS_DIR must not be the home directory or above it." >&2; return 1 ;;
  esac
  [ -d "$SECRETS" ] || { echo "Directory $SECRETS is missing." >&2; return 1; }
}

# Nested containers: the server maps 0:1:165536, so the user needs that many subordinate UIDs and GIDs,
# and the user namespace that is running must already have them. Nothing here changes the host.
NESTED_IDS=165536
SUBGID_FILE=/etc/subgid
LOGIN_DEFS=/etc/login.defs
NSSWITCH=/etc/nsswitch.conf

subid_count() { # file
  awk -F: -v u="$(id -un)" -v n="$(id -u)" '$1 == u || $1 == n { s += $3 } END { print s + 0 }' "$1" 2>/dev/null || echo 0
}

# Sources of an nsswitch database, without the [action] items.
nss_sources() { # database
  sed -n "s/^$1:[[:space:]]*//p" "$NSSWITCH" 2>/dev/null | sed 's/\[[^]]*\]//g' | tr -s ' \t' '\n' | grep -v '^$'
}

login_def() { # name default
  v=$(awk -v k="$1" '$1 == k { print $2 }' "$LOGIN_DEFS" 2>/dev/null | tail -n 1)
  echo "${v:-$2}"
}

# File part, needs no store: counts the IDs, or prints the one command that adds a free range.
nested_ids_files() {
  me=$(id -un)
  uids=$(subid_count "$SUBUID_FILE"); gids=$(subid_count "$SUBGID_FILE")
  if [ "$uids" -ge "$NESTED_IDS" ] && [ "$gids" -ge "$NESTED_IDS" ]; then
    echo "OK    $uids subordinate UIDs and $gids GIDs for nested containers"
    return 0
  fi
  echo "FAIL  nested containers need $NESTED_IDS subordinate UIDs and GIDs, $me has $uids and $gids"
  other=$(nss_sources subid | grep -vx files | head -n 1)
  if [ -n "$other" ]; then
    echo "      $NSSWITCH takes subordinate IDs from $other, not from $SUBUID_FILE. Add them there."
    return 1
  fi
  # A range over an account this check cannot see would give a nested process the UID of that account.
  other=$({ nss_sources passwd; nss_sources group; } | grep -vx -e files -e systemd | head -n 1)
  if [ -n "$other" ]; then
    echo "      $NSSWITCH lists accounts from $other, which this check cannot see. Pick a free range by hand, see README."
    return 1
  fi
  short=$((NESTED_IDS - uids))
  [ $((NESTED_IDS - gids)) -le "$short" ] || short=$((NESTED_IDS - gids))
  size=$(( (short + 65535) / 65536 * 65536 ))
  min=$(login_def SUB_UID_MIN 100000); gmin=$(login_def SUB_GID_MIN 100000)
  [ "$gmin" -le "$min" ] || min=$gmin
  max=$(login_def SUB_UID_MAX 600100000); gmax=$(login_def SUB_GID_MAX 600100000)
  [ "$gmax" -ge "$max" ] || max=$gmax
  # systemd-nspawn allocates from 524288 upward, unless the distribution starts there itself (Fedora).
  cap=0; below=""
  [ "$min" -ge 524288 ] || { cap=524288; below=" that ends below 524288"; }
  range=$({
    awk -F: 'NF >= 3 { print $2, $2 + $3 - 1 }' "$SUBUID_FILE" "$SUBGID_FILE" 2>/dev/null
    getent passwd | awk -F: '{ print $3, $3 }'
    getent group | awk -F: '{ print $3, $3 }'
  } | sort -n | awk -v at="$min" -v size="$size" -v max="$max" -v cap="$cap" '
    $2 < at { next }
    $1 > at + size - 1 { exit }
    { at = $2 + 1 }
    END {
      end = at + size - 1
      if (end > max || (cap && end >= cap)) exit 1
      print at "-" end
    }')
  if [ -z "$range" ]; then
    echo "      No free range of $size IDs between $min and $max$below. Pick one by hand, see README."
    return 1
  fi
  flags=""
  [ "$uids" -ge "$NESTED_IDS" ] || flags="--add-subuids $range"
  [ "$gids" -ge "$NESTED_IDS" ] || flags="${flags:+$flags }--add-subgids $range"
  echo "      Add a free range, then stop every rootless container of $me and run: podman system migrate"
  echo "        sudo usermod $flags $me"
  return 1
}

# Live part: the pause process keeps the old map until every rootless container of the user is gone.
# Prints the steps, never migrates: that would cut off containers of other stores.
nested_live_map() {
  if ! command -v podman >/dev/null || ! version_ok "$(podman --version | awk '{ print $NF }')"; then
    echo "SKIP  running user namespace, Podman is missing or too old"
    return 0
  fi
  need=$((NESTED_IDS + 1))
  uids=$(pod unshare cat /proc/self/uid_map | awk '{ s += $3 } END { print s + 0 }')
  gids=$(pod unshare cat /proc/self/gid_map | awk '{ s += $3 } END { print s + 0 }')
  if [ "$uids" -ge "$need" ] && [ "$gids" -ge "$need" ]; then
    echo "OK    running user namespace has $uids UIDs and $gids GIDs"
    return 0
  fi
  echo "FAIL  the running user namespace has $uids UIDs and $gids GIDs, nested containers need $need"
  echo "      Stop every rootless container of $(id -un): all servers, the client and any other. Then run: podman system migrate"
  return 1
}

# The shared doctor stays as it is, the client and other roles call it too.
server_doctor() {
  bad=0
  doctor || bad=1
  [ "$CONTAINERS" = 1 ] || return "$bad"
  if nested_ids_files; then
    require_user
    prepare_store
    nested_live_map || bad=1
  else
    bad=1
  fi
  proc_warning
  return "$bad"
}

# Read access for dev only, the default ACL covers files added later.
# setfacl -R does not follow symlinks, a link in there grants nothing.
grant_secrets() {
  uid=$(dev_host_uid) || return 1
  setfacl -R -m "u:$uid:rX" "$SECRETS" \
    && find "$SECRETS" -type d -exec setfacl -d -m "u:$uid:rX" {} + \
    || { echo "Cannot set ACLs on $SECRETS, it must be on a local file system." >&2; return 1; }
}

# Runs as root of the user namespace in a home that dev controls. Parents come first and no link is
# followed, so a link such as .local -> a folder of the host user can neither receive nor chown anything.
# The container is stopped meanwhile.
prepare_dirs() { # home state
  mkdir -p "$1" "$2"
  pod unshare sh -c '
    cd "$1" || exit 1
    for d in .agents .agents/skills .claude .claude/skills .local .local/share .local/share/orca-server projects; do
      if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then
        echo "$1/$d is not a plain directory, the server will not start." >&2; exit 1
      fi
      [ -d "$d" ] || mkdir "$d" || exit 1
    done
    chown -h '"$DEV_IN_NS:$DEV_IN_NS"' . .agents .agents/skills .claude .claude/skills .local .local/share \
      .local/share/orca-server projects && chown -h 1:1 "$2"
  ' sh "$1" "$2"
}

# Containers inside the server (PODS_CONTAINERS=1, see the README): room for the nested range,
# newuidmap through file capabilities, so no NNP, a procfs the nested runtime can mount, and a
# profile that allows sethostname, setdomainname and chroot. The limits bound nested containers too.
run_container() { # options for mounts
  ids=65536 caps=NET_ADMIN pids=4096 env=""
  security="--security-opt no-new-privileges --security-opt label=disable"
  if [ "$CONTAINERS" = 1 ]; then
    ids=165536 caps=NET_ADMIN,SETUID,SETGID pids=16384
    security="--security-opt label=disable --security-opt unmask=/proc/* --security-opt seccomp=$STORE/seccomp-nested.json"
    env="--env PODS_NESTED=1 --env XDG_RUNTIME_DIR=/run/user/30100 --env DOCKER_HOST=unix:///run/user/30100/podman/podman.sock"
  fi
  # unmask=/proc/* is for Podman, not for the shell.
  set -f
  # shellcheck disable=SC2086 # option lists without whitespace in their values
  pod run -d --rm --name orca-pods-server --hostname "orca-pods-$INSTANCE" \
    --network orca-pods-net --dns 1.1.1.1 --dns 9.9.9.9 \
    --uidmap "0:1:$ids" --gidmap "0:1:$ids" \
    --device /dev/net/tun --cap-drop=all --cap-add="$caps" \
    $security \
    --read-only --tmpfs /tmp:rw,exec,size=2g,mode=1777 --tmpfs /run $env \
    --memory "$MEMORY" --pids-limit "$pids" \
    -p "127.0.0.1:$PORT:6768" "$@" "$SERVER_IMAGE" >/dev/null
  rc=$?
  set +f
  return "$rc"
}

# The profile of nested mode, the pinned upstream default plus three syscalls (see tests/unit.sh).
# build.sh puts it into the release, so the host loads only a profile the signature covers.
seccomp_profile() {
  # @embed server/seccomp-nested.json
  cat "$(dirname "$(readlink -f "$0")")/server/seccomp-nested.json"
}

# Without NNP every setuid file and file capability of the image works for dev. The image reports
# on itself, which guards against a mistake such as an own PODS_IMAGE with sudo, not against a
# hostile image. Reading needs DAC_READ_SEARCH, directories such as /home/dev are 0700.
NESTED_CAPS='/usr/bin/newgidmap cap_setgid=ep
/usr/bin/newuidmap cap_setuid=ep'
check_image() { # image ID
  [ "$(cat "$STORE/image-checked" 2>/dev/null)" != "$1" ] || return 0
  if out=$(pod run --rm --network none --cap-drop=all --cap-add=DAC_READ_SEARCH --security-opt no-new-privileges \
      --security-opt label=disable --read-only --uidmap 0:1:165536 --gidmap 0:1:165536 --user 0:0 \
      --entrypoint find "$1" / -xdev -type f \( -perm /6000 -printf 'setid %p\n' -o -exec getcap {} + \) 2>&1) \
    && [ "$(printf '%s\n' "$out" | LC_ALL=C sort)" = "$NESTED_CAPS" ]; then
    printf '%s\n' "$1" >"$STORE/image-checked"
    return 0
  fi
  printf '%s\n' "$out" >&2
  echo "PODS_CONTAINERS=1 needs an image without setuid files and with file capabilities only on newuidmap and newgidmap, the server will not start." >&2
  return 1
}

# Container root is ID 1 of the user namespace. Its setuid files in the home, or setgid files of
# its group, would work for dev without NNP. The container is stopped meanwhile.
check_home() {
  if ! out=$(pod unshare find "$HOME_DIR" -xdev -type f \( -uid 1 -perm -4000 -o -gid 1 -perm -2000 \) -print 2>&1) \
    || [ -n "$out" ]; then
    printf '%s\n' "$out" >&2
    echo "The home has setuid or setgid files of container root, the server will not start. Remove them with: $prog shell" >&2
    return 1
  fi
}

# GNU find asks access(2). The test of busybox calls every file writable for root.
PROC_WRITABLE='find /proc -path "/proc/[0-9]*" -prune -o -path /proc/self -prune -o -path /proc/thread-self -prune -o -type f -writable -print 2>/dev/null'
# Limits of namespaces the writer owns. sys/user holds the namespace counts of an own user namespace,
# which the kernel also checks against every parent, so they cannot be raised past the outer limits.
PROC_ALLOWED='^/proc/sys/user/max_[a-z_]*_namespaces$|^/proc/sys/user/max_(fanotify|inotify)_[a-z]*$|^/proc/sys/net/|^/proc/sys/fs/mqueue/|^/proc/sys/kernel/(msg|sem|shm)|^/proc/sys/kernel/(ns_last_pid|pid_max|auto_msgmni)$|^/proc/pressure/'
# Some Ubuntu kernels let container root set kernel.cad_pid for the whole host, which only moves
# the Ctrl-Alt-Del signal to a process of the container. Every other file stops the server.
PROC_KNOWN='^/proc/sys/kernel/cad_pid$'
# The kernel can change with every boot, so this runs at every nested start. find fails on the
# directories it may not enter, and some allowed files are writable always, so an empty list fails.
check_proc() { # file for the warning
  w=$(root_exec sh -c "$PROC_WRITABLE") || true
  extra=$(printf '%s\n' "$w" | grep -vE "$PROC_ALLOWED" | grep . || true)
  unknown=$(printf '%s\n' "$extra" | grep -vE "$PROC_KNOWN" | grep . || true)
  if [ -z "$w" ] || [ -n "$unknown" ]; then
    [ -z "$unknown" ] || printf '%s\n' "$unknown" >&2
    echo "Container root can write the files above in /proc, or the check failed. With PODS_CONTAINERS=1 the server will not start on this kernel." >&2
    return 1
  fi
  if [ -n "$extra" ]; then
    echo "WARNING: this kernel lets container root set kernel.cad_pid for the whole host, so a process in the container can catch Ctrl-Alt-Del of the host. See the README." | tee "$1" >&2
  else
    rm -f "$1"
  fi
}

# Shown again by status and doctor, a start under systemd prints only to the journal.
proc_warning() {
  [ "$CONTAINERS" != 1 ] || [ ! -s "$STORE/proc-warning" ] || cat "$STORE/proc-warning" >&2
}

host_mounts() {
  [ ! -f "$HOME/.gitconfig" ] || printf '%s\n' "-v" "$HOME/.gitconfig:/etc/orca-pods/host.gitconfig:ro,noexec,nosuid,nodev"
}

teardown() {
  trap '' INT TERM HUP PIPE
  set +e
  bad=0
  remove_containers 5 orca-pods-server || { echo "WARNING: could not remove the server" >&2; bad=1; }
  remove_containers 0 orca-pods-fw || { echo "WARNING: could not remove the firewall" >&2; bad=1; }
  if pod network exists orca-pods-net 2>/dev/null; then
    pod network rm orca-pods-net >/dev/null 2>&1 || { echo "WARNING: could not remove the orca-pods-net network" >&2; bad=1; }
  fi
  rm -rf "$RUNROOT"
  if [ "$bad" -eq 0 ]; then echo "Server stopped, data kept."; else echo "Cleanup incomplete, see the warnings above." >&2; fi
  return "$bad"
}

start_network() {
  net_up
  firewall_rules | load_fw
}

require_nested_ids() {
  if ! out=$(nested_ids_files && nested_live_map); then
    printf '%s\n' "$out" >&2
    echo "PODS_CONTAINERS=1 needs the steps above, the server will not start." >&2
    exit 1
  fi
}

# The check and the run use one ID, so a new tag in between changes nothing.
nested_image() {
  SERVER_IMAGE=$(pod image inspect --format '{{.Id}}' orca-pods)
  check_image "$SERVER_IMAGE" || return 1
  seccomp_profile >"$STORE/seccomp-nested.json"
}

start_server() {
  if running; then echo "The server is already running."; return 0; fi
  check_secrets
  [ "$CONTAINERS" != 1 ] || require_nested_ids
  # After a power cut the store still lists containers that no longer exist.
  teardown >/dev/null 2>&1
  set -e
  trap 'teardown; exit 1' HUP INT TERM
  update_image
  pod image exists orca-pods || { echo "Image orca-pods is missing." >&2; teardown; exit 1; }
  state_opts=""
  if [ "$CONTAINERS" = 1 ]; then
    nested_image || { teardown; exit 1; }
    state_opts=,nosuid,nodev
  fi
  grant_secrets
  prepare_dirs "$HOME_DIR" "$STATE_DIR"
  [ "$CONTAINERS" != 1 ] || check_home || { teardown; exit 1; }
  # A failed firewall ends here, before the workload exists.
  if ! start_network; then
    echo "The firewall did not load, the server will not start." >&2
    teardown
    exit 1
  fi
  # Orca tells a stale lock from one held by another machine by the machine id. The image brings its own,
  # so without a fixed one the first start of a new image finds a lock it does not dare to clear.
  [ -s "$STORE/machine-id" ] || { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; echo; } >"$STORE/machine-id"
  # shellcheck disable=SC2046 # one option per line, paths without whitespace are checked below
  run_container --mount "type=bind,src=$HOME_DIR,dst=/home/dev" \
    --mount "type=bind,src=$STATE_DIR,dst=/state$state_opts" \
    -v "$STORE/machine-id:/etc/machine-id:ro" -v "$STORE/machine-id:/var/lib/dbus/machine-id:ro" \
    -v "$SECRETS:/secrets:ro,noexec,nosuid,nodev" $(host_mounts)
  trap - HUP INT TERM
  [ "$CONTAINERS" != 1 ] || check_proc "$STORE/proc-warning" || { teardown; exit 1; }
  pod exec -d --user dev orca-pods-server orca-serve >/dev/null
  [ "$CONTAINERS" != 1 ] || pod exec -d --user dev orca-pods-server orca-containers >/dev/null
  # Offline start must not fail on this, runtimes for projects are not needed to reach the server.
  [ -z "$RUNTIMES" ] || echo "Installing $RUNTIMES if missing..."
  # shellcheck disable=SC2086 # list of runtimes
  pod exec --user dev orca-pods-server orca-runtimes $RUNTIMES || echo "WARNING: could not install PODS_RUNTIMES ($RUNTIMES)." >&2
  # Also on servers set up before the skills came from the server itself.
  pod exec --user dev orca-pods-server orca-skills || true
  [ -z "$TOOLS" ] || echo "Installing $TOOLS if missing..."
  # shellcheck disable=SC2086 # list of tools
  [ -z "$TOOLS" ] || pod exec --user dev orca-pods-server orca-tools $TOOLS || echo "WARNING: could not install PODS_TOOLS ($TOOLS)." >&2
  echo "Server running on 127.0.0.1:$PORT."
}

tailscale_state() {
  root_exec tailscale status --json 2>/dev/null \
    | sed -n 's/.*"BackendState": *"\([A-Za-z]*\)".*/\1/p'
}

orca_running() {
  pod exec --user dev orca-pods-server sh -c 'orca-ide status --json 2>/dev/null' \
    | sed -n 's/.*"appVersion": *"\([^"]*\)".*/\1/p'
}

# Empty when GitHub cannot be reached or the image is older than this script.
orca_latest() {
  pod exec --user dev orca-pods-server orca-update --check 2>/dev/null || true
}

# One line on the Orca versions, with the command when a newer one exists.
orca_versions() {
  now=$(orca_running || true)
  latest=$(orca_latest)
  if [ -z "$now" ]; then
    echo "Orca: not ready yet${latest:+, $latest available}."
  elif [ -z "$latest" ]; then
    echo "Orca: $now, the latest version is unknown."
  elif [ "$now" = "$latest" ]; then
    echo "Orca: $now, the latest version."
  else
    echo "Orca: $now, $latest available. Switch with: $prog orca-update"
  fi
}

show_status() {
  if ! running; then echo "The server is not running."; return 1; fi
  echo "Server running on 127.0.0.1:$PORT."
  proc_warning
  echo "Tailscale: $(tailscale_state || true)"
  orca_versions
  echo "Paired devices:"
  if devices=$(pod exec --user dev orca-pods-server orca-devices 2>/dev/null); then
    printf '%s\n' "$devices" | sed 's/^/  /'
  else
    echo "  unknown, the image is older than this script"
  fi
}

unpair() {
  require_running
  [ -n "${1:-}" ] || { echo "Usage: $prog unpair <device id from $prog status>" >&2; exit 1; }
  pod exec --user dev orca-pods-server orca-devices remove "$1"
}

rename_device() {
  require_running
  [ -n "${2:-}" ] || { echo "Usage: $prog rename <device id from $prog status> <name>" >&2; exit 1; }
  pod exec --user dev orca-pods-server orca-devices rename "$1" "$2"
}

server_shell() { # [-- command]
  require_running
  [ "${1:-}" != -- ] || shift
  tty=-i
  [ ! -t 0 ] || [ ! -t 1 ] || tty=-it
  [ "$#" -gt 0 ] || set -- bash -l
  pod exec "$tty" --user dev --workdir /home/dev orca-pods-server "$@"
}

orca_update() {
  require_running
  case "${1:-}" in
    *[!0-9.]*|.*|*.|*..*) echo "Usage: $prog orca-update [version such as 1.4.255]" >&2; exit 1 ;;
  esac
  echo "Installing Orca ${1:-latest}, terminals keep running..."
  pod exec --user dev orca-pods-server orca-update ${1:+"$1"}
}

restart_server() {
  ! running || teardown
  start_server
}

tailscale_login() {
  require_running
  root_exec tailscale up "--hostname=orca-pods-$INSTANCE" \
    --advertise-tags=tag:orca-server --accept-dns=false
}

pairing() {
  require_running
  ip=$(root_exec tailscale ip -4 2>/dev/null || true)
  mobile=""
  [ "${1:-}" != --mobile ] || mobile=--mobile
  set -- "ws://127.0.0.1:$PORT"
  [ -z "$ip" ] || set -- "$@" "ws://$ip:6768"
  pod exec --user dev orca-pods-server orca-pair $mobile "$@"
  echo "Local Orca warns that the 127.0.0.1 link points back to this device. Turn on its SSH tunnel option: the port is forwarded into the container." >&2
}

# Everything that needs no downtime, then the steps left in the order they should run.
update_all() {
  old=""
  ! running || old=$(pod inspect -f '{{.Image}}' orca-pods-server)
  PULL=1 update_image
  if [ -z "$old" ]; then
    echo "The server is not running, the image is used at the next start: $prog start"
    return 0
  fi
  # Helpers of an older image do not know the current options, so they run only from the new one.
  if [ "$old" != "$(pod image inspect -f '{{.Id}}' orca-pods)" ]; then
    echo "New image ready, the restart installs the rest."
    orca_versions
    echo "Next: $prog restart, then $prog orca-update when a newer Orca is available."
    return 0
  fi
  echo "The image is up to date."
  [ -z "$RUNTIMES" ] || echo "Updating $RUNTIMES..."
  # shellcheck disable=SC2086 # list of runtimes
  pod exec --user dev orca-pods-server orca-runtimes --update $RUNTIMES
  [ -z "$TOOLS" ] || echo "Updating $TOOLS..."
  # shellcheck disable=SC2086 # list of tools
  [ -z "$TOOLS" ] || pod exec --user dev orca-pods-server orca-tools --update $TOOLS
  orca_versions
}

# Signature first, the new file is never run before it. The trusted key stays on the host,
# the container cannot reach it, so code from the container does not get here unsigned.
self_update() {
  signers=$(dirname "$CONFIG")/allowed_signers
  [ -f "$signers" ] || { echo "$signers with the signing public key is missing, see README." >&2; exit 1; }
  self=$(readlink -f "$0")
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  if [ -n "${PODS_RELEASE_DIR:-}" ]; then
    cp "$PODS_RELEASE_DIR/op-server" "$PODS_RELEASE_DIR/op-server.sig" "$work/"
  elif command -v gh >/dev/null; then
    gh release download -R jezeklu/orca-pods -p op-server -p op-server.sig -D "$work"
  else
    for file in op-server op-server.sig; do
      curl -fsSL -o "$work/$file" "https://github.com/jezeklu/orca-pods/releases/latest/download/$file"
    done
  fi
  if ! ssh-keygen -Y verify -f "$signers" -I orca-pods -n orca-pods -s "$work/op-server.sig" \
    <"$work/op-server" >/dev/null 2>&1; then
    echo "Invalid signature, nothing changed." >&2
    exit 1
  fi
  chmod +x "$work/op-server"
  mv "$work/op-server" "$self"
  echo "Script updated from a signed release."
}

write_unit() {
  mkdir -p "$(dirname "$UNIT")"
  self=$(readlink -f "$0")
  cat >"$UNIT" <<UNITFILE
[Unit]
Description=orca-pods server (instance $INSTANCE)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=PODS_CONFIG=$CONFIG
Environment=PODS_INSTANCE=$INSTANCE
ExecStart=$self start
ExecStop=$self stop
TimeoutStartSec=900
# Podman moves the containers into their own scopes, only leftovers of the scripts stay here.
KillMode=mixed

[Install]
WantedBy=default.target
UNITFILE
}

install_server() {
  server_doctor || exit 1
  if [ ! -f "$CONFIG" ]; then
    mkdir -p "$(dirname "$CONFIG")"
    printf 'PODS_SECRETS_DIR="%s"\n' "$DEFAULT_SECRETS" >"$CONFIG"
    echo "Created $CONFIG."
    SECRETS=$DEFAULT_SECRETS
  fi
  [ -d "$SECRETS" ] || { mkdir -p "$SECRETS"; chmod 700 "$SECRETS"; }
  write_unit
  systemctl --user daemon-reload
  systemctl --user enable "orca-pods-$INSTANCE.service"
  # Started by systemd, so it knows the server runs and stops it at shutdown.
  systemctl --user start "orca-pods-$INSTANCE.service"
  pod exec --user dev orca-pods-server orca-update --no-restart
  if ! loginctl enable-linger "$(id -un)" 2>/dev/null; then
    echo "Start at boot needs sudo here. Run: sudo loginctl enable-linger $(id -un)"
  fi
  echo "Done. Next: $prog login and $prog pair"
}

uninstall_server() {
  systemctl --user disable --now "orca-pods-$INSTANCE.service" 2>/dev/null || true
  rm -f "$UNIT"
  systemctl --user daemon-reload 2>/dev/null || true
  teardown
  echo "Service removed, data in $STORE kept. Delete it by hand if needed."
}

FAILS=0
report() { # ok? name
  if [ "$1" = 0 ]; then echo "OK    $2"; else echo "FAIL  $2"; FAILS=$((FAILS + 1)); fi
}

check() { # name expected(pass|block) curl-args...
  name=$1; want=$2; shift 2
  if root_exec curl -ksS -o /dev/null -m 6 "$@" 2>/dev/null; then got=pass; else got=block; fi
  # Not "report $?": under set -e a failed test would end the run before its FAIL line.
  if [ "$got" = "$want" ]; then report 0 "$name ($got)"; else report 1 "$name ($got)"; fi
}

inside() { # name shell-code that must succeed
  name=$1; shift
  if pod exec --user dev orca-pods-server sh -c "$1" >/dev/null 2>&1; then report 0 "$name"; else report 1 "$name"; fi
}

# Shell code as dev, as container root, or as root of a privileged nested container (nested mode).
at() { # position shell-code
  case "$1" in
    dev) pod exec --user dev orca-pods-server sh -c "$2" ;;
    root) root_exec sh -c "$2" ;;
    nested) pod exec --user dev orca-pods-server podman exec orca-pods-nested-root sh -c "$2" ;;
  esac
}

check_at() { # position name expected(pass|block) URL
  if at "$1" "curl -ksS -o /dev/null -m 6 '$4'" >/dev/null 2>&1; then got=pass; else got=block; fi
  if [ "$got" = "$3" ]; then report 0 "$2 ($got)"; else report 1 "$2 ($got)"; fi
}

inside_at() { # position name shell-code that must succeed
  if at "$1" "$3" >/dev/null 2>&1; then report 0 "$2"; else report 1 "$2"; fi
}

# Opens for writing only files the kernel must refuse, so it writes nothing.
PROC_CLOSED='for f in /proc/sys/kernel/core_pattern /proc/sys/kernel/modprobe /proc/sysrq-trigger; do
  if (exec 3>>"$f") 2>/dev/null; then exit 1; fi
done
! head -c1 /proc/kcore >/dev/null 2>&1'

# All IDs of every process in the cgroup of the server, nested ones included, are subordinate IDs.
nested_ids_check() {
  pid1=$(pod container inspect --format '{{.State.Pid}}' orca-pods-server)
  cg=$(sed -n 's/^0:://p' "/proc/$pid1/cgroup")
  pids=$(find "/sys/fs/cgroup$cg" -name cgroup.procs -exec cat {} + | sort -u)
  sleeps=0 outside=""
  for p in $pids; do
    [ "$(cat "/proc/$p/comm" 2>/dev/null)" != sleep ] || sleeps=$((sleeps + 1))
    for kind in Uid:"$SUBUID_FILE" Gid:"$SUBGID_FILE"; do
      awk -v k="${kind%%:*}:" '$1 == k { print $2; print $3; print $4; print $5 }' "/proc/$p/status" 2>/dev/null \
        | awk -v n="$(id -un)" -v u="$(id -u)" 'NR == FNR { split($0, f, ":"); if (f[1] == n || f[1] == u) { s[++c] = f[2]; l[c] = f[3] }; next }
            { ok = 0; for (i = 1; i <= c; i++) if ($1 >= s[i] && $1 < s[i] + l[i]) ok = 1; if (!ok) print }' "${kind#*:}" - \
        | sed "s|^|$p ${kind%%:*} |"
    done
  done >"$work/outside"
  outside=$(sort -u "$work/outside" | tr '\n' ' ')
  # Three nested containers run sleep, so the list holds nested processes and the check is not empty.
  if [ -z "$outside" ] && [ "$sleeps" -ge 3 ]; then report 0 "every process has subordinate IDs only ($sleeps sleep processes seen)"
  else report 1 "IDs outside the subordinate ranges: $outside(sleep processes: $sleeps)"; fi
  if awk -v u="$(id -u)" '$2 <= u && u < $2 + $3 { f = 1 } END { exit !f }' "/proc/$pid1/uid_map" \
    || awk -v g="$(id -g)" '$2 <= g && g < $2 + $3 { f = 1 } END { exit !f }' "/proc/$pid1/gid_map"; then
    report 1 "the map of the server holds the host user"
  else
    report 0 "the map of the server does not hold the host user"
  fi
}

# Runs on throwaway directories. The positive check switches the firewall off, so no data may be in reach.
run_tests() {
  url=${1:-}; ctl=""
  nested_note
  if [ -n "$url" ]; then
    host=${url#*://}; host=${host%%/*}
    ip=$(getent ahostsv4 "$host" | awk 'NR==1{print $1}')
    [ -n "$ip" ] || { echo "Cannot resolve the control target." >&2; exit 1; }
    ctl="--resolve $host:443:$ip $url"
  fi
  running && { echo "The server is running and the tests need its place. Stop it: $prog stop" >&2; exit 1; }
  [ "$CONTAINERS" != 1 ] || require_nested_ids
  teardown >/dev/null 2>&1
  set -e
  state_opts=""
  if [ "$CONTAINERS" = 1 ]; then
    nested_image
    state_opts=,nosuid,nodev
  fi
  gw=$(ip route show default | awk 'NR==1{print $3}')
  hostip=$(ip route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')
  work=$STORE/test
  # A killed run leaves files owned by mapped users behind.
  pod unshare rm -rf "$work"
  mkdir -p "$work/secrets/github"
  cp /bin/true "$work/secrets/program"
  echo secret >"$work/secrets/github/test.token"
  SECRETS=$work/secrets
  grant_secrets
  prepare_dirs "$work/home" "$work/state"
  # Programs of dev under the names root runs. Each leaves a file named after the UID that ran it.
  pod unshare sh -ec '
    mkdir -p "$1/.local/bin"
    for name in tailscaled tailscale curl sh ip awk; do
      printf "%s\n" "#!/bin/sh" "PATH=\${PATH#/home/dev/.local/bin:}" "n=\${0##*/}" \
        "echo \"\$n\" >>\"/tmp/planted-\$(id -u)\"" "exec \"\$n\" \"\$@\"" >"$1/.local/bin/$name"
      chmod 755 "$1/.local/bin/$name"
    done
    chown -R '"$DEV_IN_NS:$DEV_IN_NS"' "$1/.local/bin"
  ' sh "$work/home"
  srv=$(mktemp -d); python3 -m http.server --directory "$srv" 18767 >/dev/null 2>&1 & srvpid=$!
  trap 'set +e; kill "$srvpid" 2>/dev/null; rm -rf "$srv"; teardown; pod unshare rm -rf "$work"' EXIT
  sleep 1

  net_up
  if echo 'table inet orca_pods { broken' | load_fw 2>/dev/null; then report 1 "broken firewall accepted"; else report 0 "broken firewall rejected, the server would not start"; fi
  firewall_rules | load_fw
  # shellcheck disable=SC2046 # one option per line, as at start
  run_container --mount "type=bind,src=$work/home,dst=/home/dev" \
    --mount "type=bind,src=$work/state,dst=/state$state_opts" \
    -v "$work/secrets:/secrets:ro,noexec,nosuid,nodev" $(host_mounts)
  pod exec -d --user dev orca-pods-server python3 -m http.server 6768 --directory /tmp >/dev/null
  sleep 3
  if [ "$CONTAINERS" = 1 ]; then
    pod exec -d --user dev orca-pods-server orca-containers >/dev/null
    # A default nested container, one that does not map dev, and root of a privileged one,
    # the strongest position in a nested server.
    at dev 'for _ in $(seq 20); do [ -e /run/orca-pods/nested ] && break; sleep 1; done
      podman run -d --name orca-pods-nested-root --privileged --network host --pid host -v /state:/state \
        docker.io/library/alpine sleep infinity
      podman exec orca-pods-nested-root apk add -q curl findutils
      podman run -d --name orca-pods-nested docker.io/library/alpine sleep infinity
      podman run -d --name orca-pods-nested-map --uidmap 0:1:65536 --gidmap 0:1:65536 docker.io/library/alpine sleep infinity' >/dev/null \
      || { echo "FAIL  cannot start the nested containers"; exit 1; }
  fi

  brgw=$(root_exec sh -c "ip route | awk '/default/{print \$3}'")
  [ -n "$brgw" ] || { echo "FAIL  cannot find the container gateway"; exit 1; }
  check "LAN gateway" block "http://$gw"
  check "host" block "http://$hostip:18767"
  check "bridge" block "http://$brgw"
  check "host map 169.254.1.2" block "http://169.254.1.2:18767"
  check "host 5432" block "http://169.254.1.2:5432"
  check "host 6768" block "http://169.254.1.2:6768"
  targets=$(host_443_targets "$hostip")
  [ -n "$targets" ] || echo "SKIP  no other host address answers on 443"
  n=0; for a in $targets; do n=$((n + 1)); check "host address $n on 443" block "http://$a:443"; done
  [ -z "$ctl" ] || check "control target" block $ctl
  # Plain HTTP is open in nested mode, for apt and image builds.
  if [ "$CONTAINERS" = 1 ]; then check "http example.com" pass http://example.com; else check "http example.com" block http://example.com; fi
  check "https npm" pass https://registry.npmjs.org
  check "https github" pass https://github.com
  check "https pypi" pass https://pypi.org
  inside "ssh to github.com:22 blocked" '! timeout 6 bash -c "exec 3<>/dev/tcp/github.com/22"'

  inside "dev has UID 30100" 'test "$(id -u)" = 30100'
  inside "dev has no capabilities" 'grep -q "^CapEff:.*0000000000000000" /proc/self/status'
  inside "tailscale0 exists" 'ip -br link | grep -q tailscale0'
  inside "no docker.sock, ~/.ssh or GPG" 'test ! -e /var/run/docker.sock && test ! -e "$HOME/.ssh" && test ! -e "$HOME/.gnupg"'
  inside "writing to /secrets fails" '! touch /secrets/x'
  inside "skills belong to the container" 'touch ~/.agents/skills/x ~/.claude/skills/x && rm ~/.agents/skills/x ~/.claude/skills/x'
  inside "/secrets is readable" 'cat /secrets/github/test.token'
  inside "symlink from a project to /secrets works" 'ln -s /secrets/github/test.token ~/projects/link && cat ~/projects/link'
  inside "no host credentials" 'test ! -e ~/.claude/.credentials.json && test ! -e ~/.config/gh'
  inside "executing from /secrets fails while the file is readable" 'test -r /secrets/program && ! /secrets/program'
  inside "read-only root" '! touch /usr/x && ! touch /etc/x'
  inside "host home not visible" "test ! -e '$HOME' || test '$HOME' = /home/dev"
  inside "no other host data mounted" '! grep -E " /(mnt|media|host)" /proc/mounts'
  inside "orca-pods files in the image" 'command -v orca-update orca-restart orca-pair git-credential-pods gh'
  tailscale_state >/dev/null || true
  inside "programs in ~/.local/bin run for dev" 'test -s /tmp/planted-30100'
  ran=$(pod exec --user dev orca-pods-server /bin/cat /tmp/planted-0 2>/dev/null | sort -u | tr '\n' ' ')
  if [ -z "$ran" ]; then report 0 "root runs no program from ~/.local/bin"; else report 1 "root ran from ~/.local/bin: $ran"; fi

  if [ "$CONTAINERS" = 1 ]; then
    echo "--- nested mode: as dev, as container root and as root of a privileged nested container"
    for p in dev root nested; do
      check_at "$p" "$p: LAN gateway" block "http://$gw"
      check_at "$p" "$p: host on 80" block "http://$hostip"
      check_at "$p" "$p: host" block "http://$hostip:18767"
      check_at "$p" "$p: bridge" block "http://$brgw"
      check_at "$p" "$p: host map 169.254.1.2" block "http://169.254.1.2:18767"
      check_at "$p" "$p: http example.com" pass http://example.com
      check_at "$p" "$p: https github" pass https://github.com
      inside_at "$p" "$p: no host socket or runtime directory" "test ! -e /run/podman && test ! -e /var/run/docker.sock && test ! -e /run/user/$(id -u)"
      inside_at "$p" "$p: core_pattern, modprobe, sysrq-trigger and kcore closed" "$PROC_CLOSED"
    done
    for p in root nested; do
      # find fails on the directories it may not enter, the list is what counts.
      w=$(at "$p" "$PROC_WRITABLE") || true
      # The known kernel leaks only for container root, the start warns about them.
      allowed=$PROC_ALLOWED; [ "$p" != root ] || allowed="$PROC_ALLOWED|$PROC_KNOWN"
      extra=$(printf '%s\n' "$w" | grep -vE "$allowed" | grep . | tr '\n' ' ')
      # Some allowed files are writable in every position, so an empty list cannot pass.
      if [ -z "$extra" ] && [ -n "$w" ]; then report 0 "$p: writable in /proc only the allowlist"
      else report 1 "$p: writable in /proc outside the allowlist: $extra"; fi
    done
    if out=$(check_proc "$work/proc-warning" 2>&1); then report 0 "the start check accepts this kernel"
    else report 1 "the start check refuses this kernel: $(printf '%s\n' "$out" | tr '\n' ' ')"; fi
    [ ! -s "$work/proc-warning" ] || cat "$work/proc-warning"
    # The node key of Tailscale, readable for container root only.
    inside_at root "container root: reads the Tailscale state" 'for _ in $(seq 10); do [ -s /state/tailscaled.state ] && break; sleep 1; done; cat /state/tailscaled.state'
    inside_at dev "dev: the Tailscale state is not readable" '! cat /state/tailscaled.state'
    inside_at nested "nested root: the Tailscale state is not readable" '! cat /state/tailscaled.state'
    inside_at dev "dev: bounding set NET_ADMIN, SETUID, SETGID" 'grep -q "^CapBnd:[[:space:]]*00000000000010c0$" /proc/self/status'
    # Each try is a fresh user namespace, a map can be written once. The last one must work.
    inside_at dev "dev: newuidmap maps only the range of dev" 'try() { unshare -U sleep 5 & p=$!; sleep 0.5; newuidmap "$p" "$@"; r=$?; kill "$p"; return "$r"; }
      ! try 0 0 1 && ! try 0 1000 1 && ! try 0 100000 65537 && ! try 0 30100 1 1 0 1 && try 0 30100 1 1 100000 65536'
    inside_at dev "dev: sethostname and chroot fail outside an own user namespace" '! hostname orca-pods-x && ! chroot / true'
    inside_at dev "dev: sethostname and chroot work in an own user namespace" 'unshare -Ur -u hostname orca-pods-x && unshare -Ur chroot / true'
    inside_at dev "dev: Docker API on a unix socket, no TCP listener" 's=/run/user/30100/podman/podman.sock
      for _ in $(seq 20); do [ -S "$s" ] && break; sleep 1; done
      [ "$(stat -c %U "$s")" = dev ] && ! ss -Hltnp | grep -q podman'
    nested_ids_check
  fi

  if curl -sS -m 6 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then report 0 "127.0.0.1:$PORT from the host"; else report 1 "127.0.0.1:$PORT from the host"; fi
  if curl -sS -m 3 -o /dev/null "http://$hostip:$PORT/" 2>/dev/null; then report 1 "LAN IP port $PORT open"; else report 0 "LAN IP port $PORT closed"; fi

  echo "--- positive check: firewall off for a moment, test container without data only"
  pod unshare --rootless-netns nft delete table inet orca_pods
  check "no fw: http example.com" pass http://example.com
  check "no fw: host map" pass "http://169.254.1.2:18767"
  n=0; for a in $targets; do n=$((n + 1)); check "no fw: host address $n on 443" pass "http://$a:443"; done
  [ -z "$ctl" ] || check "no fw: control target" pass $ctl
  [ "$CONTAINERS" != 1 ] || check_at nested "no fw: nested root, host map" pass "http://169.254.1.2:18767"

  [ "$FAILS" -eq 0 ] && echo "RESULT: all OK" || { echo "RESULT: $FAILS failed"; exit 1; }
}

usage() {
  cat <<USAGE
$prog: an isolated Orca server in a rootless Podman container.

Setup
  install             Check requirements, create the settings and the secrets folder,
                      pull the image, install the latest Orca and start the server
                      through its systemd unit, also at boot.
  uninstall           Stop the server and remove its unit. Projects, Orca, pairings
                      and the Tailscale login stay in the store.
  login               Log the server in to Tailscale as orca-pods-$INSTANCE.

Running
  start | stop        Start or stop the server. Start loads the firewall first and
                      refuses to run without it.
  restart             Stop and start. Picks up a new image and changed settings.
  status              Whether it runs, Tailscale, Orca versions, paired devices.
  shell [-- CMD]      A shell as dev in the running server, or run CMD there.

Devices
  pair [--mobile]     Print pairing codes for the local port and Tailscale.
  unpair ID           Revoke a paired device. IDs are in status.
  rename ID NAME      Name a paired device.

Updates
  update              Pull a new image, update PODS_RUNTIMES and PODS_TOOLS,
                      then print the steps left, such as restart and orca-update.
  orca-update [VER]   Switch Orca to the latest or the given version. Terminals
                      keep running, the previous version stays for a rollback.
  self-update         Replace this script with the latest release, only when its
                      signature matches allowed_signers next to the settings.

Maintenance
  test [URL]          Isolation tests while the server is stopped, no data used.
  cleanup             Remove leftovers after a crash.
  doctor              Check the requirements of this machine.
  packages            Print the command that installs the missing packages.
  help                This help.

Settings  $CONFIG
          PODS_SECRETS_DIR, PODS_PORT, PODS_INSTANCE, PODS_RUNTIMES, PODS_TOOLS,
          PODS_CONTAINERS, ...
Data      $STORE
More      https://github.com/jezeklu/orca-pods#readme
USAGE
}

main() {
  case "${1:-}" in
    ""|help|-h|--help) usage; return ;;
    doctor) server_doctor; return ;;
    packages) packages_cmd; return ;;
  esac
  require_user
  prepare_store
  case "${1:-}" in
    install) install_server ;;
    uninstall) uninstall_server ;;
    start) start_server ;;
    stop|cleanup) teardown ;;
    restart) restart_server ;;
    status) show_status ;;
    login) tailscale_login ;;
    shell) shift; server_shell "$@" ;;
    pair) shift; pairing "$@" ;;
    unpair) shift; unpair "$@" ;;
    rename) shift; rename_device "$@" ;;
    update) update_all ;;
    orca-update) shift; orca_update "$@" ;;
    self-update) self_update ;;
    test) shift; run_tests "$@" ;;
    *) echo "Unknown command: $1. Run: $prog help" >&2; exit 1 ;;
  esac
}

[ -n "${PODS_SOURCED:-}" ] || main "$@"
