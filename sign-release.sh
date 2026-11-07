#!/bin/sh
# On the host, after reviewing the code: builds orca-server and signs it with a key the container never sees.
#   ./sign-release.sh ~/.ssh/id_ed25519     produces dist/orca-server and dist/orca-server.sig
set -eu
cd "$(dirname "$(readlink -f "$0")")"
[ "$#" -eq 1 ] || { echo "Usage: $0 path/to/private/key" >&2; exit 1; }
./build.sh
rm -f dist/orca-server.sig
ssh-keygen -q -Y sign -f "$1" -n orca-pods dist/orca-server
echo "Signed. Put the public key into ~/.config/orca-pods/allowed_signers as: orca-pods <key>"
