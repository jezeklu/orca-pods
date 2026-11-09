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
  test "$(getent passwd dev | cut -d: -f7)" = /bin/bash || { echo "FAIL  login shell of dev"; exit 1; }
  test -r /usr/share/bash-completion/bash_completion || { echo "FAIL  bash-completion missing"; exit 1; }
  for tool in git gh mc vim htop curl jq rg gcc make python3 uv mise node npm pnpm claude codex opencode \
    Xvfb xauth dbus-launch ps tailscale tailscaled orca-update orca-restart orca-pair orca-devices orca-runtimes orca-skills orca-release git-credential-pods; do
    command -v "$tool" >/dev/null || { echo "FAIL  missing $tool"; exit 1; }
  done
  node --version; pnpm --version; uv --version; mise --version
  su dev -s /bin/bash -lc "case :\$PATH: in *:/home/dev/.local/bin:*/home/dev/.local/share/mise/shims:*/opt/node/bin:*) ;; *) echo \"FAIL  login shell PATH: \$PATH\"; exit 1 ;; esac"
'
./op-server.sh test
fi

# Real Orca: install, update with a live terminal, pairing, tools, crash and return.
sec=$PWD/.local/server-test-secrets
mkdir -p "$sec/github"
printf 'token-user\n' >"$sec/github/example-user.token"
printf 'token-org\n' >"$sec/github/example-org.token"
printf 'token-default\n' >"$sec/github/default.token"
PODS_SECRETS_DIR=$sec PODS_RUNTIMES=node@24
export PODS_SECRETS_DIR PODS_RUNTIMES
trap './op-server.sh stop >/dev/null 2>&1 || true' EXIT
# A first start, the checks of a fresh home must not see what an earlier run left.
pod unshare rm -rf "$STORE/home" "$STORE/state"
./op-server.sh start
pod exec --user dev orca-pods-server orca-update 1.4.241
pod exec -i --user dev orca-pods-server bash < tests/server-inside.sh
./op-server.sh pair | awk 'NR==1{print "pair: " $0} NR==2{print "pair: code " substr($0,1,17) "..."}'
# The rewritten code has to work, and a forged one must not.
pod exec -i --user dev orca-pods-server bash <<'SH'
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
before=$(jq length ~/.config/orca/orca-devices.json)
orca-devices rename "${id:0:8}" "test laptop" >/dev/null || { echo "FAIL  rename"; exit 1; }
for _ in $(seq 30); do orca-ide status --json 2>/dev/null | grep -q '"state": "ready"' && break; sleep 2; done
orca-devices | grep -q "^${id:0:8}  test laptop  " || { echo "FAIL  device not renamed"; exit 1; }
ORCA_PAIRING_CODE=$code orca-ide status --json | jq -e .ok >/dev/null || { echo "FAIL  renamed device lost its code"; exit 1; }
echo "OK    device renamed, its code still works"
orca-devices remove "${id:0:8}" >/dev/null || { echo "FAIL  remove"; exit 1; }
for _ in $(seq 30); do orca-ide status --json 2>/dev/null | grep -q '"state": "ready"' && break; sleep 2; done
if orca-devices | grep -q "^${id:0:8} "; then echo "FAIL  device still listed"; exit 1; fi
if ORCA_PAIRING_CODE=$code orca-ide status --json 2>/dev/null | jq -e .ok >/dev/null; then echo "FAIL  revoked code still works"; exit 1; fi
echo "OK    revoked device rejected"
test "$(jq length ~/.config/orca/orca-devices.json)" -eq $((before - 1)) || { echo "FAIL  a restart added a pairing code"; exit 1; }
echo "OK    restarts add no pairing codes"
orca-devices remove "zzzz" >/dev/null 2>&1 && { echo "FAIL  invalid id accepted"; exit 1; }
echo "OK    invalid device id rejected"
SH
./op-server.sh status

echo "--- Orca versions from the host"
latest=$(pod exec --user dev orca-pods-server orca-update --check)
./op-server.sh orca-update 1.4.241 >/dev/null
./op-server.sh status | grep -qx "Orca: 1.4.241, $latest available. Switch with: op-server.sh orca-update" \
  || { echo "FAIL  status after a rollback"; exit 1; }
echo "OK    status shows the running and the available Orca"
./op-server.sh orca-update >/dev/null
./op-server.sh status | grep -qx "Orca: $latest, the latest version." || { echo "FAIL  status after orca-update"; exit 1; }
echo "OK    orca-update switches to the latest Orca"
if ./op-server.sh orca-update '1.4;id' >/dev/null 2>&1; then echo "FAIL  invalid version accepted"; exit 1; fi
echo "OK    invalid version rejected"

echo "--- the server does not start without a firewall"
./op-server.sh stop >/dev/null
if PODS_SOURCED=1 sh -c '. ./op-server.sh; firewall_rules() { echo broken; }; prepare_store; start_server' >/dev/null 2>&1; then
  echo "FAIL  the server started with a broken firewall"; exit 1
fi
if pod container exists orca-pods-server; then echo "FAIL  the container was created"; exit 1; fi
echo "OK    no container with a broken firewall"
./op-server.sh start

echo "--- crash and recovery"
pod kill orca-pods-server >/dev/null
sleep 1
./op-server.sh start
pod exec --user dev orca-pods-server sh -c 'for i in $(seq 30); do orca-ide status --json 2>/dev/null | grep -q "\"state\": \"ready\"" && break; sleep 2; done; orca-ide status --json | jq -r .result.runtime.appVersion; test -d "$HOME/proj"'
test "$(pod exec orca-pods-server cat /etc/machine-id)" = "$(cat "$STORE/machine-id")" || { echo "FAIL  machine id not fixed"; exit 1; }
echo "OK    fixed machine id, a new image does not leave a foreign Orca lock"
./op-server.sh restart >/dev/null
[ "$(pod container inspect --format '{{.State.Running}}' orca-pods-server)" = true ] || { echo "FAIL  restart"; exit 1; }
echo "OK    restart"
./op-server.sh stop
ip -br link | grep -q "^br-orca-pods" && { echo "FAIL  br-orca-pods left behind"; exit 1; }
echo "RESULT e2e: all OK"
