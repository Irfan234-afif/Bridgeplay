#!/bin/sh
# Merge new work from the projects this fork follows, keeping every local patch.
#
#   scripts/sync-upstream.sh            merge, then print what came in
#   scripts/sync-upstream.sh --check    only report whether anything new is upstream
#
# Sources, in order: leonseemann/NotProton-WineHQ (remote fork-src) and
# NotProtonNot/NotProton (remote upstream). Each is merged with a merge commit, never
# rebased or taken with -X theirs, so local commits stay as they are. The only conflict
# resolved automatically is dylib/version.h: the result is upstream's base version with
# this fork's "-winehq.N-ray.M" suffix, M bumped so Sparkle sees a newer build. Any
# other conflict aborts that merge and leaves the tree untouched.

set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

check_only=0
case "${1:-}" in
	--check) check_only=1 ;;
	"") ;;
	*) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

ensure_remote() {
	url=$(git remote get-url "$1" 2>/dev/null || true)
	[ -n "$url" ] || git remote add "$1" "$2"
}
ensure_remote fork-src https://github.com/leonseemann/NotProton-WineHQ
ensure_remote upstream https://github.com/NotProtonNot/NotProton

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	echo "==> the tree has uncommitted changes, commit them first" >&2
	exit 1
fi

git fetch -q fork-src
git fetch -q upstream

version_of() {
	sed -n 's/^#define NOTPROTON_VERSION "\(.*\)"/\1/p'
}

pending=""
for ref in fork-src/main upstream/main; do
	count=$(git rev-list --count "HEAD..$ref")
	[ "$count" -eq 0 ] || pending="$pending $ref:$count"
done

if [ -z "$pending" ]; then
	echo "==> up to date with fork-src/main and upstream/main"
	exit 0
fi
echo "==> new upstream commits:$pending"
[ "$check_only" -eq 0 ] || exit 2

ours_before=$(version_of <dylib/version.h)
for entry in $pending; do
	ref=${entry%%:*}
	echo "==> merging $ref"
	if git merge --no-ff --no-edit "$ref" >/dev/null 2>&1; then
		continue
	fi
	conflicts=$(git diff --name-only --diff-filter=U)
	if [ "$conflicts" != "dylib/version.h" ]; then
		git merge --abort
		echo "==> $ref conflicts with local patches in:" >&2
		# shellcheck disable=SC2086 # one path per line
		printf '    %s\n' $conflicts >&2
		echo "    nothing was merged from $ref; resolve it by hand" >&2
		exit 1
	fi
	theirs=$(git show "$ref:dylib/version.h" | version_of)
	base=${theirs%%-*}
	suffix=${ours_before#*-}
	ray=${suffix##*-ray.}
	next="$base-${suffix%-ray.*}-ray.$((ray + 1))"
	printf '%s\n' "// Build version string" "#ifndef NOTPROTON_VERSION_H" "#define NOTPROTON_VERSION_H" "" \
		"#define NOTPROTON_VERSION \"$next\"" "" "#endif // NOTPROTON_VERSION_H" >dylib/version.h
	git add dylib/version.h
	git commit -q --no-edit
	echo "==> version $ours_before -> $next"
done

ours_after=$(version_of <dylib/version.h)
if [ "$ours_after" = "$ours_before" ]; then
	# The merges were clean but a release still needs a newer version than the last one.
	suffix=${ours_before#*-}
	ray=${suffix##*-ray.}
	next="${ours_before%-ray.*}-ray.$((ray + 1))"
	sed -i '' "s/^#define NOTPROTON_VERSION \".*\"/#define NOTPROTON_VERSION \"$next\"/" dylib/version.h
	git commit -q -m "chore: bump version to $next after upstream merge" dylib/version.h
	echo "==> version $ours_before -> $next"
fi

echo "==> merged. Build and test, then publish with scripts/release-local.sh"
