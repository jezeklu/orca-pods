#!/bin/sh
# Isolation tests in a full QEMU VM: systemd, SELinux, AppArmor and rootless runs on the given distribution.
# Needs only the QEMU package and /dev/kvm. Everything else stays in .local/vm, nothing is installed.
#   tests/vm.sh [fedora|debian|ubuntu|archlinux…]   Fedora without an argument, Ubuntu is LTS 26.04
#   tests/vm.sh clean                               remove VMs and downloaded images
#   PODS_VM_SERVER=1 tests/vm.sh …                  also the server role and its systemd unit
# The VM is deleted after the test, the downloaded image stays for the next run.
set -eu
cd "$(dirname "$(readlink -f "$0")")/.."
VM=$PWD/.local/vm
SSH_PORT=20222
SEED_PORT=20280

if [ "${1:-}" = clean ]; then
  rm -rf "$VM"
  echo "VMs and their images removed."
  exit 0
fi
for tool in qemu-system-x86_64 qemu-img python3 ssh ssh-keygen; do
  command -v "$tool" >/dev/null || { echo "$tool is missing." >&2; exit 1; }
done
[ -w /dev/kvm ] || { echo "No access to /dev/kvm." >&2; exit 1; }

image_url() {
  case "$1" in
    fedora)
      dir=https://download.fedoraproject.org/pub/fedora/linux/releases/45/Cloud/x86_64/images/
      file=$(curl -fsSL "$dir" | grep -o 'Fedora-Cloud-Base-Generic-[^"]*\.qcow2' | head -n 1)
      echo "$dir$file" ;;
    debian) echo https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2 ;;
    ubuntu) echo https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img ;;
    archlinux) echo https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2 ;;
    *) echo "Unknown distribution $1." >&2; return 1 ;;
  esac
}

inner='
set -eux
cd repo
cmd=$(sh orca-server.sh packages)
. /etc/os-release
echo "$PRETTY_NAME, SELinux: $(getenforce 2>/dev/null || echo no)"
case "$ID" in
  # A new kernel would drop the modules of the running one, the bridge needs them.
  arch) sudo pacman -Syu --noconfirm --ignore linux >/dev/null; eval "$cmd --noconfirm python" >/dev/null ;;
  fedora) eval "$cmd python3 -y" ;;
  *) sudo apt-get -qq update; eval "$cmd python3 -y" ;;
esac
grep -q "^$(id -un):" /etc/subuid ||
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$(id -un)"
# The user manager started before the packages, it has to pick up the session bus.
sudo systemctl restart "user@$(id -u).service"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
if [ -n "${PODS_VM_SERVER:-}" ]; then
  df -h / | tail -n 1
  sh tests/vm-server.sh || {
    df -h / | tail -n 1
    sudo dmesg | grep -i "apparmor.*denied" | tail -n 12 || true
    sudo aa-status 2>/dev/null | grep -E "pasta|passt|podman|crun|runc" || true
    exit 1
  }
else
  ./dev.sh build
  ./dev.sh test
fi
'

vm_ssh() {
  ssh -i "$dir/key" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=5 pods@127.0.0.1 "$@"
}

stop_vm() {
  for pid in $qemu $seed; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  du -sh "$dir" "$VM/images" 2>/dev/null || true
  rm -rf "$dir"
}

run_vm() {
  distro=$1
  qemu=""; seed=""
  trap stop_vm EXIT
  trap 'exit 130' INT TERM
  dir=$VM/run-$distro
  base=$VM/images/$distro.qcow2
  mkdir -p "$VM/images"
  if [ ! -f "$base" ]; then
    url=$(image_url "$distro")
    curl -fL --retry 3 -o "$base.part" "$url"
    mv "$base.part" "$base"
  fi
  rm -rf "$dir"
  mkdir -p "$dir/seed"
  ssh-keygen -q -t ed25519 -N '' -f "$dir/key"
  echo "instance-id: pods-$distro" >"$dir/seed/meta-data"
  cat >"$dir/seed/user-data" <<CFG
#cloud-config
users:
  - name: pods
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys: ["$(cat "$dir/key.pub")"]
CFG
  python3 -m http.server --bind 127.0.0.1 --directory "$dir/seed" "$SEED_PORT" >/dev/null 2>&1 &
  seed=$!
  qemu-img create -q -f qcow2 -b "$base" -F qcow2 "$dir/disk.qcow2" 20G
  qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 4G -display none \
    -serial "file:$dir/console.log" \
    -drive "file=$dir/disk.qcow2,if=virtio" \
    -netdev "user,id=n,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=n \
    -smbios "type=1,serial=ds=nocloud;s=http://10.0.2.2:$SEED_PORT/" &
  qemu=$!

  try=0
  until vm_ssh true 2>/dev/null; do
    try=$((try + 1))
    if [ "$try" -gt 60 ]; then
      echo "The VM did not boot, end of the console:"; tail -n 20 "$dir/console.log"
      return 1
    fi
    sleep 5
  done
  vm_ssh 'cloud-init status --wait >/dev/null 2>&1 || true'
  # Only files git knows, client.env and .local must not get into the VM.
  git ls-files -z --cached --others --exclude-standard \
    | tar c --null -T - \
    | vm_ssh 'mkdir -p repo && tar x -C repo'
  { [ -z "${PODS_VM_SERVER:-}" ] || echo "export PODS_VM_SERVER=1"; printf '%s' "$inner"; } | vm_ssh bash -s
}

fails=0
[ "$#" -gt 0 ] || set -- fedora
for distro in "$@"; do
  echo "=== $distro"
  rc=0
  (run_vm "$distro") || rc=$?
  if [ "$rc" -eq 0 ]; then echo "OK    $distro"; else echo "FAIL  $distro"; fails=$((fails + 1)); fi
done
if [ "$fails" -ne 0 ]; then echo "RESULT VM: $fails failed"; exit 1; fi
echo "RESULT VM: all OK"
