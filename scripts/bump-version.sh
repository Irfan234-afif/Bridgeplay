#!/bin/sh
# Bump Bridgeplay's version in dylib/version.h before a release.
#
#   scripts/bump-version.sh patch|minor|major [--upstream "NotProton X.Y.Z"]
#
# patch for fixes, minor for an upstream NotProton merge or new features, major for a
# break. BRIDGEPLAY_BUILD goes up by one every time, since Sparkle orders updates by it.
# --upstream records the NotProton release this build is based on (NOTPROTON_VERSION);
# a clean upstream merge already brings upstream's value, so it is rarely needed.
# Edits the file only; commit it yourself. See docs/RELEASING.md.

set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
header=$repo/dylib/version.h

usage() {
	sed -n '4p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 1
}

part=${1:-}
case "$part" in
	patch|minor|major) shift ;;
	*) usage ;;
esac

upstream=""
while [ $# -gt 0 ]; do
	case "$1" in
		--upstream)
			[ $# -ge 2 ] || usage
			upstream=${2#NotProton }
			shift 2
			;;
		*) usage ;;
	esac
done

die() { echo "==> $*" >&2; exit 1; }

version=$(sed -n 's/^#define BRIDGEPLAY_VERSION "\(.*\)"$/\1/p' "$header")
build=$(sed -n 's/^#define BRIDGEPLAY_BUILD \([0-9][0-9]*\)$/\1/p' "$header")
based=$(sed -n 's/^#define NOTPROTON_VERSION "\(.*\)"$/\1/p' "$header")
echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "BRIDGEPLAY_VERSION '$version' in $header is not X.Y.Z"
[ -n "$build" ] || die "no numeric BRIDGEPLAY_BUILD in $header"
[ -n "$based" ] || die "no NOTPROTON_VERSION in $header"
if [ -n "$upstream" ]; then
	echo "$upstream" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || die "--upstream wants 'NotProton X.Y.Z', got '$upstream'"
fi

major=${version%%.*}
rest=${version#*.}
minor=${rest%%.*}
patch=${rest#*.}
case "$part" in
	major) major=$((major + 1)); minor=0; patch=0 ;;
	minor) minor=$((minor + 1)); patch=0 ;;
	patch) patch=$((patch + 1)) ;;
esac
next="$major.$minor.$patch"
next_build=$((build + 1))
next_based=${upstream:-$based}

sed -i '' \
	-e "s/^#define BRIDGEPLAY_VERSION \".*\"$/#define BRIDGEPLAY_VERSION \"$next\"/" \
	-e "s/^#define BRIDGEPLAY_BUILD [0-9][0-9]*$/#define BRIDGEPLAY_BUILD $next_build/" \
	-e "s/^#define NOTPROTON_VERSION \".*\"$/#define NOTPROTON_VERSION \"$next_based\"/" \
	"$header"

echo "==> Bridgeplay $version ($build) -> $next ($next_build), based on NotProton $next_based"
