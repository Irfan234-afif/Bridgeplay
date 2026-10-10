#!/bin/sh
# Build NotProton from this checkout and publish it as this fork's latest GitHub release,
# which is what the app's "Check for Updates…" (Sparkle, SUFeedURL in app/Info.plist)
# reads.
#
#   scripts/release-local.sh "release notes"
#
# The update is signed with the EdDSA key in this Mac's login keychain, created once with
# app/.build/artifacts/sparkle/Sparkle/bin/generate_keys; app/Info.plist's SUPublicEDKey
# must be its public half. The version comes from dylib/version.h and must not have been
# released yet. HEAD must already be pushed to origin/main.

set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

notes=${1:-}
[ -n "$notes" ] || { sed -n '6p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

die() { echo "==> $*" >&2; exit 1; }

[ -z "$(git status --porcelain --untracked-files=no)" ] || die "the tree has uncommitted changes"
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "HEAD is not origin/main; push first"

slug=$(git remote get-url origin | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')
version=$(sed -n 's/^#define NOTPROTON_VERSION "\(.*\)"/\1/p' dylib/version.h)
if gh release view "v$version" -R "$slug" >/dev/null 2>&1; then
	die "v$version is already released; bump dylib/version.h (scripts/sync-upstream.sh does)"
fi

sparkle=app/.build/artifacts/sparkle/Sparkle/bin
key=$("$sparkle/generate_keys" -p 2>/dev/null) || die "no Sparkle key in the keychain; run $sparkle/generate_keys"
[ "$key" = "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' app/Info.plist)" ] \
	|| die "app/Info.plist SUPublicEDKey is not this keychain's Sparkle key"

if [ -z "${CX_ROOT:-}" ]; then
	CX_ROOT="$HOME/Library/Application Support/notproton/runners/crossover-winehq-11.15/CrossOver"
	export CX_ROOT
fi
scripts/build-local.sh --checks

built=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/NotProton.app/Contents/Info.plist)
[ "$built" = "$version" ] || die "built $built, expected $version"

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp build/NotProton.zip "$out/NotProton.zip"
printf '%s\n' "$notes" >"$out/NotProton.txt"
"$sparkle/generate_appcast" \
	--download-url-prefix "https://github.com/$slug/releases/download/v$version/" \
	--embed-release-notes "$out"

gh release create "v$version" "$out/NotProton.zip" "$out/appcast.xml" -R "$slug" \
	--target "$(git rev-parse HEAD)" --title "$version" --notes "$notes" --latest
echo "==> released v$version: https://github.com/$slug/releases/tag/v$version"
