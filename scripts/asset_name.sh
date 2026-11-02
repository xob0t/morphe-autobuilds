#!/usr/bin/env bash

# Public APK asset name: <app>-<versionName>-p<patchesVersion>-morphe.apk.
# The patch bundle version is part of the name so a patch-only rebuild of the
# same upstream version gets a new name, which is what update checkers such as
# Obtainium key on. build.sh and manifest.sh must agree, so both use this.
apk_asset_name() {
  local app=${1-} version=${2-} patches=${3-}
  patches=${patches#v}
  if [ -z "$app" ] || [ -z "$version" ] || [ -z "$patches" ]; then
    echo "apk_asset_name: app, version and patches version are required" >&2
    return 1
  fi
  printf '%s-%s-p%s-morphe.apk\n' "$app" "$version" "$patches"
}
