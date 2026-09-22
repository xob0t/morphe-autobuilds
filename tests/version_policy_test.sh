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

echo "version policy tests passed"
