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
export PODS_CONFIG="$cfg"
./orca-server.sh install
[ "$(systemctl --user is-enabled orca-server-test.service)" = enabled ]
./orca-server.sh stop
systemctl --user start orca-server-test.service
systemctl --user is-active orca-server-test.service
./orca-server.sh status
# Orca takes a moment after the unit reports active.
for _ in $(seq 60); do
  curl -sS -m 3 -o /dev/null http://127.0.0.1:16769/ 2>/dev/null && break
  sleep 2
done
curl -sS -m 10 -o /dev/null -w 'port from the host: %{http_code}\n' http://127.0.0.1:16769/
systemctl --user stop orca-server-test.service
./orca-server.sh uninstall
[ ! -e "$HOME/.config/systemd/user/orca-server-test.service" ]
echo "RESULT systemd: all OK"
