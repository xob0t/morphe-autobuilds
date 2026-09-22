#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../scripts/version_policy.sh
source "$ROOT/scripts/version_policy.sh"

assert_action() {
  local expected=$1
  shift
  local actual
  actual=$(version_action "$@")
  if [ "$actual" != "$expected" ]; then
    printf 'expected %s, got %s for candidate=%s published=%s rebuild=%s\n' \
      "$expected" "$actual" "$1" "$2" "$3" >&2
    exit 1
  fi
}

assert_action reject-rollback 99 100 false
assert_action reject-rollback 99 100 true
assert_action skip-unchanged 100 100 false
assert_action build 100 100 true
assert_action build 101 100 false
assert_action build 101 100 true
assert_action build 000101 000100 false

assert_invalid() {
  local description=$1
  shift
  if version_action "$@" >/dev/null 2>&1; then
    printf 'expected invalid input for %s\n' "$description" >&2
    exit 1
  fi
}

assert_invalid decimal-candidate 1.5 1 false
assert_invalid decimal-published 1 1.5 false
assert_invalid oversized-candidate 9223372036854775808 1 false
assert_invalid oversized-published 1 9223372036854775808 false

echo "version policy tests passed"
