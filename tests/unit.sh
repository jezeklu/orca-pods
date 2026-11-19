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
  ( ROLE=server; PODS_INSTANCE=$name; [ -n "$name" ] || PODS_INSTANCE=' '; . lib/common.sh ) >/dev/null 2>&1
  ok "instance '$name' rejected" $? 1
done
( ROLE=server; PODS_INSTANCE=main-2; . lib/common.sh; [ "$STORE" = "$tmp/store/main-2" ] )
ok "instance main-2" $? 0

printf 'PODS_INSTANCE=sample\n' >"$tmp/env"
ok "config file" "$(ROLE=server; PODS_CONFIG=$tmp/env; . lib/common.sh; echo "$INSTANCE")" sample

for tools in 'agy;id' 'agy $(id)' 'AGY'; do
  ( PODS_SOURCED=1 PODS_TOOLS=$tools sh -c '. ./op-server.sh' ) >/dev/null 2>&1
  ok "PODS_TOOLS '$tools' rejected" $? 1
done
( PODS_SOURCED=1 PODS_TOOLS='agy other-tool' sh -c '. ./op-server.sh' ) >/dev/null 2>&1
ok "PODS_TOOLS list accepted" $? 0
for runtimes in 'node@24;id' 'node@$(id)' 'node@24 python/3'; do
  ( PODS_SOURCED=1 PODS_RUNTIMES=$runtimes sh -c '. ./op-server.sh' ) >/dev/null 2>&1
  ok "PODS_RUNTIMES '$runtimes' rejected" $? 1
done
( PODS_SOURCED=1 PODS_RUNTIMES='node@24 python@3.13 go@1.25' sh -c '. ./op-server.sh' ) >/dev/null 2>&1
ok "PODS_RUNTIMES list accepted" $? 0

for audio in 2 yes ' '; do
  ( PODS_SOURCED=1 PODS_AUDIO=$audio sh -c '. ./op-client.sh' ) >/dev/null 2>&1
  ok "PODS_AUDIO '$audio' rejected" $? 1
done
for audio in 0 1; do
  ( PODS_SOURCED=1 PODS_AUDIO=$audio sh -c '. ./op-client.sh' ) >/dev/null 2>&1
  ok "PODS_AUDIO $audio accepted" $? 0
done

# A rejected saved login falls back to an anonymous pull, other errors do not.
pull_log=$tmp/pull.log
pod() {
  echo "$*" >>"$pull_log"
  case "$*" in
    "pull -q --authfile "*) [ -z "${PULL_ANON_FAILS:-}" ] || { echo "Error: denied" >&2; return 1; } ;;
    "pull -q "*) echo "Error: $PULL_ERROR" >&2; return 1 ;;
  esac
}
: >"$pull_log"; PULL_ERROR="unauthorized: incorrect username or password"
( PULL=1; update_image ) 2>/dev/null
ok "rejected login retried anonymously" "$(grep -c -- '--authfile' "$pull_log")" 1
: >"$pull_log"; PULL_ERROR="connection refused"
( PULL=1; update_image ) >/dev/null 2>&1
ok "network error not retried" "$(grep -c -- '--authfile' "$pull_log")" 0
unset -f pod
. lib/common.sh
set +e

rules=$(firewall_rules)
for want in 'iifname "br-orca-pods" drop' 'tcp dport 443 accept' '192.168.0.0/16' 'meta nfproto ipv6 drop'; do
  case "$rules" in *"$want"*) r=ok ;; *) r=bad ;; esac; ok "firewall: $want" "$r" ok
done

# Host UID of dev, namespace ID 30101: from the running user namespace, else /etc/subuid in file order.
me=$(id -un)
host_uid() { # subuid-lines live-map
  printf '%b\n' "$1" >"$tmp/subuid"
  ( SUBUID_FILE=$tmp/subuid; LIVE_MAP=$2
    pod() { [ "$*" = "unshare cat /proc/self/uid_map" ] && [ -n "$LIVE_MAP" ] && printf '%b\n' "$LIVE_MAP"; }
    dev_host_uid 2>/dev/null )
}
ok "subuid: one line" "$(host_uid "$me:100000:65536" '')" 130100
ok "subuid: two adjacent lines" "$(host_uid "$me:100000:65536\n$me:165536:100000" '')" 130100
ok "subuid: first line shorter than 30101 IDs" "$(host_uid "$me:100000:30000\n$me:200000:65536" '')" 200100
ok "subuid: lines of other users skipped" "$(host_uid "other:100000:65536\n$me:165536:65536" '')" 195636
ok "subuid: line by UID" "$(host_uid "$(id -u):100000:65536" '')" 130100
ok "subuid: live map wins" "$(host_uid "$me:100000:65536" "0 $(id -u) 1\n1 300000 20000\n20001 400000 65536")" 410100
ok "subuid: live map without dev falls back" "$(host_uid "$me:100000:65536" "0 $(id -u) 1\n1 300000 1000")" 130100
ok "subuid: too few IDs" "$(host_uid "$me:100000:30000" ''; echo " $?")" " 1"
ok "subuid: no line" "$(host_uid "other:100000:65536" ''; echo " $?")" " 1"

# Without a host UID for dev, nothing gets an ACL: setfacl with an empty user changes the owner entry.
acl_log=$tmp/acl.log
: >"$acl_log"
mkdir -p "$tmp/acl-secrets"
ACL_LOG=$acl_log ACL_DIR=$tmp PODS_SOURCED=1 sh -c '. ./op-server.sh; set +e
  dev_host_uid() { return 1; }; setfacl() { echo "$*" >>"$ACL_LOG"; }
  SECRETS=$ACL_DIR/acl-secrets; grant_secrets' >/dev/null 2>&1
ok "server: no UID, grant_secrets fails" $? 1
mkdir -p "$tmp/acl-run"
ACL_LOG=$acl_log ACL_DIR=$tmp PODS_SOURCED=1 sh -c '. ./op-client.sh; set +e
  dev_host_uid() { return 1; }; setfacl() { echo "$*" >>"$ACL_LOG"; }; getfacl() { :; }
  AUDIO=1; PULSE_SOCK=$ACL_DIR/sock; RUNROOT=$ACL_DIR/acl-run; share_audio' >/dev/null 2>&1
ok "client: no UID, share_audio fails" $? 1
ok "no ACL set without a UID" "$(cat "$acl_log")" ""
ok "client: every ACL checks the UID" "$(grep -n 'setfacl.*\$(dev_host_uid)' op-client.sh op-server.sh)" ""

# prepare_dirs runs as root of the user namespace in a home that dev controls, so it follows no link.
mkdir -p "$tmp/fakebin"
printf '#!/bin/sh\necho "$*" >>"%s"\n' "$tmp/chown.log" >"$tmp/fakebin/chown"
chmod +x "$tmp/fakebin/chown"
dirs_case() { # shell code run in the home first
  rm -rf "$tmp/pd"; mkdir -p "$tmp/pd/home" "$tmp/pd/state" "$tmp/pd/victim"; : >"$tmp/chown.log"
  (cd "$tmp/pd/home" && eval "$1")
  PD=$tmp/pd PATH="$tmp/fakebin:$PATH" PODS_SOURCED=1 sh -c '. ./op-server.sh; set +e
    pod() { shift; "$@"; }
    prepare_dirs "$PD/home" "$PD/state"' >/dev/null 2>&1
}
dirs_case :
ok "prepare_dirs: fresh home" $? 0
ok "prepare_dirs: fresh home created" "$(test -d "$tmp/pd/home/.local/share/orca-server" && grep -c 'orca-server' "$tmp/chown.log")" 1
dirs_case 'ln -s ../victim .local'
ok "prepare_dirs: link at a parent refused" $? 1
ok "prepare_dirs: nothing created through the link" "$(ls -A "$tmp/pd/victim")" ""
dirs_case 'ln -s ../victim projects'
ok "prepare_dirs: link at a last component refused" $? 1
ok "prepare_dirs: link target not chowned" "$(grep -c projects "$tmp/chown.log")" 0
dirs_case 'touch .claude'
ok "prepare_dirs: file instead of a directory refused" $? 1

# The PATH of the server image starts in the home of dev, so root must not inherit it.
bad=$(grep -n 'pod exec' op-server.sh | grep -v -e '--user dev' -e '^[0-9]*:root_exec() {' -e '^[0-9]*: *pod exec --env "PATH=\$ROOT_PATH" ')
ok "every exec as root sets its PATH" "$bad" ""
ok "server tests exec only as dev" "$(grep -n 'pod exec' tests/server.sh | grep -v -e '--user dev')" ""
init_path=$(sed -n 's/^PATH=\(.*\)$/\1/p' server/bin/orca-server-init)
case ":$init_path:" in :/*:) case "$init_path" in *home*) r=bad ;; *) r=ok ;; esac ;; *) r=bad ;; esac
ok "orca-server-init sets a PATH without the home" "$r" ok

./build.sh
for f in dist/op-*; do
  case "$f" in *.sig) continue ;; esac
  sh -n "$f"; ok "syntax $f" $? 0
  ok "no @include in $f" "$(grep -c '@include' "$f")" 0
  cp "$f" "$tmp/standalone"
  (cd "$tmp" && ./standalone packages >/dev/null); ok "$f runs standalone" $? 0
done

# Signed self-update: only a release with a valid signature replaces the script.
mkdir -p "$tmp/rel" "$tmp/cfg"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/key"
printf 'orca-pods %s\n' "$(cat "$tmp/key.pub")" >"$tmp/cfg/allowed_signers"
cp dist/op-server "$tmp/rel/op-server"
echo '# new' >>"$tmp/rel/op-server"
ssh-keygen -q -Y sign -f "$tmp/key" -n orca-pods "$tmp/rel/op-server" </dev/null
cp dist/op-server "$tmp/deployed"
su_update() { PODS_CONFIG="$tmp/cfg/server.env" PODS_RELEASE_DIR="$tmp/rel" PODS_STORE="$tmp/store" "$tmp/deployed" self-update >/dev/null 2>&1; }
su_update; ok "valid signature" $? 0
ok "script replaced" "$(tail -n 1 "$tmp/deployed")" '# new'
cp dist/op-server "$tmp/deployed"
echo '# tampered' >>"$tmp/rel/op-server"
su_update; ok "tampered file rejected" $? 1
ok "script unchanged" "$(cmp -s dist/op-server "$tmp/deployed"; echo $?)" 0
ssh-keygen -q -t ed25519 -N '' -f "$tmp/other"
cp dist/op-server "$tmp/rel/op-server"
rm -f "$tmp/rel/op-server.sig"
ssh-keygen -q -Y sign -f "$tmp/other" -n orca-pods "$tmp/rel/op-server" </dev/null
su_update; ok "unknown key rejected" $? 1

# Every command main dispatches is described in help, so the help does not fall behind.
for role in server client; do
  help=$(PODS_CONFIG="$tmp/none" PODS_STORE="$tmp/store" "./op-$role.sh" help)
  ok "op-$role help" $? 0
  missing=""
  for cmd in $(sed -n '/^main() {/,/^}/s/^    \([a-z|-]*\)).*/\1/p' "op-$role.sh" | tr '|' ' '); do
    case $cmd in -*) continue ;; esac
    printf '%s\n' "$help" | grep -Eq "^  ([a-z-]+ \| )?$cmd( |$)" || missing="$missing $cmd"
  done
  ok "op-$role help lists every command" "$missing" ""
  err=$(PODS_CONFIG="$tmp/none" PODS_STORE="$tmp/store" "./op-$role.sh" no-such-command 2>&1 >/dev/null)
  ok "op-$role unknown command" $? 1
  # As root, the refusal to run with sudo comes first.
  [ "$(id -u)" -eq 0 ] || ok "op-$role unknown command message" "$err" "Unknown command: no-such-command. Run: op-$role.sh help"
done

if command -v shellcheck >/dev/null; then
  shellcheck -x -S warning -e SC1091,SC2034 op-client.sh op-server.sh dev.sh build.sh test.sh sign-release.sh lib/common.sh tests/*.sh server/bin/[a-z]* image/bin/[a-z]*
  ok "shellcheck" $? 0
else
  echo "SKIP  shellcheck not installed"
fi

[ "$FAILS" -eq 0 ] && echo "RESULT: all OK" || { echo "RESULT: $FAILS failed"; exit 1; }
