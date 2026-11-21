#!/bin/sh
# In a VM: server role, then a real install with the systemd unit.
set -eux
sudo loginctl enable-linger "$(id -un)"
tests/server.sh
cfg=$PWD/.local/vm-server.env
sec=$PWD/.local/vm-secrets
mkdir -p "$sec"
cat >"$cfg" <<CFG
PODS_INSTANCE=server-test
PODS_STORE="$PWD/.local"
PODS_PORT=16769
PODS_PULL=0
PODS_SECRETS_DIR="$sec"
CFG
# The unit reads only the settings file.
[ -z "${PODS_CONTAINERS:-}" ] || echo "PODS_CONTAINERS=$PODS_CONTAINERS" >>"$cfg"
export PODS_CONFIG="$cfg"
./op-server.sh install
[ "$(systemctl --user is-enabled orca-pods-server-test.service)" = enabled ]
[ "$(systemctl --user is-active orca-pods-server-test.service)" = active ]
grep -qx 'KillMode=mixed' "$HOME/.config/systemd/user/orca-pods-server-test.service"
systemctl --user stop orca-pods-server-test.service
PODS_SOURCED=1 sh -c '. ./op-server.sh; prepare_store; ! running'
systemctl --user start orca-pods-server-test.service
systemctl --user is-active orca-pods-server-test.service
st=$(./op-server.sh status 2>&1)
printf '%s\n' "$st"
# A warning of the start under systemd must show in status.
[ ! -s .local/proc-warning ] || printf '%s\n' "$st" | grep -q '^WARNING: this kernel'
# Orca takes a moment after the unit reports active.
for _ in $(seq 60); do
  curl -sS -m 3 -o /dev/null http://127.0.0.1:16769/ 2>/dev/null && break
  sleep 2
done
curl -sS -m 10 -o /dev/null -w 'port from the host: %{http_code}\n' http://127.0.0.1:16769/
systemctl --user stop orca-pods-server-test.service
./op-server.sh uninstall
[ ! -e "$HOME/.config/systemd/user/orca-pods-server-test.service" ]
echo "RESULT systemd: all OK"
