#!/bin/sh
# Assemble the one-click installer zip, out/Bridgeplay-Installer.zip.
#
#   scripts/package-installer.sh
#
# Takes out/Bridgeplay.app (make app), the engine archives from this Mac's engine cache,
# Apple's Game Porting Toolkit from this Mac's support folder, and installer/ plus the
# licence files from the repository. Engine archives are checked against the pins in
# FreeEngine*.swift. Nothing else from the cache is shipped: Valve's packages and Steam
# itself are downloaded on the user's Mac from Valve. GPTK is never committed.
#
# Overridable: APP (default out/Bridgeplay.app), ENGINE_CACHE (default
# ~/Library/Caches/notproton), GPTK_DIR (default ~/Library/Application Support/notproton/gptk)

set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

APP=${APP:-$repo/out/Bridgeplay.app}
ENGINE_CACHE=${ENGINE_CACHE:-$HOME/Library/Caches/notproton}
GPTK_DIR=${GPTK_DIR:-$HOME/Library/Application Support/notproton/gptk}
stage_root=$repo/out/installer
stage=$stage_root/Bridgeplay
zip=$repo/out/Bridgeplay-Installer.zip
models=app/Sources/NotProtonApp/Model

die() {
	echo "==> $*" >&2
	exit 1
}

# pin_after FILE PATTERN KEY: the first `KEY: "value"` at or after the first line
# matching PATTERN in FILE.
pin_after() {
	awk -v pat="$2" -v key="$3" '
		!found && index($0, pat) { found = 1 }
		found && match($0, key ": \"[^\"]*\"") {
			v = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", v); sub(/"$/, "", v)
			print v; exit
		}' "$1"
}

# need_file PATH SHA256: PATH exists and matches its pin.
need_file() {
	[ -n "$2" ] || die "no pin found for $1 in $models"
	[ -f "$1" ] || die "missing $1 (install the engine in the app once so the cache holds it)"
	actual=$(shasum -a 256 "$1" | cut -d' ' -f1)
	[ "$actual" = "$2" ] || die "$1 does not match its pin ($actual, want $2)"
}

# --- the app ----------------------------------------------------------------------

[ -d "$APP" ] || die "missing $APP, run: make app"
codesign --verify --strict "$APP" || die "$APP fails codesign --verify"
for f in Assets.car Bridgeplay.icns LICENSE NOTICE; do
	[ -s "$APP/Contents/Resources/$f" ] || die "$APP has no Contents/Resources/$f, rebuild with: make app"
done

# --- engine archives, from the pins -----------------------------------------------

winecx_swift=$models/FreeEngineWinecx.swift
engine_swift=$models/FreeEngine.swift
current=$(sed -n 's/^ *static let current = \(v[0-9]*\)$/\1/p' "$winecx_swift")
[ -n "$current" ] || die "cannot find FreeEngineWinecx.current in $winecx_swift"
runtime=$(pin_after "$winecx_swift" "static let $current = WinecxRelease(" runtime)
winecx_archive=$(pin_after "$winecx_swift" "static let $current = WinecxRelease(" archive)
winecx_sha=$(pin_after "$winecx_swift" "static let $current = WinecxRelease(" sha256)
dxmt_archive=$(pin_after "$engine_swift" "static let dxmt = RendererRelease(" archive)
dxmt_sha=$(pin_after "$engine_swift" "static let dxmt = RendererRelease(" sha256)
dxvk_archive=$(pin_after "$engine_swift" "dxvk: BackendRelease(" archive)
dxvk_sha=$(pin_after "$engine_swift" "dxvk: BackendRelease(" sha256)
[ -n "$runtime" ] && [ -n "$winecx_archive" ] && [ -n "$dxmt_archive" ] && [ -n "$dxvk_archive" ] \
	|| die "cannot read the engine pins from $models"

winecx_rel=engines/winecx-$runtime/$winecx_archive
echo "==> checking engine archives in $ENGINE_CACHE against the pins"
need_file "$ENGINE_CACHE/$winecx_rel" "$winecx_sha"
need_file "$ENGINE_CACHE/engines/$dxmt_archive" "$dxmt_sha"
need_file "$ENGINE_CACHE/engines/$dxvk_archive" "$dxvk_sha"

# --- Game Porting Toolkit ---------------------------------------------------------

[ -d "$GPTK_DIR" ] || die "missing $GPTK_DIR (Game Porting Toolkit redist/lib, set up in the app first)"
[ -s "$GPTK_DIR/License.rtf" ] || die "missing $GPTK_DIR/License.rtf, Apple's licence must ship with GPTK"
[ -d "$GPTK_DIR/external/D3DMetal.framework" ] || die "missing $GPTK_DIR/external/D3DMetal.framework"
[ -d "$GPTK_DIR/wine" ] || die "missing $GPTK_DIR/wine"

# --- stage ------------------------------------------------------------------------

echo "==> staging $stage"
rm -rf "$stage_root" "$zip"
mkdir -p "$stage/cache/engines/winecx-$runtime"

ditto "$APP" "$stage/Bridgeplay.app"
cp installer/Install.command "installer/BACA DULU.txt" installer/README.txt "$stage/"
chmod 755 "$stage/Install.command"
cp LICENSE LICENSE.* NOTICE "$stage/"
cp "$GPTK_DIR/License.rtf" "$stage/GPTK-License.rtf"
rsync -a --exclude .DS_Store installer/config/ "$stage/config/"
rsync -a --exclude .DS_Store "$GPTK_DIR/" "$stage/gptk/"
cp "$ENGINE_CACHE/$winecx_rel" "$stage/cache/$winecx_rel"
cp "$ENGINE_CACHE/engines/$dxmt_archive" "$ENGINE_CACHE/engines/$dxvk_archive" "$stage/cache/engines/"

# Valve's software is downloaded from Valve on the user's Mac, never shipped.
unwanted=$(find "$stage" \( -name valve-packages -o -name 'steam.dmg' -o -name 'Steam.app' \
	-o -name '*.p12' -o -name '*.pem' -o -name '*.key' -o -name '.env*' \) -print)
[ -z "$unwanted" ] || die "refusing to ship: $unwanted"

# --- zip --------------------------------------------------------------------------

echo "==> writing $zip"
ditto -c -k --keepParent "$stage" "$zip"

echo "==> contents"
(cd "$stage_root" && find Bridgeplay -maxdepth 3 ! -path 'Bridgeplay/Bridgeplay.app/*' \
	! -path 'Bridgeplay/gptk/*/*' | sort | sed 's/^/    /')
echo "==> sizes"
(cd "$stage" && du -sh -- * | sed 's/^/    /')
echo "==> $zip $(du -h "$zip" | cut -f1) ($(stat -f %z "$zip") bytes)"
