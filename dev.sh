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

run_tests() {
  url=${1:-}; ctl=""
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
  [ -z "$ctl" ] || check "control target" block $ctl
  check "http example.com" block http://example.com
  check "https tailscale.com" pass https://tailscale.com
  if pod exec orca-pods-client sh -c 'ip -br link | grep -q tailscale0'; then echo "OK    tailscale0 exists"; else echo "FAIL  tailscale0 missing"; FAILS=$((FAILS + 1)); fi
  [ "$(pod exec orca-pods-client id -u dev)" = 30100 ] && echo "OK    dev has UID 30100" || { echo "FAIL  dev UID"; FAILS=$((FAILS + 1)); }

  echo "--- positive check: firewall off for a moment, test container without data only"
  pod unshare --rootless-netns nft delete table inet orca_pods
  check "no fw: http example.com" pass http://example.com
  check "no fw: host map" pass "http://169.254.1.2:18767"
  [ -z "$ctl" ] || check "no fw: control target" pass $ctl

  kill "$srvpid" 2>/dev/null || true
  teardown; trap - EXIT; rm -rf "$srv"
  sleep 1
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
