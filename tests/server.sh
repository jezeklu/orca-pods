#!/bin/sh
# Server role on this machine: image, isolation tests and a real Orca in the container.
#   tests/server.sh        everything
#   tests/server.sh image  build the image only
#   tests/server.sh e2e    real Orca in the container only, downloads two versions
#   tests/server.sh clean  remove the image and data of the test server
# Stores into .local/server-test and never touches a regular server.
set -eu
cd "$(dirname "$(readlink -f "$0")")/.."
PODS_CONFIG=/dev/null
PODS_STORE="$PWD/.local"
PODS_INSTANCE=server-test
PODS_PORT=16769
PODS_PULL=0
export PODS_CONFIG PODS_STORE PODS_INSTANCE PODS_PORT PODS_PULL
ROLE=server
. lib/common.sh

require_user
prepare_store
if [ "${1:-}" = clean ]; then
  pod rmi -af >/dev/null 2>&1 || true
  # Files of the container belong to mapped users.
  pod unshare rm -rf "$STORE/home" "$STORE/state" "$STORE/test" "$PWD/.local/server-test-secrets"
  echo "Test server removed."
  exit 0
fi
pod build --security-opt label=disable --target server -t orca-pods .
pod image prune -f >/dev/null
pod images orca-pods
[ "${1:-}" != image ] || exit 0
if [ "${1:-}" != e2e ]; then
pod run --rm --read-only --security-opt label=disable orca-pods sh -ec '
  test "$(id -u dev)" = 30100
  for tool in git gh mc htop curl jq rg gcc make python3 uv fnm node npm pnpm claude codex opencode \
    Xvfb xauth dbus-launch ps tailscale tailscaled orca-update orca-restart orca-pair orca-devices orca-node git-credential-pods; do
    command -v "$tool" >/dev/null || { echo "FAIL  missing $tool"; exit 1; }
  done
  node --version; pnpm --version; uv --version; fnm --version
  su dev -s /bin/bash -lc "case :\$PATH: in *:/home/dev/.local/bin:*:/opt/node/bin:*) ;; *) echo \"FAIL  login shell PATH: \$PATH\"; exit 1 ;; esac"
'
./orca-server.sh test
fi

# Real Orca: install, update with a live terminal, pairing, tools, crash and return.
sec=$PWD/.local/server-test-secrets
mkdir -p "$sec/github"
printf 'token-user\n' >"$sec/github/example-user.token"
printf 'token-org\n' >"$sec/github/example-org.token"
printf 'token-default\n' >"$sec/github/default.token"
PODS_SECRETS_DIR=$sec PODS_NODE_VERSIONS=24
export PODS_SECRETS_DIR PODS_NODE_VERSIONS
trap './orca-server.sh stop >/dev/null 2>&1 || true' EXIT
./orca-server.sh start
pod exec --user dev orca-server orca-update 1.4.241
pod exec -i --user dev orca-server bash < tests/server-inside.sh
./orca-server.sh pair | awk 'NR==1{print "pair: " $0} NR==2{print "pair: code " substr($0,1,17) "..."}'
# The rewritten code has to work, and a forged one must not.
pod exec -i --user dev orca-server bash <<'SH'
code=$(orca-pair ws://127.0.0.1:6768 | tail -n 1)
for _ in $(seq 30); do orca-ide status --json 2>/dev/null | grep -q '"state": "ready"' && break; sleep 2; done
ORCA_PAIRING_CODE=$code orca-ide status --json | jq -e '.ok and .result.target.kind == "environment"' >/dev/null || { echo "FAIL  rewritten code"; exit 1; }
echo "OK    rewritten pairing code works"
bad=$(printf '%s' "${code#*=}" | tr '_-' '/+' | base64 -d 2>/dev/null | jq -c '.deviceToken = "AAAA"' | base64 -w0 | tr '/+' '_-' | tr -d '=')
if ORCA_PAIRING_CODE="${code%%=*}=$bad" orca-ide status --json 2>/dev/null | jq -e .ok >/dev/null; then echo "FAIL  forged token accepted"; exit 1; fi
echo "OK    forged token rejected"
# Revoking the newest device ends that code, the list shows it before and not after.
id=$(jq -r 'max_by(.pairedAt) | .deviceId' ~/.config/orca/orca-devices.json)
orca-devices | grep -q "^${id:0:8} " || { echo "FAIL  device not listed"; exit 1; }
echo "OK    paired device listed"
orca-devices remove "${id:0:8}" >/dev/null || { echo "FAIL  remove"; exit 1; }
for _ in $(seq 30); do orca-ide status --json 2>/dev/null | grep -q '"state": "ready"' && break; sleep 2; done
if orca-devices | grep -q "^${id:0:8} "; then echo "FAIL  device still listed"; exit 1; fi
if ORCA_PAIRING_CODE=$code orca-ide status --json 2>/dev/null | jq -e .ok >/dev/null; then echo "FAIL  revoked code still works"; exit 1; fi
echo "OK    revoked device rejected"
orca-devices remove "zzzz" >/dev/null 2>&1 && { echo "FAIL  invalid id accepted"; exit 1; }
echo "OK    invalid device id rejected"
SH
./orca-server.sh status

echo "--- the server does not start without a firewall"
./orca-server.sh stop >/dev/null
if PODS_SOURCED=1 sh -c '. ./orca-server.sh; firewall_rules() { echo broken; }; prepare_store; start_server' >/dev/null 2>&1; then
  echo "FAIL  the server started with a broken firewall"; exit 1
fi
if pod container exists orca-server; then echo "FAIL  the container was created"; exit 1; fi
echo "OK    no container with a broken firewall"
./orca-server.sh start

echo "--- crash and recovery"
pod kill orca-server >/dev/null
sleep 1
./orca-server.sh start
pod exec --user dev orca-server sh -c 'for i in $(seq 30); do orca-ide status --json 2>/dev/null | grep -q "\"state\": \"ready\"" && break; sleep 2; done; orca-ide status --json | jq -r .result.runtime.appVersion; test -d "$HOME/proj"'
./orca-server.sh stop
ip -br link | grep -q "^br-orca" && { echo "FAIL  br-orca left behind"; exit 1; }
echo "RESULT e2e: all OK"
