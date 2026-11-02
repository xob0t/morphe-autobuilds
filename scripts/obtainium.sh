#!/usr/bin/env bash
#
# Obtainium (https://obtainium.imranr.dev) one-tap import links, one per app.
#
# All apps share one rolling release whose tag never changes, so Obtainium's
# GitHub source cannot tell builds apart. The links use its HTML source on the
# release's asset list instead: the link filter picks this app's APK, and the
# version is read from the file name (<versionName>-p<patchesVersion>), so a
# patch-only rebuild of the same upstream version still shows as an update.
# OS version detection is off because that string never equals versionName.
#
# Sourced by manifest.sh for the release notes. Run directly to print the
# README table:  bash scripts/obtainium.sh [config] [owner/repo]

# Prints the Obtainium app JSON for one app.
obtainium_app_json() {
  local repo=$1 tag=$2 id=$3 name=$4 package=$5
  if ! [[ "$id" =~ ^[a-z0-9]+$ ]]; then
    # A hyphen would make "<id>-" a prefix of another app's asset names.
    echo "obtainium: app id '$id' must match ^[a-z0-9]+$" >&2
    return 1
  fi
  jq -cn \
    --arg repo "$repo" --arg tag "$tag" --arg id "$id" \
    --arg name "$name" --arg package "$package" '
    {
      id: $package,
      url: "https://github.com/\($repo)/releases/expanded_assets/\($tag)",
      author: ($repo | split("/")[0]),
      name: "\($name) (Morphe)",
      preferredApkIndex: 0,
      additionalSettings: ({
        customLinkFilterRegex: "/\($id)-[^/]+-morphe\\.apk$",
        versionExtractionRegEx: "/\($id)-([^/]+)-morphe\\.apk$",
        matchGroupToUse: "1",
        versionDetection: false
      } | tojson),
      overrideSource: "HTML"
    }'
}

# Prints a clickable https link that opens the import in Obtainium. The JSON is
# encoded once for the obtainium:// URL and again for the redirect's query.
obtainium_link() {
  local json
  json=$(obtainium_app_json "$@") || return 1
  jq -rn --arg json "$json" \
    '"https://apps.obtainium.imranr.dev/redirect?r=" + ("obtainium://app/" + ($json | @uri) | @uri)'
}

# Prints "<id>\t<link>" for every app in the config. An app whose link cannot
# be built is skipped with a warning; it must never block publishing.
obtainium_links() {
  local config=$1 repo=$2 tag id name package link
  tag=$(jq -er '.release_tag' "$config")
  while IFS=$'\t' read -r id name package; do
    if link=$(obtainium_link "$repo" "$tag" "$id" "$name" "$package"); then
      printf '%s\t%s\n' "$id" "$link"
    else
      echo "::warning::No Obtainium link for app '$id'." >&2
    fi
  done < <(jq -r '.apps[] | [.id, .name, .package] | @tsv' "$config")
}

# Prints the README table.
obtainium_table() {
  local config=$1 repo=$2 id link name
  echo "| App | Obtainium |"
  echo "|-----|-----------|"
  while IFS=$'\t' read -r id link; do
    name=$(jq -r --arg id "$id" '.apps[] | select(.id == $id) | .name' "$config")
    printf '| %s | [Add to Obtainium](%s) |\n' "$name" "$link"
  done < <(obtainium_links "$config" "$repo")
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  obtainium_table "${1:-$ROOT/config/apps.json}" "${2:-xob0t/morphe-autobuilds}"
fi
