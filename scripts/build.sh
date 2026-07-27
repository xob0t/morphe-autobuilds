#!/usr/bin/env bash
#
# Build one app: detect a new version, patch it with EVERY compatible Morphe patch
# (app-specific + universal), and publish the APK to the single rolling release.
# Designed to run on a GitHub-hosted ubuntu runner.
#
# The patch step is the validation gate: app patches support one explicit version,
# and every required hook must resolve. Any drift makes morphe-cli exit non-zero.
#
# Required env:
#   APP_ID       app id from config/apps.json (e.g. "avito")
#   CONFIG       path to apps.json
#   MORPHE_CLI   path to morphe-cli-*-all.jar
#   MPP          path to patches-*.mpp
#   PATCHES_METADATA patches-list.json from the same exact patch tag
#   PATCH_TAG     exact resolved patch tag
#   KEYSTORE     path to the decoded signing keystore for this app
#   RELEASE_TAG  the shared rolling release tag (e.g. "latest")
#   GH_TOKEN     token with contents:write on this repo
#   FORCE        "true" to build even if the version is unchanged (optional)
#   GITHUB_OUTPUT  set by Actions; receives built=/version=/failed= (optional)
set -euo pipefail

APP_ID="${APP_ID:?APP_ID required}"
CONFIG="${CONFIG:?CONFIG required}"
RELEASE_TAG="${RELEASE_TAG:?RELEASE_TAG required}"
PATCHES_METADATA="${PATCHES_METADATA:?PATCHES_METADATA required}"
PATCH_TAG="${PATCH_TAG:?PATCH_TAG required}"
FORCE="${FORCE:-false}"
PROMOTION_QUALIFICATION="${PROMOTION_QUALIFICATION:-null}"

log()  { printf '::notice::%s\n' "$*"; }
group(){ printf '::group::%s\n' "$*"; }
endg() { printf '::endgroup::\n'; }
out()  { [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT" || true; }
strip(){ sed 's/\x1b\[[0-9;]*m//g'; }

app() { jq -er --arg id "$APP_ID" '.apps[] | select(.id==$id) | '"$1" "$CONFIG"; }

NAME=$(app '.name')
PACKAGE=$(app '.package')
UA="Mozilla/5.0 (Linux; Android 13)"
mapfile -t DISABLE < <(jq -r --arg id "$APP_ID" '.apps[] | select(.id==$id) | .disable[]?' "$CONFIG")

# Resolve the APK download URL by trying the app's ordered `sources` list until one
# works (resilience: store primary + direct-URL fallback). Sets SRC_URL, UA,
# RESOLVED_TYPE, and — for rustore — RS_VCODE (the upstream versionCode, returned by
# the API before any download, so unchanged apps can be skipped without fetching).
#   direct  — sources[i].url is the APK; validated with a HEAD before committing.
#   rustore — RuStore store API: overallInfo→appId, download-link→single non-split URL.
RS_VCODE=""; RESOLVED_TYPE=""; RESOLVED_INDEX=""; RESOLVED_SOURCE_FINGERPRINT=""
src() { jq -r --arg id "$APP_ID" --argjson i "$1" '.apps[]|select(.id==$id).sources['"$1"']'"$2" "$CONFIG"; }
mark_source() {
  RESOLVED_INDEX="$1"
  RESOLVED_SOURCE_FINGERPRINT=$(
    src "$1" '' | jq -cS . | sha256sum | cut -d' ' -f1
  )
}
resolve_source() {
  local n i type url ua appid resp rs_device_id rs_ver
  n=$(jq -r --arg id "$APP_ID" '.apps[]|select(.id==$id).sources|length' "$CONFIG")
  for ((i=0; i<n; i++)); do
    type=$(src "$i" '.type')
    echo "Trying source #$((i+1))/$n: $type"
    case "$type" in
      direct)
        url=$(src "$i" '.url')
        ua=$(src "$i" '.user_agent // "Mozilla/5.0 (Linux; Android 13)"')
        if curl -fsSIL -A "$ua" --max-time 30 "$url" >/dev/null 2>&1; then
          RESOLVED_TYPE=direct; SRC_URL=$url; UA=$ua
          mark_source "$i"
          echo "  using direct: $url"; return 0
        fi
        echo "  direct source unreachable" ;;
      rustore)
        rs_device_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
          || printf '%s-%s' "$RANDOM$RANDOM" "$RANDOM$RANDOM")
        if rs_ver=$(curl -fsS --retry 2 --max-time 30 \
              -H "deviceId: $rs_device_id" \
              "https://backapi.rustore.ru/rustore-info/new-version" 2>/dev/null \
              | jq -er '.body.latestVersion' 2>/dev/null) \
           && appid=$(curl -fsS --retry 2 --max-time 30 \
              -H "deviceId: $rs_device_id" \
              -H "ruStoreVerCode: $rs_ver" \
              "https://backapi.rustore.ru/applicationData/overallInfo/$PACKAGE" 2>/dev/null \
              | jq -er '.body.appId' 2>/dev/null) \
           && resp=$(curl -fsS --retry 2 --max-time 30 -X POST \
              "https://backapi.rustore.ru/applicationData/v2/download-link" \
              -H "deviceId: $rs_device_id" \
              -H "ruStoreVerCode: $rs_ver" \
              -H "Content-Type: application/json" \
              -d "{\"appId\":$appid,\"firstInstall\":true,\"withoutSplits\":true}" 2>/dev/null) \
           && url=$(printf '%s' "$resp" | jq -er '.body.downloadUrls[0].url' 2>/dev/null); then
          RESOLVED_TYPE=rustore; SRC_URL=$url
          RS_VCODE=$(printf '%s' "$resp" | jq -er '.body.versionCode')
          mark_source "$i"
          echo "  using RuStore: appId=$appid versionCode=$RS_VCODE"; return 0
        fi
        echo "  RuStore resolve failed" ;;
      *) echo "  unknown source type '$type'" ;;
    esac
  done
  echo "::error::All sources failed for $APP_ID" >&2; return 1
}

WORK="${RUNNER_TEMP:-/tmp}/$APP_ID"
mkdir -p "$WORK"
APK="$WORK/original.apk"
# Per-app state is written here and handed to the manifest job as a workflow
# artifact (STATE_OUT, set by the workflow). The release keeps only manifest.json.
STATE_FILE="${STATE_OUT:-$WORK/state-$APP_ID.json}"

# ---- 1. recorded state from the consolidated manifest.json -------------------
PREV_CODE=0
PREV_ETAG=""
PREV_LEN=""
PREV_PATCHES=""
if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  if gh release download "$RELEASE_TAG" -p manifest.json -D "$WORK" --clobber 2>/dev/null; then
    # Tolerate a missing/old/malformed manifest (don't let jq abort set -e).
    PREV_CODE=$(jq -r --arg id "$APP_ID" '.apps[$id].version_code // 0' "$WORK/manifest.json" 2>/dev/null || echo 0)
    PREV_ETAG=$(jq -r --arg id "$APP_ID" '.apps[$id].etag // ""' "$WORK/manifest.json" 2>/dev/null || echo "")
    PREV_LEN=$(jq -r --arg id "$APP_ID" '.apps[$id].content_length // ""' "$WORK/manifest.json" 2>/dev/null || echo "")
    PREV_PATCHES=$(jq -r --arg id "$APP_ID" '.apps[$id].patches_version // ""' "$WORK/manifest.json" 2>/dev/null || echo "")
  fi
fi

# Rebuild when forced, or when the patches bundle changed since this app's last
# build (so a new patches release refreshes every app, not just ones whose app
# version moved). Otherwise the version/ETag change-checks below decide.
CUR_PATCHES=$(basename "$MPP" | sed -E 's/^patches-(.*)\.mpp$/\1/')
REBUILD=false
if [ "$FORCE" = "true" ]; then
  REBUILD=true
elif [ -n "$PREV_PATCHES" ] && [ "$CUR_PATCHES" != "$PREV_PATCHES" ]; then
  REBUILD=true
  log "$NAME: patches bundle changed ($PREV_PATCHES → $CUR_PATCHES) — will rebuild."
fi
log "$NAME: last built versionCode=$PREV_CODE on patches $PREV_PATCHES (current $CUR_PATCHES)."

# ---- 2. resolve source + cheap change check ----------------------------------
group "Resolve source + change check"
resolve_source
ETAG=""; LASTMOD=""; CLEN=""
if [ "$RESOLVED_TYPE" = "rustore" ]; then
  # RuStore hands us the versionCode without downloading — the best change signal.
  if [ "$REBUILD" != "true" ] && [ -n "$RS_VCODE" ] && [ "$RS_VCODE" -le "$PREV_CODE" ]; then
    endg; log "$NAME: RuStore versionCode $RS_VCODE not newer than $PREV_CODE, patches unchanged — skipping."
    out built false; exit 0
  fi
else
  HEADERS=$(curl -fsSIL -A "$UA" "$SRC_URL" 2>/dev/null || true)
  # ETag values arrive wrapped in literal double-quotes (and may be weak: W/"…");
  # strip quotes so the value is JSON-safe and compares cleanly run-to-run.
  ETAG=$(printf '%s' "$HEADERS" | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}' | tail -1 | tr -d '"')
  LASTMOD=$(printf '%s' "$HEADERS" | tr -d '\r' | awk -F': ' 'tolower($1)=="last-modified"{print $2}' | tail -1)
  CLEN=$(printf '%s' "$HEADERS" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}' | tail -1)
  echo "etag=$ETAG last-modified=$LASTMOD content-length=$CLEN"
  if [ "$REBUILD" != "true" ]; then
    if [ -n "$ETAG" ] && [ "$ETAG" = "$PREV_ETAG" ]; then
      endg; log "$NAME: source unchanged (ETag match), patches unchanged — skipping."; out built false; exit 0
    fi
    if [ -z "$ETAG" ] && [ -n "$CLEN" ] && [ "$CLEN" = "$PREV_LEN" ]; then
      endg; log "$NAME: source unchanged (Content-Length match), patches unchanged — skipping."; out built false; exit 0
    fi
  fi
fi
endg

# ---- 3. download + read version ----------------------------------------------
group "Download $NAME"
curl -fL --retry 3 --retry-delay 5 -A "$UA" -o "$APK" "$SRC_URL"
ls -lh "$APK"

# RuStore may wrap the installable APK with ART baseline profiles in an outer ZIP.
# Keep a normal APK unchanged; otherwise require and extract exactly one APK entry.
if [ "$RESOLVED_TYPE" = "rustore" ]; then
  if ! ZIP_ENTRIES=$(unzip -Z1 "$APK" 2>/dev/null); then
    echo "::error::RuStore download is neither an APK nor a readable ZIP archive." >&2
    exit 1
  fi
  if ! grep -Fxq 'AndroidManifest.xml' <<<"$ZIP_ENTRIES"; then
    mapfile -t WRAPPED_APKS < <(printf '%s\n' "$ZIP_ENTRIES" | awk 'tolower($0) ~ /\.apk$/')
    if [ "${#WRAPPED_APKS[@]}" -ne 1 ]; then
      echo "::error::RuStore wrapper contains ${#WRAPPED_APKS[@]} APK entries; expected exactly one." >&2
      exit 1
    fi
    EXTRACTED_APK="$WORK/rustore-extracted.apk"
    if ! unzip -p "$APK" "${WRAPPED_APKS[0]}" >"$EXTRACTED_APK" || [ ! -s "$EXTRACTED_APK" ]; then
      echo "::error::Failed to extract APK from RuStore wrapper." >&2
      exit 1
    fi
    mv "$EXTRACTED_APK" "$APK"
    echo "Extracted RuStore APK: ${WRAPPED_APKS[0]}"
    ls -lh "$APK"
  fi
fi
endg

AAPT2=$(ls "$ANDROID_SDK_ROOT"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1)
BADGING=$("$AAPT2" dump badging "$APK")
VCODE=$(printf '%s' "$BADGING" | sed -n "s/.*versionCode='\([0-9]*\)'.*/\1/p" | head -1)
VNAME=$(printf '%s' "$BADGING" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p" | head -1)
PKG=$(printf '%s' "$BADGING" | sed -n "s/package: name='\([^']*\)'.*/\1/p" | head -1)
log "$NAME: downloaded $PKG $VNAME (versionCode $VCODE)"

if [ "$PKG" != "$PACKAGE" ]; then
  echo "::error::Downloaded package '$PKG' != expected '$PACKAGE' — source URL may have changed." >&2
  exit 1
fi
if [ "$REBUILD" != "true" ] && [ "${VCODE:-0}" -le "$PREV_CODE" ]; then
  log "$NAME: versionCode $VCODE not newer than $PREV_CODE, patches unchanged — skipping."; out built false; exit 0
fi

APK_SHA256=$(sha256sum "$APK" | cut -d' ' -f1)
MPP_SHA256=$(sha256sum "$MPP" | cut -d' ' -f1)

# patches-list.json comes from the same immutable tag as the MPP. Exact
# non-experimental version/versionCode pairs are authoritative for this package.
PACKAGE_TARGETS=$(jq -c --arg pkg "$PACKAGE" '
  [
    .patches[].compatiblePackages[]?
    | select(.packageName == $pkg)
    | .targets[]?
    | select(
        .version != null
        and .versionCode != null
        and .isExperimental == false
      )
    | {version, versionCode}
  ]
  | unique_by([.version, .versionCode])
' "$PATCHES_METADATA")
if [ "$(jq 'length' <<<"$PACKAGE_TARGETS")" -eq 0 ]; then
  echo "::error::No exact targets with versionCode found for $PACKAGE in $PATCH_TAG." >&2
  out built false; out failed true; out version "$VNAME"; out failed_patches "missing-target-metadata"; exit 1
fi

QUALIFICATION=false
if ! jq -e --arg version "$VNAME" --argjson code "$VCODE" \
  'any(.[]; .version == $version and .versionCode == $code)' \
  <<<"$PACKAGE_TARGETS" >/dev/null; then
  QUALIFICATION=true
  log "$NAME $VNAME ($VCODE) is unlisted in $PATCH_TAG; entering target qualification."
fi

# A stable-release dispatch may carry the evidence that caused this target to be
# appended. Matching input provenance is useful confirmation; any drift is safe
# because this exact-target, non-forced build is itself the authoritative recheck.
if jq -e --arg app "$APP_ID" --arg version "$VNAME" --argjson code "$VCODE" '
    type == "object"
    and .app == $app
    and .version_name == $version
    and .version_code == $code
  ' <<<"$PROMOTION_QUALIFICATION" >/dev/null 2>&1; then
  if jq -e \
      --arg source "$RESOLVED_TYPE" \
      --argjson sourceIndex "$RESOLVED_INDEX" \
      --arg sourceFingerprint "$RESOLVED_SOURCE_FINGERPRINT" \
      --arg apkSha256 "$APK_SHA256" '
        .source == $source
        and .source_index == $sourceIndex
        and .source_fingerprint == $sourceFingerprint
        and .apk_sha256 == $apkSha256
      ' <<<"$PROMOTION_QUALIFICATION" >/dev/null; then
    log "$NAME: stable rebuild input matches the promotion qualification."
  else
    log "$NAME: stable rebuild input changed since qualification; this strict build will requalify it."
  fi
fi

# ---- 4. enable EVERY compatible patch (app-specific + universal) -------------
group "Resolve patch list"
mapfile -t ALL_PATCHES < <(java -jar "$MORPHE_CLI" list-patches --patches="$MPP" -f "$PACKAGE" 2>/dev/null | strip | sed -n 's/^Name: //p')
if [ "${#ALL_PATCHES[@]}" -eq 0 ]; then
  echo "::error::No patches found compatible with $PACKAGE in the bundle." >&2; exit 1
fi
ENABLE_ARGS=()
SELECTED_PATCHES=()
ENABLED_PATCH_COUNT=0
for p in "${ALL_PATCHES[@]}"; do
  skip=false
  for d in "${DISABLE[@]}"; do [ "$p" = "$d" ] && skip=true && break; done
  $skip && { echo "config-disabled: $p"; continue; }
  ENABLE_ARGS+=(--enable="$p")
  SELECTED_PATCHES+=("$p")
  ENABLED_PATCH_COUNT=$((ENABLED_PATCH_COUNT + 1))
done
echo "Enabling $ENABLED_PATCH_COUNT of ${#ALL_PATCHES[@]} compatible patches."
endg

# ---- 5. patch (this is the test) ---------------------------------------------
OUT="$WORK/${APP_ID}-${VNAME}-morphe.apk"
group "Patch $NAME $VNAME"
COMPATIBILITY_ARGS=()
if [ "$QUALIFICATION" = "true" ]; then
  COMPATIBILITY_ARGS+=(--force)
fi
set +e
java -jar "$MORPHE_CLI" patch \
  "${COMPATIBILITY_ARGS[@]}" \
  --bytecode-mode FULL \
  --exclusive \
  "${ENABLE_ARGS[@]}" \
  --patches="$MPP" \
  --keystore="$KEYSTORE" \
  --out="$OUT" \
  --result-file="$WORK/result.json" \
  --temporary-files-path="$WORK/tmp" \
  "$APK"
RC=$?
set -e
endg
if [ $RC -ne 0 ]; then
  # Name the patch(es) morphe-cli reported as failed.
  FAILED=$(jq -r '.failedPatches[]? | (.name // .patch.name // .patch // empty) | strings' "$WORK/result.json" 2>/dev/null | paste -sd, - || true)
  echo "::error::$NAME $VNAME failed to patch (rc=$RC). Failed patch(es): ${FAILED:-unknown}." >&2
  out built false; out failed true; out version "$VNAME"; out failed_patches "${FAILED:-unknown}"; exit $RC
fi

# morphe-cli treats version-incompatible explicitly enabled patches as warnings:
# it skips them, patches with the remaining selection, and exits zero. The result
# report is therefore the authoritative postcondition for CI. Refuse to publish
# unless every patch selected above is present in appliedPatches.
# kotlinx.serialization omits success when it has its default value (true), but
# writes false on an unsuccessful run.
if ! jq -e '(.success // true) == true and (.appliedPatches | type == "array")' "$WORK/result.json" >/dev/null 2>&1; then
  echo "::error::$NAME $VNAME produced an unsuccessful or invalid patch result report." >&2
  out built false; out failed true; out version "$VNAME"; out failed_patches "invalid-result-report"; exit 1
fi

mapfile -t APPLIED_PATCHES < <(jq -r '.appliedPatches[]?.name // empty' "$WORK/result.json")
SELECTED_FILE="$WORK/selected-patches.txt"
APPLIED_FILE="$WORK/applied-patches.txt"
printf '%s\n' "${SELECTED_PATCHES[@]}" | sort >"$SELECTED_FILE"
printf '%s\n' "${APPLIED_PATCHES[@]}" | sort >"$APPLIED_FILE"
if ! cmp -s "$SELECTED_FILE" "$APPLIED_FILE"; then
  MISSING=$(comm -23 "$SELECTED_FILE" "$APPLIED_FILE" | paste -sd, - || true)
  UNEXPECTED=$(comm -13 "$SELECTED_FILE" "$APPLIED_FILE" | paste -sd, - || true)
  DETAILS="missing=${MISSING:-none};unexpected=${UNEXPECTED:-none}"
  echo "::error::$NAME $VNAME selected/applied patch multisets differ ($DETAILS)." >&2
  out built false; out failed true; out version "$VNAME"; out failed_patches "$DETAILS"; exit 1
fi

APPLIED_PATCH_COUNT=${#APPLIED_PATCHES[@]}
echo "Applied all $APPLIED_PATCH_COUNT selected patches."
ls -lh "$OUT"

# ---- 6. qualify or stage an immutable APK ------------------------------------
MPP_VER=$(basename "$MPP" | sed -E 's/^patches-(.*)\.mpp$/\1/')
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ "$QUALIFICATION" = "true" ]; then
  QUALIFICATION_FILE="${QUALIFICATION_OUT:-$WORK/qualification-$APP_ID.json}"
  SELECTED_JSON=$(jq -Rn '[inputs]' <"$SELECTED_FILE")
  APPLIED_JSON=$(jq -Rn '[inputs]' <"$APPLIED_FILE")
  RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}"
  jq -n \
    --arg app "$APP_ID" --arg name "$NAME" --arg pkg "$PACKAGE" \
    --arg version "$VNAME" --argjson versionCode "$VCODE" \
    --arg source "$RESOLVED_TYPE" --argjson sourceIndex "$RESOLVED_INDEX" \
    --arg sourceFingerprint "$RESOLVED_SOURCE_FINGERPRINT" \
    --arg apkSha256 "$APK_SHA256" --arg patchTag "$PATCH_TAG" \
    --arg patchBundleSha256 "$MPP_SHA256" --arg patchesVersion "$MPP_VER" \
    --arg runUrl "$RUN_URL" \
    --arg autobuildRepository "${GITHUB_REPOSITORY:-unknown}" \
    --arg qualifiedAt "$BUILT_AT" \
    --argjson selected "$SELECTED_JSON" --argjson applied "$APPLIED_JSON" \
    '{
      schema: 1,
      qualification: true,
      app: $app,
      name: $name,
      package: $pkg,
      version_name: $version,
      version_code: $versionCode,
      source: $source,
      source_index: $sourceIndex,
      source_fingerprint: $sourceFingerprint,
      apk_sha256: $apkSha256,
      patch_tag: $patchTag,
      patch_bundle_sha256: $patchBundleSha256,
      patches_version: $patchesVersion,
      selected_patches: $selected,
      applied_patches: $applied,
      run_url: $runUrl,
      autobuild_repository: $autobuildRepository,
      qualified_at: $qualifiedAt
    }' >"$QUALIFICATION_FILE"
  log "$NAME $VNAME qualified successfully; publication waits for target promotion."
  out built false
  out qualified true
  out version "$VNAME"
  out version_code "$VCODE"
  exit 0
fi

OUT_SHA256=$(sha256sum "$OUT" | cut -d' ' -f1)
ASSET="${APP_ID}-${VNAME}-morphe-${OUT_SHA256:0:12}.apk"
IMMUTABLE_OUT="$WORK/$ASSET"
mv "$OUT" "$IMMUTABLE_OUT"

# Upload under a content-addressed immutable name. The currently referenced APK
# remains untouched; the serialized manifest job activates this asset later.
group "Upload immutable APK"
if gh release view "$RELEASE_TAG" --json assets -q '.assets[].name' 2>/dev/null \
  | grep -Fxq "$ASSET"; then
  echo "Asset $ASSET already exists; verifying it."
else
  gh release upload "$RELEASE_TAG" "$IMMUTABLE_OUT"
fi
VERIFY_DIR="$WORK/verify-upload"
mkdir -p "$VERIFY_DIR"
gh release download "$RELEASE_TAG" -p "$ASSET" -D "$VERIFY_DIR" --clobber
UPLOADED_SHA256=$(sha256sum "$VERIFY_DIR/$ASSET" | cut -d' ' -f1)
if [ "$UPLOADED_SHA256" != "$OUT_SHA256" ]; then
  echo "::error::Uploaded asset digest mismatch for $ASSET." >&2
  out built false; out failed true; out version "$VNAME"; out failed_patches "upload-digest-mismatch"; exit 1
fi
endg

jq -n \
  --arg app "$APP_ID" --arg name "$NAME" --arg pkg "$PACKAGE" \
  --arg vn "$VNAME" --argjson vc "${VCODE:-0}" \
  --arg etag "$ETAG" --arg lm "$LASTMOD" --arg clen "$CLEN" \
  --arg src "$RESOLVED_TYPE" --argjson srcIndex "$RESOLVED_INDEX" \
  --arg srcFingerprint "$RESOLVED_SOURCE_FINGERPRINT" \
  --arg apkSha256 "$APK_SHA256" --arg outputSha256 "$OUT_SHA256" \
  --arg pv "$MPP_VER" --argjson pe "$APPLIED_PATCH_COUNT" \
  --arg asset "$ASSET" --arg built "$BUILT_AT" \
  '{app:$app, name:$name, package:$pkg, version_name:$vn, version_code:$vc,
    etag:$etag, last_modified:$lm, content_length:$clen, source:$src,
    source_index:$srcIndex, source_fingerprint:$srcFingerprint,
    apk_sha256:$apkSha256, output_sha256:$outputSha256,
    patches_version:$pv, patches_enabled:$pe, asset:$asset, built_at:$built}' \
  >"$STATE_FILE"

log "$NAME: staged $VNAME ($APPLIED_PATCH_COUNT patches, via $RESOLVED_TYPE) as '$ASSET'."
out built true
out qualified false
out version "$VNAME"
