#!/bin/sh
# Fast tests without Podman or network. Also run inside a container.
set -u
cd "$(dirname "$(readlink -f "$0")")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
FAILS=0
ok() { if [ "$2" = "$3" ]; then echo "OK    $1"; else echo "FAIL  $1: expected '$3', got '$2'"; FAILS=$((FAILS + 1)); fi; }

ROLE=client; PODS_CONFIG=$tmp/none; PODS_STORE=$tmp/store
export PODS_CONFIG PODS_STORE
. lib/common.sh
set +e

for v in 5.0.0 5.4.2 5.10.1 6.1.4; do version_ok "$v"; ok "version $v accepted" $? 0; done
for v in 4.9.3 4.9.10; do version_ok "$v"; ok "version $v rejected" $? 1; done

osr() { printf '%s\n' "$1" >"$tmp/os"; OS_RELEASE=$tmp/os os_family; }
ok "arch" "$(osr 'ID=arch')" arch
ok "fedora" "$(osr 'ID=fedora')" fedora
ok "debian" "$(osr 'ID=debian')" debian
ok "ubuntu" "$(osr 'ID=ubuntu
ID_LIKE=debian')" debian
ok "mint" "$(osr 'ID=linuxmint
ID_LIKE="ubuntu debian"')" debian
ok "rocky" "$(osr 'ID=rocky
ID_LIKE="rhel centos fedora"')" fedora
ok "unknown" "$(osr 'ID=gentoo')" unknown
OS_RELEASE=$tmp/os; export OS_RELEASE
printf 'ID=ubuntu\n' >"$tmp/os"
case "$(packages_cmd gocryptfs)" in "sudo apt install "*uidmap*gocryptfs*) r=ok ;; *) r=bad ;; esac; ok "ubuntu packages" "$r" ok
unset OS_RELEASE

ok "instance path" "$STORE" "$tmp/store/client"
ok "instance runroot" "$RUNROOT" "/run/user/$(id -u)/orca-pods-client"
case "$RUNROOT" in /run/user/*) r=ok ;; *) r=bad ;; esac; ok "runroot in /run/user" "$r" ok

for name in 'Bad' 'a/b' '-x' 'a b' 'secrets' ''; do
  ( ROLE=client; PODS_INSTANCE=$name; [ -n "$name" ] || PODS_INSTANCE=' '; . lib/common.sh ) >/dev/null 2>&1
  ok "instance '$name' rejected" $? 1
done
( ROLE=client; PODS_INSTANCE=main-2; . lib/common.sh; [ "$STORE" = "$tmp/store/main-2" ] )
ok "instance main-2" $? 0

printf 'PODS_INSTANCE=sample\n' >"$tmp/env"
ok "config file" "$(ROLE=client; PODS_CONFIG=$tmp/env; . lib/common.sh; echo "$INSTANCE")" sample

rules=$(firewall_rules)
for want in 'iifname "br-orca" drop' 'tcp dport 443 accept' '192.168.0.0/16' 'meta nfproto ipv6 drop'; do
  case "$rules" in *"$want"*) r=ok ;; *) r=bad ;; esac; ok "firewall: $want" "$r" ok
done

./build.sh
for f in dist/orca-*; do
  case "$f" in *.sig) continue ;; esac
  sh -n "$f"; ok "syntax $f" $? 0
  ok "no @include in $f" "$(grep -c '@include' "$f")" 0
  cp "$f" "$tmp/standalone"
  (cd "$tmp" && ./standalone packages >/dev/null); ok "$f runs standalone" $? 0
done

if command -v shellcheck >/dev/null; then
  shellcheck -x -S warning -e SC1091,SC2034 orca-client.sh dev.sh build.sh test.sh lib/common.sh tests/*.sh
  ok "shellcheck" $? 0
else
  echo "SKIP  shellcheck not installed"
fi

[ "$FAILS" -eq 0 ] && echo "RESULT: all OK" || { echo "RESULT: $FAILS failed"; exit 1; }
