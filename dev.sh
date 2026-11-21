#!/bin/sh
# Development: the same run as op-client.sh, with an image built locally in .local/.
#
#   ./dev.sh                  start Orca with the local image
#   ./dev.sh login            log the running client in to Tailscale
#   ./dev.sh build            build the image locally
#   ./dev.sh test [URL]       isolation tests; URL is an internal target for the positive check, never stored
#   ./dev.sh cleanup          manual cleanup after a crash
#   ./dev.sh clean            remove locally built images, only in .local/
set -eu
cd "$(dirname "$(readlink -f "$0")")"

# Machine-specific paths stay out of git, see client.env.example.
PODS_CONFIG="$PWD/client.env"
PODS_STORE="$PWD/.local"
PODS_PULL=0
PODS_SOURCED=1
. ./op-client.sh

FAILS=0
check() { # name expected(pass|block) curl-args...
  name=$1; want=$2; shift 2
  if pod exec orca-pods-client curl -ksS -o /dev/null -m 6 "$@" 2>/dev/null; then got=pass; else got=block; fi
  if [ "$got" = "$want" ]; then echo "OK    $name ($got)"; else echo "FAIL  $name: expected $want, got $got"; FAILS=$((FAILS + 1)); fi
}

fail() { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }

# A throwaway vault in .local, passwords come on stdin, gocryptfs reads them line by line.
vault_tests() {
  echo "--- vault"
  if ! command -v gocryptfs >/dev/null; then echo "SKIP  vault, gocryptfs is not installed"; return 0; fi
  VAULT_BASE=$PWD/.local/test-vault VAULT=$PWD/.local/test-vault/vault OPEN=$PWD/.local/test-vault/vault-open
  CONFIG=$PWD/.local/test-client.env
  podman unshare rm -rf "$VAULT_BASE"
  : >"$CONFIG"
  if printf 'test-password\ntest-password\n' | (install_client) >/dev/null 2>&1 && [ -f "$VAULT/gocryptfs.conf" ] && [ ! -e "$RUNROOT" ]; then
    echo "OK    install creates the vault and installs Orca"
  else fail "install"; fi
  out=$(printf 'test-password\n' | (vault_shell -- sh -c 'id -u; pwd; echo "links=$(ip -br link | grep -vc "^lo ")"; touch ~/marker') 2>&1)
  case "$out" in
    *"30100"*"/home/dev"*) echo "OK    shell as dev in the vault" ;;
    *) fail "shell: $out" ;;
  esac
  case "$out" in *"links=0"*) echo "OK    shell without a network" ;; *) fail "shell network: $out" ;; esac
  if podman unshare mountpoint -q "$OPEN" || [ -e "$RUNROOT" ]; then fail "the vault stays unlocked after the shell"
  else echo "OK    the vault is locked after the shell"; fi
  [ "$(printf 'test-password\n' | (vault_shell -- sh -c 'test -f ~/marker && echo kept') 2>/dev/null)" = kept ] \
    && echo "OK    the shell writes into the vault" || fail "marker in the vault"
  if printf 'wrong\n' | (vault_shell -- true) >/dev/null 2>&1 || podman unshare mountpoint -q "$OPEN" || [ -e "$RUNROOT" ]; then
    fail "wrong password"
  else echo "OK    a wrong password opens nothing and leaves nothing"; fi
  mkdir -p "$RUNROOT"
  if printf 'test-password\n' | (vault_shell -- true) >/dev/null 2>&1; then fail "shell while the client runs"
  else echo "OK    no shell while the client runs"; fi
  rmdir "$RUNROOT"
  if (VAULT_BASE=$STORE/vault; uninstall_client) >/dev/null 2>&1; then fail "uninstall with the vault inside the store"
  else echo "OK    uninstall refuses a vault inside the store"; fi
  podman unshare rm -rf "$VAULT_BASE"
  rm -f "$CONFIG"
}

# A throwaway socket instead of the real one, the ACL must come back after teardown.
audio_tests() {
  echo "--- audio"
  dir=$(mktemp -d)
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$dir/native"
  before=$(getfacl -cp "$dir/native")
  if (AUDIO=1 PULSE_SOCK=$dir/native; mkdir -p "$RUNROOT"; share_audio \
      && getfacl -cp "$PULSE_SOCK" | grep -q "^user:$(dev_host_uid):rwx" && teardown >/dev/null); then
    echo "OK    PODS_AUDIO=1 grants the socket to dev only while the client runs"
  else fail "audio socket ACL"; fi
  [ "$(getfacl -cp "$dir/native")" = "$before" ] && [ ! -e "$RUNROOT" ] \
    && echo "OK    teardown restores the audio socket ACL" || fail "audio socket ACL after teardown"
  (AUDIO=0 PULSE_SOCK=$dir/native; mkdir -p "$RUNROOT"; share_audio; teardown >/dev/null)
  [ "$(getfacl -cp "$dir/native")" = "$before" ] && echo "OK    PODS_AUDIO=0 leaves the audio socket alone" || fail "audio socket with PODS_AUDIO=0"
  rm -rf "$dir"
}

run_tests() {
  url=${1:-}; ctl=""
  nested_note
  if [ -n "$url" ]; then
    host=${url#*://}; host=${host%%/*}
    ip=$(getent ahostsv4 "$host" | awk 'NR==1{print $1}')
    [ -n "$ip" ] || { echo "Cannot resolve the control target." >&2; exit 1; }
    ctl="--resolve $host:443:$ip $url"
  fi
  gw=$(ip route show default | awk 'NR==1{print $3}')
  hostip=$(ip route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')
  srv=$(mktemp -d); python3 -m http.server --directory "$srv" 18767 >/dev/null 2>&1 & srvpid=$!
  trap 'kill "$srvpid" 2>/dev/null; rm -rf "$srv"; teardown' EXIT
  sleep 1

  net_up
  if echo 'table inet orca_pods { broken' | load_fw 2>/dev/null; then echo "FAIL  broken firewall accepted"; FAILS=$((FAILS + 1)); else echo "OK    broken firewall rejected, the client would not start"; fi
  firewall_rules | load_fw
  start_client --tmpfs /state
  sleep 4

  brgw=$(pod exec orca-pods-client sh -c "ip route | awk '/default/{print \$3}'")
  [ -n "$brgw" ] || { echo "FAIL  cannot find the container gateway"; exit 1; }
  check "LAN gateway" block "http://$gw"
  check "host" block "http://$hostip:18767"
  check "bridge" block "http://$brgw"
  check "host map 169.254.1.2" block "http://169.254.1.2:18767"
  targets=$(host_443_targets "$hostip")
  [ -n "$targets" ] || echo "SKIP  no other host address answers on 443"
  n=0; for a in $targets; do n=$((n + 1)); check "host address $n on 443" block "http://$a:443"; done
  [ -z "$ctl" ] || check "control target" block $ctl
  check "http example.com" block http://example.com
  check "https tailscale.com" pass https://tailscale.com
  if pod exec orca-pods-client sh -c 'ip -br link | grep -q tailscale0'; then echo "OK    tailscale0 exists"; else echo "FAIL  tailscale0 missing"; FAILS=$((FAILS + 1)); fi
  if pod exec orca-pods-client test -e /pulse; then echo "FAIL  audio socket without PODS_AUDIO"; FAILS=$((FAILS + 1)); else echo "OK    no audio socket without PODS_AUDIO"; fi
  if pod exec orca-pods-client sh -c 'ldconfig -p | grep -q libpulse.so.0'; then echo "OK    libpulse in the image"; else echo "FAIL  libpulse missing"; FAILS=$((FAILS + 1)); fi
  [ "$(pod exec orca-pods-client id -u dev)" = 30100 ] && echo "OK    dev has UID 30100" || { echo "FAIL  dev UID"; FAILS=$((FAILS + 1)); }

  echo "--- Orca releases, kept in .local for the next run"
  [ "$(fetch_orca 1.4.241 2>/dev/null)" = 1.4.241 ] && echo "OK    Orca 1.4.241 installed in the container" || { echo "FAIL  Orca install"; FAILS=$((FAILS + 1)); }
  pod unshare sh -c 'cd "$1" && mkdir -p 0.0.1 0.0.2 && ln -sfn 0.0.2 current && chown -h 30101:30101 0.0.1 0.0.2 current' sh "$ORCA_DIR"
  fetch_orca 1.4.241 >/dev/null 2>&1
  if [ "$(readlink "$ORCA_DIR/current")" = 1.4.241 ] && [ -d "$ORCA_DIR/0.0.2" ] && [ ! -e "$ORCA_DIR/0.0.1" ]; then
    echo "OK    switch keeps only the previous version"
  else echo "FAIL  switch"; FAILS=$((FAILS + 1)); fi
  if [ -x "$ORCA_DIR/current/AppRun" ] && ! touch "$ORCA_DIR/x" "$ORCA_DIR/current/x" 2>/dev/null; then
    echo "OK    the host reads Orca and cannot change it"
  else echo "FAIL  Orca ownership"; FAILS=$((FAILS + 1)); fi
  if fetch_orca 0.0.3 >/dev/null 2>&1 || [ "$(readlink "$ORCA_DIR/current")" != 1.4.241 ]; then
    echo "FAIL  a nonexistent version"; FAILS=$((FAILS + 1))
  else echo "OK    a nonexistent version changed nothing"; fi
  pod unshare rm -rf "$ORCA_DIR/0.0.2"

  echo "--- positive check: firewall off for a moment, test container without data only"
  pod unshare --rootless-netns nft delete table inet orca_pods
  check "no fw: http example.com" pass http://example.com
  check "no fw: host map" pass "http://169.254.1.2:18767"
  n=0; for a in $targets; do n=$((n + 1)); check "no fw: host address $n on 443" pass "http://$a:443"; done
  [ -z "$ctl" ] || check "no fw: control target" pass $ctl

  kill "$srvpid" 2>/dev/null || true
  teardown; trap - EXIT; rm -rf "$srv"
  sleep 1
  echo "--- status"
  net_up
  firewall_rules | load_fw
  start_client --tmpfs /state --tmpfs /home/dev:rw,mode=1777 \
    --mount "type=bind,src=$(readlink -f "$ORCA_DIR/current"),dst=/opt/orca,readonly"
  status=$(show_status 2>&1)
  teardown >/dev/null
  case "$status" in
    *"Orca: 1.4.241, "*" available. "*"Servers: none paired."*) echo "OK    status of a running client" ;;
    *) echo "FAIL  status of a running client: $status"; FAILS=$((FAILS + 1)) ;;
  esac
  status=$( (show_status) 2>&1)
  case "$status" in
    *"not running"*"Orca: 1.4.241, "*" available. "*"op-server status"*) echo "OK    status of a closed client" ;;
    *) echo "FAIL  status of a closed client: $status"; FAILS=$((FAILS + 1)) ;;
  esac
  if (orca_update 1.4.241) >/dev/null 2>&1 && [ ! -e "$RUNROOT" ]; then echo "OK    orca-update of a closed client"
  else echo "FAIL  orca-update of a closed client"; FAILS=$((FAILS + 1)); fi
  vault_tests
  audio_tests
  echo "--- host"
  echo "ip_forward=$(cat /proc/sys/net/ipv4/ip_forward) br-orca-pods=$(ip -br link | grep -c br-orca-pods || true) pasta=$(pgrep -c pasta || true)"
  [ "$FAILS" -eq 0 ] && echo "RESULT: all OK" || { echo "RESULT: $FAILS failed"; exit 1; }
}

require_user
prepare_store
case "${1:-}" in
  "") run_client ;;
  login) tailscale_login ;;
  build)
    require_free
    pod build --security-opt label=disable --target client -t orca-pods .
    pod image prune -f >/dev/null
    pod images orca-pods
    rm -rf "$RUNROOT"
    ;;
  test)
    require_free
    run_tests "${2:-}"
    ;;
  cleanup) teardown ;;
  clean)
    require_free
    pod rmi -af >/dev/null 2>&1 || true
    rm -rf "$RUNROOT"
    echo "Local images removed."
    ;;
  *) echo "Usage: $0 [login|build|test [URL]|cleanup|clean]" >&2; exit 1 ;;
esac
