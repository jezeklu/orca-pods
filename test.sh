#!/bin/sh
# All local tests, no GitHub Actions needed. Run only code you have reviewed.
#   ./test.sh            unit tests, distributions in containers, isolation tests on this machine
#   ./test.sh unit       unit tests only, also run in a container without Podman
#   ./test.sh vm [distro…]  isolation tests in a VM, Fedora without an argument; needs QEMU
#   ./test.sh clean      remove test images and VMs, leave other images alone
# Downloaded images stay for the next run. Fresh ones are pulled after ./test.sh clean.
set -eu
cd "$(dirname "$(readlink -f "$0")")"
case "${1:-}" in
  unit) tests/unit.sh ;;
  vm) shift; tests/vm.sh "$@" ;;
  clean) tests/distro.sh clean; tests/vm.sh clean; ./dev.sh clean ;;
  "") tests/unit.sh; tests/distro.sh; ./dev.sh build; ./dev.sh test ;;
  *) echo "Usage: $0 [unit|vm [distro…]|clean]" >&2; exit 1 ;;
esac
