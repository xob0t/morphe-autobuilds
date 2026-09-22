#!/usr/bin/env bash

# Decide whether a resolved app version may replace the published version.
# A patch refresh may rebuild the same version, but it must never move the
# rolling release backwards when a staged rollout returns an older APK.
normalize_version_code() {
  local LC_ALL=C
  local value=${1-}
  local max=9223372036854775807

  [[ "$value" =~ ^[0-9]+$ ]] || return 1

  while [ "${#value}" -gt 1 ] && [ "${value:0:1}" = "0" ]; do
    value=${value:1}
  done

  if [ "${#value}" -gt "${#max}" ] ||
    { [ "${#value}" -eq "${#max}" ] && [[ "$value" > "$max" ]]; }; then
    return 1
  fi

  printf '%s\n' "$value"
}

version_action() {
  local candidate_raw=${1-}
  local published_raw=${2-}
  local rebuild=${3:?rebuild flag required}
  local candidate published

  if ! candidate=$(normalize_version_code "$candidate_raw"); then
    printf 'version_action: invalid candidate versionCode: %q\n' "$candidate_raw" >&2
    return 1
  fi

  if ! published=$(normalize_version_code "$published_raw"); then
    printf 'version_action: invalid published versionCode: %q\n' "$published_raw" >&2
    return 1
  fi

  if (( candidate < published )); then
    printf '%s\n' reject-rollback
  elif [ "$rebuild" != "true" ] && (( candidate <= published )); then
    printf '%s\n' skip-unchanged
  else
    printf '%s\n' build
  fi
}
