#!/bin/sh
# Builds the standalone files dist/orca-client and dist/orca-server.
set -eu
cd "$(dirname "$(readlink -f "$0")")"
mkdir -p dist
for script in orca-*.sh; do
  out=dist/${script%.sh}
  awk '/^# @include /{ f = "lib/" $3; while ((getline line < f) > 0) print line; close(f); getline; next } { print }' \
    "$script" >"$out"
  chmod +x "$out"
done
