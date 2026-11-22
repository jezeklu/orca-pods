#!/bin/sh
# Builds the standalone files dist/op-client and dist/op-server.
set -eu
cd "$(dirname "$(readlink -f "$0")")"
# The same checkout must give the same bytes in CI and on the host, sign-release.sh compares them.
version=${PODS_VERSION:-$(git describe --tags --exact-match 2>/dev/null || echo dev)}
mkdir -p dist
for script in op-*.sh; do
  out=dist/${script%.sh}
  # @include inlines lib/, @embed prints a file through a here-document. Both drop the next line.
  awk -v version="$version" '/^# @include /{ f = "lib/" $3; while ((getline line < f) > 0) { if (line == "VERSION=dev") line = "VERSION=" version; print line }; close(f); getline; next }
    /^ *# @embed /{ print "  cat <<'\''EMBED'\''"; while ((getline line < $3) > 0) print line; close($3); print "EMBED"; getline; next }
    { print }' \
    "$script" >"$out"
  chmod +x "$out"
done
