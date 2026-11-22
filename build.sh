#!/bin/sh
# Builds the standalone files dist/op-client and dist/op-server.
set -eu
cd "$(dirname "$(readlink -f "$0")")"
mkdir -p dist
for script in op-*.sh; do
  out=dist/${script%.sh}
  # @include inlines lib/, @embed prints a file through a here-document. Both drop the next line.
  awk '/^# @include /{ f = "lib/" $3; while ((getline line < f) > 0) print line; close(f); getline; next }
    /^ *# @embed /{ print "  cat <<'\''EMBED'\''"; while ((getline line < $3) > 0) print line; close($3); print "EMBED"; getline; next }
    { print }' \
    "$script" >"$out"
  chmod +x "$out"
done
