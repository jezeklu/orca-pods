#!/bin/sh
# On the host, after reviewing the code of a tag: signs the release CI drafted for it and publishes it.
# The key never leaves the host, so neither CI nor a container can release code to the hosts.
#   git checkout v1.2.3 && ./sign-release.sh ~/.ssh/id_ed25519
set -eu
cd "$(dirname "$(readlink -f "$0")")"
[ "$#" -eq 1 ] || { echo "Usage: $0 path/to/private/key" >&2; exit 1; }
tag=$(git describe --tags --exact-match 2>/dev/null) || { echo "Check out the release tag first." >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "The checkout has uncommitted changes." >&2; exit 1; }

PODS_VERSION=$tag ./build.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh release download "$tag" -p op-client -p op-server -D "$work"
# What gets signed is the reviewed checkout, the files from CI only have to be the same.
for name in op-client op-server; do
  cmp -s "dist/$name" "$work/$name" || { echo "$name of release $tag differs from this checkout, nothing signed." >&2; exit 1; }
  rm -f "dist/$name.sig"
  ssh-keygen -q -Y sign -f "$1" -n orca-pods "dist/$name"
done
gh release upload "$tag" dist/op-client.sig dist/op-server.sig --clobber
gh release edit "$tag" --draft=false --latest
echo "Release $tag signed and published. Its images are built and pushed now."
