#!/usr/bin/env bash

# Decide whether a resolved app version may replace the published version.
# A patch refresh may rebuild the same version, but it must never move the
# rolling release backwards when a staged rollout returns an older APK.
version_action() {
  local candidate=${1:?candidate versionCode required}
  local published=${2:?published versionCode required}
  local rebuild=${3:?rebuild flag required}

  if (( candidate < published )); then
    printf '%s\n' reject-rollback
  elif [ "$rebuild" != "true" ] && (( candidate <= published )); then
    printf '%s\n' skip-unchanged
  else
    printf '%s\n' build
  fi
}
