#!/usr/bin/env bash
# Commit compat/reported.json onto $TARGET_BRANCH when its games list changed, and push
# it there. Run by .github/workflows/compat-reported.yml after scripts/compat-reported.py
# has rewritten the file, from a checkout of $TARGET_BRANCH. It pushes that one branch and
# never forces, so a rejected push (another push got in first) fails the run.
set -euo pipefail

branch="${TARGET_BRANCH:-main}"
remote="${REMOTE:-origin}"
file=compat/reported.json
tip="refs/remotes/$remote/$branch"

fail() {
	echo "::error::compat-reported: $*" >&2
	exit 1
}

# A checkout of the default branch would commit the file on top of unreleased code.
[ "$(git symbolic-ref -q --short HEAD || true)" = "$branch" ] \
	|| fail "the checkout is not on $branch, refusing to commit"
[ "$(git rev-parse HEAD)" = "$(git rev-parse --verify -q "$tip" || true)" ] \
	|| fail "HEAD is not the tip of $remote/$branch, refusing to commit"

# "fetched" changes every run; only a different games list is worth a commit.
old=$(git show "$tip:$file")
rc=0
printf '%s' "$old" | python3 -c '
import json, sys
old = json.load(sys.stdin)["games"]
new = json.load(open(sys.argv[1]))["games"]
sys.exit(0 if old == new else 10)' "$file" || rc=$?
case "$rc" in
	0) echo "no change in the game list"; exit 0 ;;
	10) ;;
	*) fail "could not compare the game lists (exit $rc)" ;;
esac

git add -- "$file"
git -c user.name="github-actions[bot]" \
	-c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
	commit -q -m "chore(compat): refresh AppleGamingWiki ratings" -- "$file"

# One explicit refspec, no tags, no force.
git -c push.followTags=false push -q "$remote" "HEAD:refs/heads/$branch" \
	|| fail "the push to $branch was rejected; another push probably landed first. Nothing else was pushed, run the workflow again"
