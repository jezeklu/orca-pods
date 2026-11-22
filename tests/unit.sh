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

# Subordinate IDs for nested containers: the range doctor proposes, from fixture files and a getent stub.
nested_files() { # subuid subgid [login.defs] [nsswitch] [passwd] [group]
  printf '%b\n' "$1" >"$tmp/n-subuid"; printf '%b\n' "$2" >"$tmp/n-subgid"
  printf '%b\n' "${3:-SUB_UID_MIN 100000\nSUB_UID_MAX 600100000\nSUB_GID_MIN 100000\nSUB_GID_MAX 600100000}" >"$tmp/n-defs"
  printf '%b\n' "${4:-passwd: files systemd\ngroup: files [SUCCESS=merge] systemd\nsubid: files}" >"$tmp/n-nss"
  printf '%b\n' "${5:-root:x:0:0::/root:/bin/sh\nnobody:x:65534:65534::/:/bin/false}" >"$tmp/n-passwd"
  printf '%b\n' "${6:-root:x:0:\nnobody:x:65534:}" >"$tmp/n-group"
  N=$tmp PODS_SOURCED=1 sh -c '. ./op-server.sh; set +e
    SUBUID_FILE=$N/n-subuid SUBGID_FILE=$N/n-subgid LOGIN_DEFS=$N/n-defs NSSWITCH=$N/n-nss
    getent() { cat "$N/n-$1"; }
    nested_ids_files' 2>&1
}
cmd_of() { printf '%s\n' "$1" | sed -n 's/^ *\(sudo usermod .*\)$/\1/p'; }
out=$(nested_files "$me:100000:65536" "$me:100000:65536"); rc=$?
ok "nested ids: single user fails" $rc 1
ok "nested ids: single user command" "$(cmd_of "$out")" "sudo usermod --add-subuids 165536-296607 --add-subgids 165536-296607 $me"
out=$(nested_files "other:100000:65536\n$me:165536:65536\nthird:231072:65536" "other:100000:65536\n$me:165536:65536\nthird:231072:65536")
ok "nested ids: several users" "$(cmd_of "$out")" "sudo usermod --add-subuids 296608-427679 --add-subgids 296608-427679 $me"
out=$(nested_files "other:100000:65536\n$me:200000:65536" "other:100000:65536\n$me:200000:65536")
ok "nested ids: a gap too small is skipped" "$(cmd_of "$out")" "sudo usermod --add-subuids 265536-396607 --add-subgids 265536-396607 $me"
out=$(nested_files "other:100000:65536\n$me:400000:65536" "other:100000:65536\n$me:400000:65536")
ok "nested ids: a large enough gap is used" "$(cmd_of "$out")" "sudo usermod --add-subuids 165536-296607 --add-subgids 165536-296607 $me"
out=$(nested_files "$me:524288:65536" "$me:524288:65536" "SUB_UID_MIN 524288\nSUB_UID_MAX 600100000\nSUB_GID_MIN 524288\nSUB_GID_MAX 600100000")
ok "nested ids: Fedora SUB_UID_MIN 524288" "$(cmd_of "$out")" "sudo usermod --add-subuids 589824-720895 --add-subgids 589824-720895 $me"
out=$(nested_files "other:100000:400000\n$me:500000:65536" "other:100000:400000\n$me:500000:65536"); rc=$?
ok "nested ids: no block below 524288 fails" $rc 1
ok "nested ids: no block below 524288, no command" "$(cmd_of "$out")" ""
out=$(nested_files "$me:100000:65536" "$me:100000:65536" "" "" "root:x:0:0::/root:/bin/sh\nremote:x:200000:200000::/home/remote:/bin/sh")
ok "nested ids: an account UID inside the candidate is skipped" "$(cmd_of "$out")" "sudo usermod --add-subuids 200001-331072 --add-subgids 200001-331072 $me"
out=$(nested_files "$me:100000:65536" "$me:100000:65536" "SUB_UID_MIN 100000\nSUB_UID_MAX 200000\nSUB_GID_MIN 100000\nSUB_GID_MAX 200000"); rc=$?
ok "nested ids: no free block fails" $rc 1
ok "nested ids: no free block, no command" "$(cmd_of "$out")" ""
out=$(nested_files "$me:100000:65536\n$me:165536:131072" "$me:100000:65536\n$me:165536:131072"); rc=$?
ok "nested ids: enough already" $rc 0
ok "nested ids: enough already, no command" "$(cmd_of "$out")" ""
out=$(nested_files "$me:100000:30000\n$me:300000:35536\n$me:400000:100000" "$me:100000:30000\n$me:300000:35536\n$me:400000:100000"); rc=$?
ok "nested ids: ranges split over several lines" $rc 0
out=$(nested_files "$me:100000:65536\n$me:165536:131072" "$me:100000:65536")
ok "nested ids: only GIDs missing" "$(cmd_of "$out")" "sudo usermod --add-subgids 296608-427679 $me"
out=$(nested_files "$me:100000:65536" "$me:100000:65536" "" "passwd: files systemd\ngroup: files systemd\nsubid: sss"); rc=$?
ok "nested ids: subid from sss fails" $rc 1
ok "nested ids: subid from sss, no command" "$(cmd_of "$out")" ""
out=$(nested_files "$me:100000:65536" "$me:100000:65536" "" "passwd: files sss\ngroup: files sss"); rc=$?
ok "nested ids: accounts from sss fail" $rc 1
ok "nested ids: accounts from sss, no command" "$(cmd_of "$out")" ""
out=$(nested_files "$me:100000:65536\n$me:165536:131072" "$me:100000:65536\n$me:165536:131072" "" "passwd: files sss\ngroup: files"); rc=$?
ok "nested ids: accounts from sss, enough already" $rc 0

# The running user namespace: too small prints the migration steps and runs nothing.
live_map() { # uid_map gid_map [podman version]
  : >"$tmp/live.log"
  L=$tmp/live.log UMAP=$1 GMAP=$2 PV=${3:-5.4.2} PODS_SOURCED=1 sh -c '. ./op-server.sh; set +e
    podman() { echo "podman version $PV"; }
    pod() { echo "$*" >>"$L"
      case "$*" in "unshare cat /proc/self/uid_map") printf "%b\n" "$UMAP" ;; "unshare cat /proc/self/gid_map") printf "%b\n" "$GMAP" ;; *) return 1 ;; esac; }
    nested_live_map' 2>&1
}
small="0 1000 1\n1 100000 65536"
big="0 1000 1\n1 100000 65536\n65537 165536 131072"
out=$(live_map "$small" "$big"); rc=$?
ok "live map: too small fails" $rc 1
case "$out" in *"podman system migrate"*) r=ok ;; *) r=bad ;; esac; ok "live map: prints the migration" "$r" ok
ok "live map: runs nothing but reading the maps" "$(sort -u "$tmp/live.log" | tr '\n' ';')" "unshare cat /proc/self/gid_map;unshare cat /proc/self/uid_map;"
out=$(live_map "$big" "$small"); ok "live map: GIDs too small fail" $? 1
out=$(live_map "$big" "$big"); ok "live map: large enough" $? 0
out=$(live_map "$small" "$small" 4.9.3); rc=$?
ok "live map: old Podman skips" $rc 0
case "$out" in "SKIP  "*) r=ok ;; *) r=bad ;; esac; ok "live map: old Podman prints SKIP" "$r" ok
ok "live map: old Podman reads no map" "$(cat "$tmp/live.log")" ""

# PODS_CONTAINERS: only empty, 0 and 1. Without 1, doctor, install and start run no nested check.
for v in yes 2 ' '; do
  ( PODS_SOURCED=1 PODS_CONTAINERS=$v sh -c '. ./op-server.sh' ) >/dev/null 2>&1
  ok "PODS_CONTAINERS '$v' rejected" $? 1
done
for v in 0 1; do
  ( PODS_SOURCED=1 PODS_CONTAINERS=$v sh -c '. ./op-server.sh' ) >/dev/null 2>&1
  ok "PODS_CONTAINERS $v accepted" $? 0
done
flow() { # PODS_CONTAINERS command
  : >"$tmp/flow.log"
  L=$tmp/flow.log PODS_SOURCED=1 PODS_CONTAINERS=$1 sh -c '. ./op-server.sh; set +e
    log() { echo "$1" >>"$L"; }
    doctor() { log doctor; }; require_user() { log require_user; }; prepare_store() { log prepare_store; }
    nested_ids_files() { log nested_files; echo "FAIL  nested"; return 1; }; nested_live_map() { log nested_live; }
    check_secrets() { :; }; running() { return 1; }; teardown() { log teardown; }; update_image() { log update_image; }
    write_unit() { log write_unit; }; systemctl() { log systemctl; }
    '"$2" >/dev/null 2>&1
  echo "$?:$(tr '\n' ' ' <"$tmp/flow.log")"
}
ok "doctor: default mode unchanged" "$(flow '' server_doctor)" "0:doctor "
ok "doctor: nested check with PODS_CONTAINERS=1" "$(flow 1 server_doctor)" "1:doctor nested_files "
ok "start: default mode, no nested check" "$(flow 0 '(start_server)' | cut -d: -f2 | grep -c nested)" 0
ok "start: refused before anything runs" "$(flow 1 '(start_server)')" "1:nested_files "
ok "install: refused before the unit" "$(flow 1 '(install_server)')" "1:doctor nested_files "

# Nested mode: the flags of the server container in both modes, from run_container itself.
flags() { # PODS_CONTAINERS
  PODS_SOURCED=1 PODS_INSTANCE=t PODS_CONTAINERS=$1 sh -c '. ./op-server.sh; set +e
    pod() { printf "%s\n" "$@" >&2; }; SERVER_IMAGE=${SERVER_IMAGE:-orca-pods}; [ "$CONTAINERS" != 1 ] || SERVER_IMAGE=sha123
    run_container --extra; echo "STORE=$STORE"' 2>&1 | tr '\n' ' '
}
f0=$(flags 0); f1=$(flags 1)
st=${f1##*STORE=}; st=${st% }
ok "flags: default mode unchanged" "$f0" "run -d --rm --name orca-pods-server --hostname orca-pods-t --network orca-pods-net --dns 1.1.1.1 --dns 9.9.9.9 --uidmap 0:1:65536 --gidmap 0:1:65536 --device /dev/net/tun --cap-drop=all --cap-add=NET_ADMIN --security-opt no-new-privileges --security-opt label=disable --read-only --tmpfs /tmp:rw,exec,size=2g,mode=1777 --tmpfs /run --memory 10g --pids-limit 4096 -p 127.0.0.1:6769:6768 --extra orca-pods STORE=$st "
ok "flags: nested mode" "$f1" "run -d --rm --name orca-pods-server --hostname orca-pods-t --network orca-pods-net --dns 1.1.1.1 --dns 9.9.9.9 --uidmap 0:1:165536 --gidmap 0:1:165536 --device /dev/net/tun --cap-drop=all --cap-add=NET_ADMIN,SETUID,SETGID --security-opt label=disable --security-opt unmask=/proc/* --security-opt seccomp=$st/seccomp-nested.json --read-only --tmpfs /tmp:rw,exec,size=2g,mode=1777 --tmpfs /run --env PODS_NESTED=1 --env XDG_RUNTIME_DIR=/run/user/30100 --env DOCKER_HOST=unix:///run/user/30100/podman/podman.sock --memory 10g --pids-limit 16384 -p 127.0.0.1:6769:6768 --extra sha123 STORE=$st "
for f in "$f0" "$f1"; do
  case "$f" in *" --uidmap 0:1:"*" --gidmap 0:1:"*" --memory 10g --pids-limit "*) r=ok ;; *) r=bad ;; esac
  ok "flags: map from 0:1: and limits in both modes" "$r" ok
done
ok "flags: default mode passes no seccomp option" "$(printf '%s' "$f0" | grep -c seccomp)" 0

# Nested start: the order of the checks, the profile in the store, the helper for the Docker API.
nflow() { # PODS_CONTAINERS
  rm -rf "$tmp/nf"; mkdir -p "$tmp/nf/server"; : >"$tmp/nf.log"
  L=$tmp/nf.log NF=$tmp/nf PODS_SOURCED=1 PODS_STORE=$tmp/nf PODS_CONTAINERS=$1 sh -c '. ./op-server.sh; set +e
    log() { echo "$*" >>"$L"; }
    check_secrets() { :; }; running() { return 1; }; teardown() { :; }; update_image() { log update_image; }
    nested_ids_files() { log nested_files; }; nested_live_map() { log nested_live; }
    check_image() { log "check_image $1"; }; check_home() { log check_home; }; check_proc() { log "check_proc:$1"; }
    grant_secrets() { log grant; }; prepare_dirs() { log prepare_dirs; }; start_network() { log network; }
    run_container() { log "run $SERVER_IMAGE $*"; }
    pod() { case "$1 $2" in "image exists") ;; "image inspect") echo sha123 ;; "exec -d") log "$*" ;; esac; }
    start_server' >/dev/null 2>&1
  echo "$?"
}
ok "nested start: runs" "$(nflow 1)" 0
ok "nested start: order" "$(cut -d' ' -f1-2 "$tmp/nf.log" | tr '\n' ' ')" "nested_files nested_live update_image check_image sha123 grant prepare_dirs check_home network run sha123 check_proc:$tmp/nf/server/proc-warning exec -d exec -d "
ok "nested start: /state without setuid and devices" "$(grep -c '^run .*dst=/state,nosuid,nodev ' "$tmp/nf.log")" 1
ok "nested start: warning kept in the store" "$(grep -c "^check_proc:$tmp/nf/server/proc-warning$" "$tmp/nf.log")" 1
ok "nested start: orca-serve, then the Docker API helper" "$(grep '^exec' "$tmp/nf.log" | tr '\n' ' ')" "exec -d --user dev orca-pods-server orca-serve exec -d --user dev orca-pods-server orca-containers "
ok "nested start: profile written to the store" "$(cmp -s "$tmp/nf/server/seccomp-nested.json" server/seccomp-nested.json; echo $?)" 0
ok "default start: runs" "$(nflow 0)" 0
ok "default start: no image check, no home check, no helper" "$(grep -c -e check_image -e check_home -e check_proc -e orca-containers "$tmp/nf.log")" 0
ok "default start: image by tag, /state as today" "$(grep -c '^run orca-pods .*dst=/state -v' "$tmp/nf.log")" 1
ok "default start: no profile in the store" "$(test -e "$tmp/nf/server/seccomp-nested.json" && echo found)" ""

# The image check: the image lists its own setuid files and file capabilities.
good='/usr/bin/newgidmap cap_setgid=ep
/usr/bin/newuidmap cap_setuid=ep'
imgcheck() { # scan output, scan exit code, [ID already in image-checked]
  rm -rf "$tmp/ic"; mkdir -p "$tmp/ic"; : >"$tmp/ic.log"
  [ -z "${3:-}" ] || printf '%s\n' "$3" >"$tmp/ic/image-checked"
  OUT=$1 RC=$2 IC=$tmp/ic L=$tmp/ic.log PODS_SOURCED=1 PODS_CONTAINERS=1 sh -c '. ./op-server.sh; set +e
    STORE=$IC; pod() { echo "$*" >>"$L"; [ -z "$OUT" ] || printf "%s\n" "$OUT"; return "$RC"; }
    check_image sha123' >/dev/null 2>&1
  echo "$?"
}
ok "image check: the server image passes" "$(imgcheck "$good" 0)" 0
ok "image check: result kept" "$(cat "$tmp/ic/image-checked")" sha123
ok "image check: no network, no capability but reading, NNP" "$(grep -c -- '^run --rm --network none --cap-drop=all --cap-add=DAC_READ_SEARCH --security-opt no-new-privileges .* sha123 ' "$tmp/ic.log")" 1
ok "image check: setuid file refused" "$(imgcheck "$good
setid /usr/bin/sudo" 0)" 1
ok "image check: a refused image is not kept" "$(test -e "$tmp/ic/image-checked" && echo kept)" ""
ok "image check: third file capability refused" "$(imgcheck "$good
/usr/bin/ping cap_net_raw=ep" 0)" 1
ok "image check: missing capability refused" "$(imgcheck '/usr/bin/newgidmap cap_setgid=ep' 0)" 1
ok "image check: missing getcap refused" "$(imgcheck "find: 'getcap': No such file or directory" 1)" 1
ok "image check: find error refused" "$(imgcheck "$good
find: '/x': Permission denied" 1)" 1
ok "image check: failed scan refused" "$(imgcheck "$good" 1)" 1
ok "image check: checked image not scanned again" "$(imgcheck '' 1 sha123):$(wc -l <"$tmp/ic.log")" "0:0"
ok "image check: another image scanned" "$(imgcheck "$good" 0 sha999):$(cat "$tmp/ic/image-checked")" "0:sha123"

# The home check: a setuid file of container root or setgid file of its group would work inside.
homecheck() { # find output, find exit code
  : >"$tmp/hc.log"
  OUT=$1 RC=$2 L=$tmp/hc.log PODS_SOURCED=1 PODS_CONTAINERS=1 sh -c '. ./op-server.sh; set +e
    pod() { echo "$*" >>"$L"; [ -z "$OUT" ] || printf "%s\n" "$OUT"; return "$RC"; }; check_home' >/dev/null 2>&1
  echo "$?"
}
ok "home check: clean home" "$(homecheck '' 0)" 0
ok "home check: searches setuid of ID 1 and setgid of group 1" "$(grep -c -e '-uid 1 -perm -4000' "$tmp/hc.log"):$(grep -c -e '-gid 1 -perm -2000' "$tmp/hc.log")" "1:1"
ok "home check: setuid file refused" "$(homecheck /home/x/bin/sh 0)" 1
ok "home check: find error refused" "$(homecheck '' 1)" 1

# The /proc check after a nested start: container root may write only the allowlist and known
# kernel leaks, which stay as a warning for status and doctor.
proccheck() { # find output, [a warning left from the last start]
  rm -rf "$tmp/pc"; mkdir -p "$tmp/pc"
  [ -z "${2:-}" ] || echo old >"$tmp/pc/proc-warning"
  OUT=$1 PC=$tmp/pc PODS_SOURCED=1 PODS_CONTAINERS=1 sh -c '. ./op-server.sh; set +e
    root_exec() { printf "%s\n" "$OUT"; return 1; }; check_proc "$PC/proc-warning"' >"$tmp/pc.out" 2>&1
  echo "$?"
}
allowed='/proc/sys/net/core/somaxconn
/proc/sys/kernel/shmmax'
ok "proc check: only the allowlist" "$(proccheck "$allowed" old):$(test -e "$tmp/pc/proc-warning" && echo kept)" "0:"
ok "proc check: cad_pid starts with a warning" "$(proccheck "$allowed
/proc/sys/kernel/cad_pid")" 0
ok "proc check: cad_pid warning printed" "$(grep -c '^WARNING: .*cad_pid' "$tmp/pc.out")" 1
ok "proc check: cad_pid warning kept" "$(grep -c 'cad_pid' "$tmp/pc/proc-warning")" 1
ok "proc check: another file refused" "$(proccheck "$allowed
/proc/sys/kernel/cad_pid
/proc/sys/kernel/core_pattern")" 1
ok "proc check: refusal names the file" "$(grep -c '^/proc/sys/kernel/core_pattern$' "$tmp/pc.out")" 1
ok "proc check: empty list refused" "$(proccheck '')" 1
warnshow() { # command
  rm -rf "$tmp/ws"; mkdir -p "$tmp/ws"; echo 'WARNING: test leak' >"$tmp/ws/proc-warning"
  WS=$tmp/ws PODS_SOURCED=1 PODS_CONTAINERS=1 sh -c '. ./op-server.sh; set +e
    STORE=$WS; running() { :; }; tailscale_state() { :; }; orca_versions() { :; }; pod() { :; }
    doctor() { :; }; nested_ids_files() { :; }; require_user() { :; }; prepare_store() { :; }; nested_live_map() { :; }
    '"$1" 2>&1 | grep -c 'WARNING: test leak'
}
ok "proc check: status shows the warning" "$(warnshow show_status)" 1
ok "proc check: doctor shows the warning" "$(warnshow server_doctor)" 1

# Port 80 only for a nested server, after every drop.
fw() { # role PODS_CONTAINERS
  PODS_SOURCED=1 PODS_CONTAINERS=$2 sh -c '. ./op-'"$1"'.sh; host_addresses() { echo 203.0.113.7; }; firewall_rules'
}
case "$(fw server 1)" in
  *'240.0.0.0/4'*'} drop'*'ip daddr { 203.0.113.7 } drop'*'tcp dport 443 accept'*'tcp dport 80 accept'*'meta l4proto udp accept'*) r=ok ;; *) r=bad ;; esac
ok "firewall: nested server accepts port 80 after the drops" "$r" ok
ok "firewall: default server, no port 80" "$(fw server 0 | grep -c 'dport 80 ')" 0
ok "firewall: client, no port 80" "$(fw client 1 | grep -c 'dport 80 ')" 0

# Nested processes are visible in the PID namespace of the server, so the helpers must not touch them.
ok "server/bin: pkill and pgrep stay in the own PID namespace" "$(grep -n -E '\b(pkill|pgrep)\b' server/bin/* | grep -v -e '--ns \$\$ --nslist pid' -e ':[0-9]*: *#')" ""

# The nested profile is the pinned upstream default plus sethostname, setdomainname and chroot.
if command -v jq >/dev/null; then
  ok "seccomp: pinned upstream default" "$(sha256sum server/seccomp-default.json | cut -d' ' -f1)" 9b755202516aee4b45d9d411ab800c20fe4f7af97166a93b7f07d5b16c1a4ecd
  three='["chroot", "setdomainname", "sethostname"]'
  ok "seccomp: the three are conditional in the default" "$(jq --argjson t "$three" '[.syscalls[] | select(.action == "SCMP_ACT_ERRNO" and (.names - $t) != .names)] | length' server/seccomp-default.json)" 2
  derived=$(jq -S --argjson t "$three" '.syscalls |= (map(if .action == "SCMP_ACT_ERRNO" then .names -= $t else . end | select(.names != []))
    + [{names: $t, action: "SCMP_ACT_ALLOW"}])' server/seccomp-default.json)
  ok "seccomp: nested profile differs only in the three syscalls" "$(jq -S . server/seccomp-nested.json 2>&1)" "$derived"
else
  echo "SKIP  seccomp profile, jq not installed"
fi
ok "seccomp: op-server.sh carries the profile" "$(PODS_SOURCED=1 sh -c '. ./op-server.sh; seccomp_profile' 2>&1 | cmp -s - server/seccomp-nested.json; echo $?)" 0

ok "help names PODS_CONTAINERS" "$(PODS_CONFIG="$tmp/none" PODS_STORE="$tmp/store" ./op-server.sh help | grep -c PODS_CONTAINERS)" 1
ok "server.env.example names PODS_CONTAINERS" "$(grep -c '^#PODS_CONTAINERS=1$' server.env.example)" 1

# The README command that deletes the nested store from the host, run as written. A fake podman
# drops "unshare", the paths below the home are what the container could have planted.
delcmd=$(sed -n '/^If the server no longer starts for step 1/,/^```$/p' README.md | grep '^podman unshare ')
ok "README delete command: default home of the server" "$(printf '%s' "$delcmd" | grep -c ' sh ~/.local/share/orca-pods/server/home$')" 1
mkdir -p "$tmp/fp" && printf '%s\n' '#!/bin/sh' 'shift; exec "$@"' >"$tmp/fp/podman" && chmod 755 "$tmp/fp/podman"
delrun() { # home
  PATH=$tmp/fp:$PATH sh -c "${delcmd% *} \"\$1\"" sh "$1" >/dev/null 2>&1
  echo "$?"
}
victim() { rm -rf "$tmp/victim"; mkdir -p "$tmp/victim/share/containers"; echo x >"$tmp/victim/share/containers/f"; }
rm -rf "$tmp/dh"; mkdir -p "$tmp/dh/.local/share/containers/storage"; echo x >"$tmp/dh/.local/share/containers/storage/f"
ok "README delete command: deletes the store" "$(delrun "$tmp/dh"):$(test -e "$tmp/dh/.local/share/containers" && echo left)" "0:"
ok "README delete command: keeps the rest of the home" "$(test -d "$tmp/dh/.local/share" && echo kept)" kept
victim; rm -rf "$tmp/dh"; mkdir -p "$tmp/dh"; ln -s "$tmp/victim" "$tmp/dh/.local"
ok "README delete command: link at .local refused" "$(delrun "$tmp/dh"):$(cat "$tmp/victim/share/containers/f")" "1:x"
victim; rm -rf "$tmp/dh"; mkdir -p "$tmp/dh/.local"; ln -s "$tmp/victim/share" "$tmp/dh/.local/share"
ok "README delete command: link at .local/share refused" "$(delrun "$tmp/dh"):$(cat "$tmp/victim/share/containers/f")" "1:x"
victim; rm -rf "$tmp/dh"; mkdir -p "$tmp/dh/.local/share"; ln -s "$tmp/victim/share/containers" "$tmp/dh/.local/share/containers"
ok "README delete command: link at containers removes only the link" "$(delrun "$tmp/dh"):$(cat "$tmp/victim/share/containers/f"):$(test -L "$tmp/dh/.local/share/containers" && echo left)" "0:x:"

# Inside a server with containers the outer firewall blocks the same targets, the tests say so.
NESTED_MARKER=$tmp/nested-marker
ok "no note outside a nested server" "$(nested_note)" ""
: >"$NESTED_MARKER"
case "$(nested_note)" in "WARNING: "*"outer firewall"*"./test.sh vm"*) r=ok ;; *) r=bad ;; esac
ok "note inside a nested server" "$r" ok
rm -f "$NESTED_MARKER"
for f in op-server.sh dev.sh; do
  ok "$f: isolation tests print the note" "$(sed -n '/^run_tests() {/,/^}/p' "$f" | grep -c '^  nested_note$')" 1
done

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

# tests/vm.sh with fake QEMU and ssh: the settings reach QEMU, a bad value stops before anything runs.
if [ -w /dev/kvm ]; then
  mkdir -p "$tmp/vmbin" "$tmp/vm/images"
  : >"$tmp/vm/images/debian.qcow2"
  for tool in qemu-system-x86_64 qemu-img; do
    printf '#!/bin/sh\necho "%s $*" >>"%s"\n' "$tool" "$tmp/qemu.log" >"$tmp/vmbin/$tool"
  done
  # Keeps only the script that runs in the VM, not the copy of the repository.
  printf '#!/bin/sh\ncase "$*" in *"bash -s") cat >>"%s" ;; *) cat >/dev/null ;; esac\n' "$tmp/ssh.log" >"$tmp/vmbin/ssh"
  chmod +x "$tmp/vmbin/"*
  vm_run() { : >"$tmp/qemu.log"; env PATH="$tmp/vmbin:$PATH" PODS_VM_DIR="$tmp/vm" "$@" tests/vm.sh debian </dev/null 2>&1; }
  for setting in PODS_VM_DISK=20 PODS_VM_MEMORY=lots PODS_VM_CPUS=0 PODS_VM_DIR=relative PODS_VM_KEEP=yes; do
    vm_run "$setting" >/dev/null; ok "vm: $setting rejected" $? 1
    ok "vm: $setting starts nothing" "$(cat "$tmp/qemu.log")" ""
  done
  out=$(vm_run PODS_VM_DISK=30G PODS_VM_MEMORY=6G PODS_VM_CPUS=4); ok "vm: run with settings" $? 0
  ok "vm: disk size" "$(grep -c "^qemu-img create .*$tmp/vm/run-debian/disk.qcow2 30G$" "$tmp/qemu.log")" 1
  ok "vm: memory and CPUs" "$(grep -c '^qemu-system-x86_64 .*-smp 4 -m 6G ' "$tmp/qemu.log")" 1
  ok "vm: run directory removed" "$(ls -A "$tmp/vm" | tr '\n' ' ')" "images "
  out=$(vm_run); ok "vm: defaults" "$(grep -c -e ' 20G$' -e '-smp 2 -m 4G ' "$tmp/qemu.log")" 2
  out=$(vm_run PODS_VM_KEEP=1)
  line=$(printf '%s\n' "$out" | grep '^The VM keeps running. Log in with: ssh ')
  case "$line" in *" -i $tmp/vm/run-debian/key -p 20222 "*"UserKnownHostsFile=/dev/null"*" pods@127.0.0.1") r=ok ;; *) r=bad ;; esac
  ok "vm: PODS_VM_KEEP=1 prints the ssh command" "$r" ok
  for setting in "PODS_CONTAINERS=yes PODS_VM_SERVER=1" PODS_CONTAINERS=1; do
    # shellcheck disable=SC2086 # two settings
    vm_run $setting >/dev/null; ok "vm: $setting rejected" $? 1
    ok "vm: $setting starts nothing" "$(cat "$tmp/qemu.log")" ""
  done
  : >"$tmp/ssh.log"; vm_run PODS_VM_SERVER=1 PODS_CONTAINERS=1 >/dev/null
  ok "vm: PODS_CONTAINERS=1 reaches the VM" "$(grep -c '^export PODS_CONTAINERS=1$' "$tmp/ssh.log")" 1
  ok "vm: the VM adds the range doctor prints" "$(grep -c '^  add=.*op-server.sh doctor' "$tmp/ssh.log")" 1
else
  echo "SKIP  vm settings, no access to /dev/kvm"
fi

# The PATH of the server image starts in the home of dev, so root must not inherit it.
bad=$(grep -n 'pod exec' op-server.sh | grep -v -e '--user dev' -e '^[0-9]*:root_exec() {' -e '^[0-9]*: *pod exec --env "PATH=\$ROOT_PATH" ')
ok "every exec as root sets its PATH" "$bad" ""
ok "server tests exec only as dev" "$(grep -n 'pod exec' tests/server.sh | grep -v -e '--user dev')" ""
init_path=$(sed -n 's/^PATH=\(.*\)$/\1/p' server/bin/orca-server-init)
case ":$init_path:" in :/*:) case "$init_path" in *home*) r=bad ;; *) r=ok ;; esac ;; *) r=bad ;; esac
ok "orca-server-init sets a PATH without the home" "$r" ok

# Own addresses of the host go into a drop rule of their own, before any accept.
host_addresses() { printf '%s\n' 203.0.113.7 198.51.100.9; }
rules=$(firewall_rules)
case "$rules" in *'ip daddr { 203.0.113.7, 198.51.100.9 } drop'*'tcp dport 443 accept'*) r=ok ;; *) r=bad ;; esac
ok "firewall: host addresses dropped before the accepts" "$r" ok
host_addresses() { :; }
case "$(firewall_rules)" in *'{  }'*|*'{ }'*) r=bad ;; *) r=ok ;; esac
ok "firewall: no empty set without host addresses" "$r" ok
. lib/common.sh
set +e

./build.sh
for f in dist/op-*; do
  case "$f" in *.sig) continue ;; esac
  sh -n "$f"; ok "syntax $f" $? 0
  ok "no @include in $f" "$(grep -c '@include' "$f")" 0
  cp "$f" "$tmp/standalone"
  (cd "$tmp" && ./standalone packages >/dev/null); ok "$f runs standalone" $? 0
done
ok "seccomp: the profile in dist/op-server is the repository file" "$(PODS_SOURCED=1 sh -c '. dist/op-server; seccomp_profile' 2>&1 | cmp -s - server/seccomp-nested.json; echo $?)" 0

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
