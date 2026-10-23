#!/usr/bin/env bash
# np-test-batch.sh <appid...> - run np-test-game.sh sequentially with --stop; prints a summary.
# Extra args via NP_TEST_ARGS, e.g. NP_TEST_ARGS="--seconds 60 --backend dxvk".
set -u
[ $# -gt 0 ] || { echo "usage: $0 <appid...>" >&2; exit 64; }
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2206
EXTRA=(${NP_TEST_ARGS:-})
for id in "$@"; do
  out="$("$DIR/np-test-game.sh" "$id" ${EXTRA[@]+"${EXTRA[@]}"} --stop)"
  printf '%s\n' "$out" | jq -r '"\(.appid)\t\(.name)\t\(.backend)\t\(.verdict)\t\(.seconds_alive)s"'
  sleep 5
done
