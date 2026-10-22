#!/bin/sh
# The verdict of the app workflow's "app gate" job, the one check a branch rule requires.
# Green only when the heavy jobs all succeeded, or all were skipped because the change
# is docs-only. Failed, cancelled and any other skip are red: a required check that is
# skipped counts as passing, so a skipped build must never be read as one.
#   SCOPE_RESULT   needs.scope.result
#   DOCS_ONLY      needs.scope.outputs.docs_only
#   BUILD_RESULT   needs.build.result
#   CHECKS_RESULT  needs.checks.result
#   TESTS_RESULT   needs.tests.result
fail() {
	echo "app gate: $*" >&2
	exit 1
}

[ "${SCOPE_RESULT:-}" = success ] || fail "the change scope job ended ${SCOPE_RESULT:-with no result}"
case ${DOCS_ONLY:-} in
true) want=skipped ;;
false) want=success ;;
*) fail "docs_only is '${DOCS_ONLY:-}', not true or false" ;;
esac
[ "${BUILD_RESULT:-}" = "$want" ] || fail "full app build ended ${BUILD_RESULT:-with no result}, expected $want"
[ "${CHECKS_RESULT:-}" = "$want" ] || fail "source checks ended ${CHECKS_RESULT:-with no result}, expected $want"
[ "${TESTS_RESULT:-}" = "$want" ] || fail "swift tests ended ${TESTS_RESULT:-with no result}, expected $want"

if [ "$want" = skipped ]; then
	echo "app gate: docs-only change, build, checks and tests skipped"
else
	echo "app gate: full app build, source checks and swift tests passed"
fi
