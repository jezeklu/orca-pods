#!/bin/sh
# Runs as root in a short container of the server image, see tests/server.sh.
# Checks the parts for containers inside the server that need no running server.
set -u
bad=0
fail() { echo "FAIL  $*"; bad=1; }

for tool in /usr/bin/podman /usr/bin/docker /usr/bin/newuidmap /usr/bin/newgidmap /usr/bin/pasta \
  /usr/sbin/nft /usr/bin/setfacl /usr/sbin/getcap /usr/bin/crun /usr/bin/shellcheck /usr/bin/setpriv; do
  [ -x "$tool" ] || fail "missing $tool"
done
for tool in netavark aardvark-dns; do
  [ -x "/usr/lib/podman/$tool" ] || fail "missing $tool"
done
[ "$bad" = 1 ] || echo "OK    container tools present"

# Without NNP every setuid file would be a way to container root, see the README.
files=$(find / -xdev -type f -perm /6000 2>&1)
if [ -n "$files" ]; then fail "setuid or setgid files: $(echo "$files" | tr '\n' ' ')"
else echo "OK    no setuid or setgid file"; fi
caps=$(getcap -r / 2>/dev/null | sort | tr '\n' ' ')
if [ "$caps" = "/usr/bin/newgidmap cap_setgid=ep /usr/bin/newuidmap cap_setuid=ep " ]; then
  echo "OK    file capabilities only on newuidmap and newgidmap"
else
  fail "file capabilities: $caps"
fi

if [ "$(cat /etc/subuid)" = dev:100000:65536 ] && [ "$(cat /etc/subgid)" = dev:100000:65536 ]; then
  echo "OK    subordinate IDs of dev"
else
  fail "subuid or subgid: $(cat /etc/subuid /etc/subgid | tr '\n' ' ')"
fi

conf=/etc/containers/containers.conf
ok=1
for line in 'cgroup_manager = "cgroupfs"' 'events_logger = "file"' 'log_driver = "k8s-file"' 'image_copy_tmp_dir = "storage"'; do
  grep -qxF "$line" "$conf" 2>/dev/null || { fail "$conf lacks $line"; ok=0; }
done
grep -rqxF 'unqualified-search-registries = ["docker.io"]' /etc/containers/registries.conf /etc/containers/registries.conf.d 2>/dev/null \
  || { fail "short names do not resolve to docker.io"; ok=0; }
[ "$ok" = 0 ] || echo "OK    Podman configuration"

for cmd in podman docker; do
  [ "$(command -v "$cmd")" = "/usr/local/bin/$cmd" ] || fail "$cmd is not the wrapper"
  out=$(su dev -s /bin/sh -c "$cmd --version" 2>&1) && fail "$cmd ran without the marker"
  if [ "$out" = "Containers need PODS_CONTAINERS=1, see README." ]; then
    echo "OK    $cmd without the marker prints the hint"
  else
    fail "$cmd without the marker: $out"
  fi
done

[ "$bad" = 0 ] && echo "RESULT image: all OK"
exit "$bad"
