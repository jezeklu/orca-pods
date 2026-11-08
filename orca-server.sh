#!/bin/sh
# Isolated Orca server in a rootless container.
#
# Usage:
#   orca-server install           set everything up and start the server at boot
#   orca-server uninstall         remove the service, keep the data
#   orca-server start | stop      start or stop the server
#   orca-server status            server status
#   orca-server login             log the server in to Tailscale
#   orca-server pair [--mobile]   print pairing codes
#   orca-server update            pull a new image and Node patch releases
#   orca-server self-update       replace this script, only with a validly signed release
#   orca-server test [URL]        isolation tests, without data and only while the server is stopped
#   orca-server cleanup           manual cleanup after a crash
#   orca-server doctor            check requirements
#   orca-server packages          print the command that installs the packages
#
# Settings: ~/.config/orca-pods/server.env, see server.env.example.

ROLE=server
# @include common.sh
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

PORT="${PODS_PORT:-6769}"
DEFAULT_SECRETS="${XDG_DATA_HOME:-$HOME/.local/share}/orca-pods/secrets"
SECRETS="${PODS_SECRETS_DIR:-}"
NODE_VERSIONS="${PODS_NODE_VERSIONS:-}"
TOOLS="${PODS_TOOLS:-}"
case "$TOOLS" in
  *[!a-z0-9\ -]*) echo "PODS_TOOLS is a space-separated list of tool names." >&2; exit 1 ;;
esac
MEMORY="${PODS_MEMORY:-10g}"
HOME_DIR="$STORE/home"
STATE_DIR="$STORE/state"
UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/orca-$INSTANCE.service"
# In a user namespace of the store: container UID n is n + 1, see --uidmap.
DEV_IN_NS=30101

running() {
  [ "$(pod container inspect --format '{{.State.Running}}' orca-server 2>/dev/null)" = true ]
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

# Read access for dev only, the default ACL covers files added later.
# setfacl -R does not follow symlinks, a link in there grants nothing.
grant_secrets() {
  uid=$(dev_host_uid)
  setfacl -R -m "u:$uid:rX" "$SECRETS" \
    && find "$SECRETS" -type d -exec setfacl -d -m "u:$uid:rX" {} + \
    || { echo "Cannot set ACLs on $SECRETS, it must be on a local file system." >&2; return 1; }
}

prepare_dirs() { # home state
  mkdir -p "$1" "$2"
  pod unshare sh -c '
    cd "$1" && mkdir -p .agents/skills .claude/skills .local/share/orca-server projects
    chown '"$DEV_IN_NS:$DEV_IN_NS"' . .agents .agents/skills .claude .claude/skills .local .local/share \
      .local/share/orca-server projects
    chown 1:1 "$2"
  ' sh "$1" "$2"
}

run_container() { # options for mounts
  pod run -d --rm --name orca-server --hostname "orca-$INSTANCE" \
    --network orca-net --dns 1.1.1.1 --dns 9.9.9.9 \
    --uidmap 0:1:65536 --gidmap 0:1:65536 \
    --device /dev/net/tun --cap-drop=all --cap-add=NET_ADMIN \
    --security-opt no-new-privileges --security-opt label=disable \
    --read-only --tmpfs /tmp:rw,exec,size=2g,mode=1777 --tmpfs /run \
    --memory "$MEMORY" --pids-limit 4096 \
    -p "127.0.0.1:$PORT:6768" "$@" orca-pods >/dev/null
}

host_mounts() {
  for pair in "$HOME/.agents/skills:/home/dev/.agents/skills" "$HOME/.claude/skills:/home/dev/.claude/skills"; do
    [ ! -d "${pair%%:*}" ] || printf '%s\n' "-v" "$pair:ro,nosuid,nodev"
  done
  [ ! -f "$HOME/.gitconfig" ] || printf '%s\n' "-v" "$HOME/.gitconfig:/etc/orca-pods/host.gitconfig:ro,noexec,nosuid,nodev"
}

teardown() {
  trap '' INT TERM HUP PIPE
  set +e
  bad=0
  remove_containers 5 orca-server || { echo "WARNING: could not remove the server" >&2; bad=1; }
  remove_containers 0 orca-fw || { echo "WARNING: could not remove the firewall" >&2; bad=1; }
  if pod network exists orca-net 2>/dev/null; then
    pod network rm orca-net >/dev/null 2>&1 || { echo "WARNING: could not remove the orca-net network" >&2; bad=1; }
  fi
  rm -rf "$RUNROOT"
  if [ "$bad" -eq 0 ]; then echo "Server stopped, data kept."; else echo "Cleanup incomplete, see the warnings above." >&2; fi
  return "$bad"
}

start_network() {
  net_up
  firewall_rules | load_fw
}

start_server() {
  if running; then echo "The server is already running."; return 0; fi
  check_secrets
  # After a power cut the store still lists containers that no longer exist.
  teardown >/dev/null 2>&1
  set -e
  trap 'teardown; exit 1' HUP INT TERM
  update_image
  pod image exists orca-pods || { echo "Image orca-pods is missing." >&2; teardown; exit 1; }
  grant_secrets
  prepare_dirs "$HOME_DIR" "$STATE_DIR"
  # A failed firewall ends here, before the workload exists.
  if ! start_network; then
    echo "The firewall did not load, the server will not start." >&2
    teardown
    exit 1
  fi
  # shellcheck disable=SC2046 # one option per line, paths without whitespace are checked below
  run_container --mount "type=bind,src=$HOME_DIR,dst=/home/dev" \
    --mount "type=bind,src=$STATE_DIR,dst=/state" \
    -v "$SECRETS:/secrets:ro,noexec,nosuid,nodev" $(host_mounts)
  trap - HUP INT TERM
  pod exec -d --user dev orca-server orca-serve >/dev/null
  # Offline start must not fail on this, Node for projects is not needed to reach the server.
  # shellcheck disable=SC2086 # list of majors
  pod exec --user dev orca-server orca-node $NODE_VERSIONS || echo "WARNING: could not install the extra Node versions." >&2
  # shellcheck disable=SC2086 # list of tools
  [ -z "$TOOLS" ] || pod exec --user dev orca-server orca-tools $TOOLS || echo "WARNING: could not install PODS_TOOLS ($TOOLS)." >&2
  echo "Server running on 127.0.0.1:$PORT."
}

tailscale_state() {
  pod exec orca-server tailscale status --json 2>/dev/null \
    | sed -n 's/.*"BackendState": *"\([A-Za-z]*\)".*/\1/p'
}

show_status() {
  if ! running; then echo "The server is not running."; return 1; fi
  echo "Server running on 127.0.0.1:$PORT."
  echo "Tailscale: $(tailscale_state || true)"
  pod exec --user dev orca-server sh -c 'orca-ide status --json 2>/dev/null' \
    | sed -n 's/.*"appVersion": *"\([^"]*\)".*/Orca: \1/p'
}

tailscale_login() {
  require_running
  pod exec orca-server tailscale up "--hostname=orca-$INSTANCE" \
    --advertise-tags=tag:orca-server --accept-dns=false
}

pairing() {
  require_running
  ip=$(pod exec orca-server tailscale ip -4 2>/dev/null || true)
  mobile=""
  [ "${1:-}" != --mobile ] || mobile=--mobile
  set -- "ws://127.0.0.1:$PORT"
  [ -z "$ip" ] || set -- "$@" "ws://$ip:6768"
  pod exec --user dev orca-server orca-pair $mobile "$@"
}

update_all() {
  PULL=1 update_image
  echo "The new image is used at the next start."
  if running; then
    # shellcheck disable=SC2086 # list of majors
    pod exec --user dev orca-server orca-node --update $NODE_VERSIONS
  fi
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
    cp "$PODS_RELEASE_DIR/orca-server" "$PODS_RELEASE_DIR/orca-server.sig" "$work/"
  elif command -v gh >/dev/null; then
    gh release download -R jezeklu/orca-pods -p orca-server -p orca-server.sig -D "$work"
  else
    for file in orca-server orca-server.sig; do
      curl -fsSL -o "$work/$file" "https://github.com/jezeklu/orca-pods/releases/latest/download/$file"
    done
  fi
  if ! ssh-keygen -Y verify -f "$signers" -I orca-pods -n orca-pods -s "$work/orca-server.sig" \
    <"$work/orca-server" >/dev/null 2>&1; then
    echo "Invalid signature, nothing changed." >&2
    exit 1
  fi
  chmod +x "$work/orca-server"
  mv "$work/orca-server" "$self"
  echo "Script updated from a signed release."
}

write_unit() {
  mkdir -p "$(dirname "$UNIT")"
  self=$(readlink -f "$0")
  cat >"$UNIT" <<UNITFILE
[Unit]
Description=Orca server $INSTANCE
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
KillMode=none

[Install]
WantedBy=default.target
UNITFILE
}

install_server() {
  doctor
  if [ ! -f "$CONFIG" ]; then
    mkdir -p "$(dirname "$CONFIG")"
    printf 'PODS_SECRETS_DIR="%s"\n' "$DEFAULT_SECRETS" >"$CONFIG"
    echo "Created $CONFIG."
    SECRETS=$DEFAULT_SECRETS
  fi
  [ -d "$SECRETS" ] || { mkdir -p "$SECRETS"; chmod 700 "$SECRETS"; }
  start_server
  pod exec --user dev orca-server orca-update --no-restart
  write_unit
  systemctl --user daemon-reload
  systemctl --user enable "orca-$INSTANCE.service"
  if ! loginctl enable-linger "$(id -un)" 2>/dev/null; then
    echo "Start at boot needs sudo here. Run: sudo loginctl enable-linger $(id -un)"
  fi
  echo "Done. Next: $prog login and $prog pair"
}

uninstall_server() {
  systemctl --user disable --now "orca-$INSTANCE.service" 2>/dev/null || true
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
  if pod exec orca-server curl -ksS -o /dev/null -m 6 "$@" 2>/dev/null; then got=pass; else got=block; fi
  [ "$got" = "$want" ]; report $? "$name ($got)"
}

inside() { # name shell-code that must succeed
  name=$1; shift
  pod exec --user dev orca-server sh -c "$1" >/dev/null 2>&1; report $? "$name"
}

# Runs on throwaway directories. The positive check switches the firewall off, so no data may be in reach.
run_tests() {
  url=${1:-}; ctl=""
  if [ -n "$url" ]; then
    host=${url#*://}; host=${host%%/*}
    ip=$(getent ahostsv4 "$host" | awk 'NR==1{print $1}')
    [ -n "$ip" ] || { echo "Cannot resolve the control target." >&2; exit 1; }
    ctl="--resolve $host:443:$ip $url"
  fi
  running && { echo "The server is running and the tests need its place. Stop it: $prog stop" >&2; exit 1; }
  teardown >/dev/null 2>&1
  set -e
  gw=$(ip route show default | awk 'NR==1{print $3}')
  hostip=$(ip route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')
  work=$STORE/test
  # A killed run leaves files owned by mapped users behind.
  pod unshare rm -rf "$work"
  mkdir -p "$work/secrets/github" "$work/agents/sample" "$work/skills"
  echo sample >"$work/agents/sample/SKILL.md"
  ln -s ../../.agents/skills/sample "$work/skills/sample"
  cp /bin/true "$work/secrets/program"
  echo secret >"$work/secrets/github/test.token"
  SECRETS=$work/secrets
  grant_secrets
  prepare_dirs "$work/home" "$work/state"
  chmod -R o+rX "$work/skills" "$work/agents"
  srv=$(mktemp -d); python3 -m http.server --directory "$srv" 18767 >/dev/null 2>&1 & srvpid=$!
  trap 'set +e; kill "$srvpid" 2>/dev/null; rm -rf "$srv"; teardown; pod unshare rm -rf "$work"' EXIT
  sleep 1

  net_up
  if echo 'table inet orca_pods { broken' | load_fw 2>/dev/null; then report 1 "broken firewall accepted"; else report 0 "broken firewall rejected, the server would not start"; fi
  firewall_rules | load_fw
  run_container --mount "type=bind,src=$work/home,dst=/home/dev" \
    --mount "type=bind,src=$work/state,dst=/state" \
    -v "$work/secrets:/secrets:ro,noexec,nosuid,nodev" \
    -v "$work/agents:/home/dev/.agents/skills:ro,nosuid,nodev" \
    -v "$work/skills:/home/dev/.claude/skills:ro,nosuid,nodev"
  pod exec -d --user dev orca-server python3 -m http.server 6768 --directory /tmp >/dev/null
  sleep 3

  brgw=$(pod exec orca-server sh -c "ip route | awk '/default/{print \$3}'")
  [ -n "$brgw" ] || { echo "FAIL  cannot find the container gateway"; exit 1; }
  check "LAN gateway" block "http://$gw"
  check "host" block "http://$hostip:18767"
  check "bridge" block "http://$brgw"
  check "host map 169.254.1.2" block "http://169.254.1.2:18767"
  check "host 5432" block "http://169.254.1.2:5432"
  check "host 6768" block "http://169.254.1.2:6768"
  [ -z "$ctl" ] || check "control target" block $ctl
  check "http example.com" block http://example.com
  check "https npm" pass https://registry.npmjs.org
  check "https github" pass https://github.com
  check "https pypi" pass https://pypi.org
  inside "ssh to github.com:22 blocked" '! timeout 6 bash -c "exec 3<>/dev/tcp/github.com/22"'

  inside "dev has UID 30100" 'test "$(id -u)" = 30100'
  inside "dev has no capabilities" 'grep -q "^CapEff:.*0000000000000000" /proc/self/status'
  inside "tailscale0 exists" 'ip -br link | grep -q tailscale0'
  inside "no docker.sock, ~/.ssh or GPG" 'test ! -e /var/run/docker.sock && test ! -e "$HOME/.ssh" && test ! -e "$HOME/.gnupg"'
  inside "writing to /secrets fails" '! touch /secrets/x'
  inside "writing to skills fails" '! touch /home/dev/.claude/skills/x'
  inside "/secrets is readable" 'cat /secrets/github/test.token'
  inside "symlink from a project to /secrets works" 'ln -s /secrets/github/test.token ~/projects/link && cat ~/projects/link'
  inside "relative link in skills works" 'cat ~/.claude/skills/sample/SKILL.md'
  inside "no host credentials" 'test ! -e ~/.claude/.credentials.json && test ! -e ~/.config/gh'
  inside "executing from /secrets fails while the file is readable" 'test -r /secrets/program && ! /secrets/program'
  inside "read-only root" '! touch /usr/x && ! touch /etc/x'
  inside "host home not visible" "test ! -e '$HOME' || test '$HOME' = /home/dev"
  inside "no other host data mounted" '! grep -E " /(mnt|media|host)" /proc/mounts'
  inside "orca-pods files in the image" 'command -v orca-update orca-restart orca-pair git-credential-pods gh'

  if curl -sS -m 6 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then report 0 "127.0.0.1:$PORT from the host"; else report 1 "127.0.0.1:$PORT from the host"; fi
  if curl -sS -m 3 -o /dev/null "http://$hostip:$PORT/" 2>/dev/null; then report 1 "LAN IP port $PORT open"; else report 0 "LAN IP port $PORT closed"; fi

  echo "--- positive check: firewall off for a moment, test container without data only"
  pod unshare --rootless-netns nft delete table inet orca_pods
  check "no fw: http example.com" pass http://example.com
  check "no fw: host map" pass "http://169.254.1.2:18767"
  [ -z "$ctl" ] || check "no fw: control target" pass $ctl

  [ "$FAILS" -eq 0 ] && echo "RESULT: all OK" || { echo "RESULT: $FAILS failed"; exit 1; }
}

main() {
  case "${1:-}" in
    doctor) doctor; return ;;
    packages) packages_cmd; return ;;
  esac
  require_user
  prepare_store
  case "${1:-}" in
    install) install_server ;;
    uninstall) uninstall_server ;;
    start) start_server ;;
    stop|cleanup) teardown ;;
    status) show_status ;;
    login) tailscale_login ;;
    pair) shift; pairing "$@" ;;
    update) update_all ;;
    self-update) self_update ;;
    test) shift; run_tests "$@" ;;
    *) echo "Usage: $prog [install|uninstall|start|stop|status|login|pair|update|self-update|test|cleanup|doctor|packages]" >&2; exit 1 ;;
  esac
}

[ -n "${PODS_SOURCED:-}" ] || main "$@"
