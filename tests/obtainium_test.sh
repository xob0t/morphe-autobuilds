#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../scripts/asset_name.sh
source "$ROOT/scripts/asset_name.sh"
# shellcheck source=../scripts/obtainium.sh
source "$ROOT/scripts/obtainium.sh"

fail() { printf '%s\n' "$*" >&2; exit 1; }

# ---- asset names --------------------------------------------------------------
[ "$(apk_asset_name avito 236.1 1.12.0)" = "avito-236.1-p1.12.0-morphe.apk" ] \
  || fail "asset name with plain patches version"
[ "$(apk_asset_name avito 236.1 v1.12.0)" = "avito-236.1-p1.12.0-morphe.apk" ] \
  || fail "asset name strips a leading v from the patches version"
[ "$(apk_asset_name wildberries 7.8.6001-rustore 1.13.0-dev.2)" = \
  "wildberries-7.8.6001-rustore-p1.13.0-dev.2-morphe.apk" ] \
  || fail "asset name with hyphenated versions"
if apk_asset_name avito 236.1 "" >/dev/null 2>&1; then
  fail "asset name requires a patches version"
fi

# ---- Obtainium filter and version regexes ------------------------------------
# Mirrors Obtainium's HTML source: keep links matching customLinkFilterRegex,
# take the last, and read capture group 1 of versionExtractionRegEx.
settings() {
  obtainium_app_json owner/repo latest "$1" "$1" "pkg.$1" | jq -r '.additionalSettings'
}
assert_version() {
  local id=$1 file=$2 expected=$3 s filter extract actual
  s=$(settings "$id")
  filter=$(jq -r '.customLinkFilterRegex' <<<"$s")
  extract=$(jq -r '.versionExtractionRegEx' <<<"$s")
  local url="https://github.com/owner/repo/releases/download/latest/$file"
  [[ "$url" =~ $filter ]] || fail "$id filter does not match $file"
  [[ "$url" =~ $extract ]] || fail "$id version regex does not match $file"
  actual=${BASH_REMATCH[1]}
  [ "$actual" = "$expected" ] || fail "$id: expected version '$expected' from $file, got '$actual'"
}
assert_no_match() {
  local id=$1 file=$2 filter
  filter=$(settings "$id" | jq -r '.customLinkFilterRegex')
  if [[ "https://github.com/owner/repo/releases/download/latest/$file" =~ $filter ]]; then
    fail "$id filter unexpectedly matches $file"
  fi
}

assert_version avito "$(apk_asset_name avito 236.1 1.12.0)" "236.1-p1.12.0"
assert_version wildberries "$(apk_asset_name wildberries 7.8.6001-rustore 1.12.0)" \
  "7.8.6001-rustore-p1.12.0"
# Names published before the patches version was added still resolve.
assert_version avito avito-236.1-morphe.apk "236.1"
assert_no_match avito tbank-8.4.2-p1.12.0-morphe.apk
assert_no_match avito manifest.json
assert_no_match ozon backup-123-1-ozon-19.41.0-morphe.apk

# Patch-only rebuilds must change the version Obtainium sees.
a=$(apk_asset_name ozon 19.41.0 1.12.0)
b=$(apk_asset_name ozon 19.41.0 1.12.1)
[ "$a" != "$b" ] || fail "patch-only rebuild kept the same asset name"

# ---- link shape ---------------------------------------------------------------
json=$(obtainium_app_json owner/repo latest avito Avito com.avito.android)
jq -e '
  .id == "com.avito.android"
  and .url == "https://github.com/owner/repo/releases/expanded_assets/latest"
  and .overrideSource == "HTML"
  and (.additionalSettings | fromjson | .versionDetection == false and .matchGroupToUse == "1")
' <<<"$json" >/dev/null || fail "unexpected Obtainium app JSON: $json"

link=$(obtainium_link owner/repo latest avito Avito com.avito.android)
prefix="https://apps.obtainium.imranr.dev/redirect?r="
[[ "$link" == "$prefix"* ]] || fail "unexpected link prefix: $link"
decoded=$(python3 -c '
import sys, urllib.parse
outer = urllib.parse.unquote(sys.argv[1])
assert outer.startswith("obtainium://app/"), outer
print(urllib.parse.unquote(outer[len("obtainium://app/"):]))
' "${link#"$prefix"}")
[ "$decoded" = "$json" ] || fail "link does not round-trip to the app JSON"

if obtainium_app_json owner/repo latest bad-id Bad pkg >/dev/null 2>&1; then
  fail "hyphenated app ids must be rejected"
fi

# ---- README stays in sync with config ----------------------------------------
expected=$(obtainium_table "$ROOT/config/apps.json" xob0t/morphe-autobuilds)
actual=$(sed -n '/<!-- obtainium:start -->/,/<!-- obtainium:end -->/p' "$ROOT/README.md" \
  | sed '1d;$d' | tr -d '\r')
[ "$actual" = "$expected" ] \
  || fail "README Obtainium table is stale; regenerate it with: bash scripts/obtainium.sh"

echo "obtainium tests passed"
