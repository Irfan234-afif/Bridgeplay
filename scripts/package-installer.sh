#!/bin/sh
# Assemble the one-click installer zip, out/Bridgeplay-Installer.zip.
#
#   scripts/package-installer.sh [--fingerprint-only]
#
# The installer carries no app: Install.command downloads the latest Bridgeplay.zip from
# the GitHub releases, so the zip only changes with the engines, GPTK, the configs or the
# installer itself, and release-local.sh uploads it only then. --fingerprint-only runs
# every check and prints that fingerprint without writing the zip.
#
# Takes the engine archives from this Mac's engine cache,
# Apple's Game Porting Toolkit from this Mac's support folder, and installer/ plus the
# licence files from the repository. Engine archives are checked against the pins in
# FreeEngine*.swift. Nothing else from the cache is shipped: Valve's packages and Steam
# itself are downloaded on the user's Mac from Valve. GPTK is never committed.
#
# Overridable: ENGINE_CACHE (default
# ~/Library/Caches/bridgeplay), GPTK_DIR (default ~/Library/Application Support/bridgeplay/gptk).
# On a Mac the app has not migrated to 3.0.0 yet, the defaults fall back to the old
# notproton folders when the bridgeplay ones are missing.

set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

fingerprint_only=0
[ "${1:-}" = "--fingerprint-only" ] && fingerprint_only=1
if [ -z "${ENGINE_CACHE:-}" ]; then
	ENGINE_CACHE=$HOME/Library/Caches/bridgeplay
	[ -d "$ENGINE_CACHE" ] || [ ! -d "$HOME/Library/Caches/notproton" ] || ENGINE_CACHE=$HOME/Library/Caches/notproton
fi
if [ -z "${GPTK_DIR:-}" ]; then
	GPTK_DIR="$HOME/Library/Application Support/bridgeplay/gptk"
	legacy_gptk="$HOME/Library/Application Support/notproton/gptk"
	[ -d "$GPTK_DIR" ] || [ ! -d "$legacy_gptk" ] || GPTK_DIR=$legacy_gptk
fi
stage_root=$repo/out/installer
stage=$stage_root/Bridgeplay
zip=$repo/out/Bridgeplay-Installer.zip
models=app/Sources/BridgeplayApp/Model

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

# GPTK is Apple's: every Mach-O file in it must carry Apple's own signature (anchor apple),
# so a modified or swapped copy in the support folder is never shipped. The Windows DLLs
# under wine/ are PE files that codesign cannot check.
gptk_apple_signed() {
	codesign --verify --strict --deep -R='anchor apple' "$1" 2>/dev/null \
		|| die "$1 is not signed by Apple (codesign -R 'anchor apple'), refusing to ship it"
}
echo "==> checking Apple's signature on GPTK"
gptk_apple_signed "$GPTK_DIR/external/D3DMetal.framework"
gptk_list=$(mktemp)
trap 'rm -f "$gptk_list"' EXIT
find "$GPTK_DIR" -type f ! -path '*/D3DMetal.framework/*' >"$gptk_list"
gptk_macho=0
while IFS= read -r f; do
	case "$(file -b "$f")" in
		Mach-O*) gptk_apple_signed "$f"; gptk_macho=$((gptk_macho + 1)) ;;
	esac
done <"$gptk_list"
[ "$gptk_macho" -gt 0 ] || die "no Mach-O files in $GPTK_DIR besides D3DMetal.framework (libd3dshared.dylib missing?)"

# --- gamefixes --------------------------------------------------------------------

# Per-game confs come from gamefixes/, the same files the app ships into
# gamefixes-default/, so the installer can never carry a divergent copy. default.conf (the
# global file in the user's gamefixes/) is installer-only and lives in installer/config/.
ls gamefixes/*.conf >/dev/null 2>&1 || die "no gamefixes/*.conf in the repository"
[ -s installer/config/gamefixes/default.conf ] || die "missing installer/config/gamefixes/default.conf"

# --- stage ------------------------------------------------------------------------

echo "==> staging $stage"
rm -rf "$stage_root" "$zip"
mkdir -p "$stage/cache/engines/winecx-$runtime"

cp installer/Install.command "installer/BACA DULU.txt" installer/README.txt "$stage/"
chmod 755 "$stage/Install.command"
cp LICENSE LICENSE.* NOTICE "$stage/"
# DXMT (LGPL-2.1, plus its pre-0.80 licence) and DXVK (zlib) ship in cache/engines/, so
# their licence texts ship too, taken from upstream at the pinned commits (installer/licenses/).
cp installer/licenses/* "$stage/"
cp "$GPTK_DIR/License.rtf" "$stage/GPTK-License.rtf"
rsync -a --exclude .DS_Store installer/config/ "$stage/config/"
mkdir -p "$stage/config/gamefixes-default"
cp gamefixes/*.conf "$stage/config/gamefixes-default/"
rsync -a --exclude .DS_Store "$GPTK_DIR/" "$stage/gptk/"
cp "$ENGINE_CACHE/$winecx_rel" "$stage/cache/$winecx_rel"
# The runtime bundles third-party libraries without their licence files, so the installer
# names every one of them; NOTICE says which licences they fall under.
# CEILING: lists files, not each library's own copyright notice — generate those from the
# Homebrew formulae the runtime was built from, or get winecx-gptk to ship them upstream.
{
	echo "Libraries bundled in the WineCX runtime ($winecx_rel)."
	echo "Licences and the written offer for source code: see NOTICE."
	echo
	tar -tzf "$stage/cache/$winecx_rel" | grep -E '\.(dylib|so)$' | sed 's#.*/##' | sort -u
} >"$stage/WINECX-RUNTIME-LIBRARIES.txt" || die "could not list the WineCX runtime's libraries"
cp "$ENGINE_CACHE/engines/$dxmt_archive" "$ENGINE_CACHE/engines/$dxvk_archive" "$stage/cache/engines/"

# Valve's software is downloaded from Valve on the user's Mac, never shipped.
unwanted=$(find "$stage" \( -name valve-packages -o -name 'steam.dmg' -o -name 'Steam.app' \
	-o -name '*.p12' -o -name '*.pem' -o -name '*.key' -o -name '.env*' \) -print)
[ -z "$unwanted" ] || die "refusing to ship: $unwanted"

# Every staged file's path and content, so the fingerprint moves when anything shipped does.
fingerprint=$(cd "$stage" && find . -type f ! -name .DS_Store -print0 | LC_ALL=C sort -z \
	| xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
if [ "$fingerprint_only" -eq 1 ]; then
	rm -rf "$stage_root"
	echo "$fingerprint"
	exit 0
fi
printf '%s\n' "$fingerprint" >"$repo/out/Bridgeplay-Installer.fingerprint"

# --- zip --------------------------------------------------------------------------

echo "==> writing $zip"
# --norsrc --noextattr: no AppleDouble ._ files in the zip.
ditto -c -k --norsrc --noextattr --keepParent "$stage" "$zip"

echo "==> contents"
(cd "$stage_root" && find Bridgeplay -maxdepth 3 ! -path 'Bridgeplay/gptk/*/*' | sort | sed 's/^/    /')
echo "==> sizes"
(cd "$stage" && du -sh -- * | sed 's/^/    /')
echo "==> $zip $(du -h "$zip" | cut -f1) ($(stat -f %z "$zip") bytes)"

# The zip is the deliverable.
rm -rf "$stage_root"
echo "==> fingerprint $fingerprint"
