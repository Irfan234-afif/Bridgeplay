#!/bin/sh
# Builds nvapi-shim/nvapi64.dll (x86_64 PE, no Wine builtin marker, so a prefix copy loads
# as native and is not swapped for the lib/wine builtin).
set -eu
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -O2 -shared -s -Wall -Wextra -Wno-unused-parameter \
  -Wl,--no-insert-timestamp -Wl,--build-id=none \
  -o nvapi64.dll nvapi_shim.c nvapi_shim.def
shasum -a 256 nvapi64.dll
