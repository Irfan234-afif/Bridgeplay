#!/bin/bash
# Builds libnp_gamepad.dylib (universal arm64 + x86_64: most native games run under
# Rosetta) into native-shim/out/ and ad-hoc signs it.
# Env: NP_MIN_MACOS sets -mmacosx-version-min (default: the compiler's default).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/out"
obj="$out/obj"
lib="$out/libnp_gamepad.dylib"
arches=(-arch arm64 -arch x86_64)
cflags=(-O2 -Wall -Werror -I"$here" "${arches[@]}")
[ -n "${NP_MIN_MACOS:-}" ] && cflags+=(-mmacosx-version-min="$NP_MIN_MACOS")

mkdir -p "$obj"
rm -f "$obj"/*.o

objects=()
compile() {   # source, extra flags...
    local src="$1"; shift
    local o="$obj/$(basename "${src%.*}").o"
    if ! clang "${cflags[@]}" "$@" -c "$here/$src" -o "$o"; then
        echo "build.sh: FAILED compiling $src" >&2
        exit 1
    fi
    objects+=("$o")
}

for src in gamepad_shim.c hid_profile.c; do
    if [ ! -f "$here/$src" ]; then
        echo "build.sh: FAILED: $src is missing" >&2
        exit 1
    fi
done

compile gamepad_shim.c
compile hid_profile.c
if [ -f "$here/gc_virtual.m" ]; then
    compile gc_virtual.m -fobjc-arc
else
    echo "build.sh: warning: gc_virtual.m not found, building without the GameController path" >&2
fi

if ! clang -dynamiclib "${cflags[@]}" -o "$lib" "${objects[@]}" \
        -framework IOKit -framework CoreFoundation -framework Foundation \
        -framework GameController; then
    echo "build.sh: FAILED linking $lib (undefined np_* symbols mean hid_profile.c or gc_virtual.m is incomplete)" >&2
    exit 1
fi
codesign -s - -f "$lib"
echo "build.sh: built $lib ($(lipo -archs "$lib"))"
