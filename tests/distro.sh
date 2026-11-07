#!/bin/sh
# Slim containers: package names, installation and version checks on each distribution.
#   tests/distro.sh [image…]   all without arguments; PODS_CT=docker switches the runtime
#   tests/distro.sh clean      remove downloaded images, fresh ones are pulled next time
# Ubuntu: LTS 26.04 only.
set -eu
cd "$(dirname "$(readlink -f "$0")")/.."
CT=${PODS_CT:-podman}
IMAGES="docker.io/library/archlinux:latest docker.io/library/fedora:latest
  docker.io/library/debian:trixie-slim docker.io/library/ubuntu:26.04"

if [ "${1:-}" = clean ]; then
  for image in $IMAGES; do "$CT" rmi -f "$image" >/dev/null 2>&1 || true; done
  echo "Distribution images removed."
  exit 0
fi
./build.sh

inner='
case "$(. /etc/os-release; echo "$ID")" in
  arch) pacman -Syu --noconfirm >/dev/null; yes=--noconfirm ;;
  fedora) dnf -q -y install util-linux >/dev/null; yes=-y ;;
  *) apt-get -qq update; yes="-y --no-install-recommends" ;;
esac
cmd=$(sh /t/orca-client packages)
echo "+ $cmd"
eval "${cmd#sudo } $yes" >/dev/null 2>&1
useradd -m t
grep -q "^t:" /etc/subuid 2>/dev/null || echo "t:100000:65536" >>/etc/subuid
su - t -c "sh /t/orca-server doctor; sh /t/orca-client doctor"
'

fails=0
# shellcheck disable=SC2086 # the list splits on purpose
[ "$#" -gt 0 ] || set -- $IMAGES
for image in "$@"; do
  echo "=== $image"
  # Images stay for the next run. Docker Hub sometimes refuses a pull for a moment.
  for try in 1 2 3 4; do
    "$CT" image inspect "$image" >/dev/null 2>&1 && break
    "$CT" pull -q "$image" >/dev/null 2>&1 && break
    [ "$try" -lt 4 ] || { echo "FAIL  cannot pull $image"; }
    sleep $((try * 5))
  done
  out=$("$CT" run --rm -v "$PWD/dist:/t:ro" "$image" sh -c "$inner" 2>&1) && rc=0 || rc=$?
  printf '%s\n' "$out" | tail -n 5
  if [ "$rc" -eq 0 ]; then echo "OK    $image"; else echo "FAIL  $image"; fails=$((fails + 1)); fi
done
if [ "$fails" -ne 0 ]; then echo "RESULT: $fails failed"; exit 1; fi
echo "RESULT: all OK"
