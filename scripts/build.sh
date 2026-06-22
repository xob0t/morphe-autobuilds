#!/usr/bin/env bash
#
# Build one app: detect a new version, patch it with Morphe, publish to a rolling
# "<app>-latest" release. Designed to run on a GitHub-hosted ubuntu runner.
#
# The patch step IS the regression test: if a fingerprint no longer resolves on a
# new app version, morphe-cli exits non-zero and this script fails the job.
#
# Required env:
#   APP_ID            app id from config/apps.json (e.g. "avito")
#   CONFIG            path to apps.json
#   MORPHE_CLI        path to morphe-cli-*-all.jar
#   MPP               path to patches-*.mpp
#   KEYSTORE          path to the decoded signing keystore for this app
#   GH_TOKEN          token with contents:write on this repo
#   FORCE             "true" to build even if the version is unchanged (optional)
#   GITHUB_OUTPUT     set by Actions; receives built=/version= (optional)
set -euo pipefail

APP_ID="${APP_ID:?APP_ID required}"
CONFIG="${CONFIG:?CONFIG required}"
FORCE="${FORCE:-false}"

log()  { printf '::notice::%s\n' "$*"; }
group(){ printf '::group::%s\n' "$*"; }
endg() { printf '::endgroup::\n'; }
out()  { [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT" || true; }

app() { jq -er --arg id "$APP_ID" '.apps[] | select(.id==$id) | '"$1" "$CONFIG"; }

NAME=$(app '.name')
PACKAGE=$(app '.package')
RELEASE_TAG=$(app '.release_tag')
SRC_URL=$(app '.source.url')
UA=$(app '.source.user_agent')
mapfile -t PATCH_ARGS < <(jq -r --arg id "$APP_ID" '.apps[] | select(.id==$id) | .patch_args[]?' "$CONFIG")

WORK="${RUNNER_TEMP:-/tmp}/$APP_ID"
mkdir -p "$WORK"
APK="$WORK/original.apk"

# ---- 1. recorded state from the current rolling release -----------------------
PREV_CODE=0
PREV_ETAG=""
PREV_LEN=""
if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  if gh release download "$RELEASE_TAG" -p state.json -D "$WORK" --clobber 2>/dev/null; then
    PREV_CODE=$(jq -r '.version_code // 0' "$WORK/state.json")
    PREV_ETAG=$(jq -r '.etag // ""' "$WORK/state.json")
    PREV_LEN=$(jq -r '.content_length // ""' "$WORK/state.json")
  fi
fi
log "$NAME: last built versionCode=$PREV_CODE"

# ---- 2. cheap change check via ETag / Last-Modified / Content-Length ----------
# Some CDNs (Avito) expose only Content-Length; others (T-Bank) expose ETag. Use
# whichever is present to skip the (hundreds-of-MB) download when nothing changed.
# versionCode is still the authoritative dedup once downloaded.
group "Change check"
HEADERS=$(curl -fsSIL -A "$UA" "$SRC_URL" 2>/dev/null || true)
ETAG=$(printf '%s' "$HEADERS" | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}' | tail -1)
LASTMOD=$(printf '%s' "$HEADERS" | tr -d '\r' | awk -F': ' 'tolower($1)=="last-modified"{print $2}' | tail -1)
CLEN=$(printf '%s' "$HEADERS" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}' | tail -1)
echo "etag=$ETAG last-modified=$LASTMOD content-length=$CLEN"
endg
if [ "$FORCE" != "true" ]; then
  if [ -n "$ETAG" ] && [ "$ETAG" = "$PREV_ETAG" ]; then
    log "$NAME: source unchanged (ETag match) — skipping."
    out built false; exit 0
  fi
  if [ -z "$ETAG" ] && [ -n "$CLEN" ] && [ "$CLEN" = "$PREV_LEN" ]; then
    log "$NAME: source unchanged (Content-Length match, no ETag) — skipping."
    out built false; exit 0
  fi
fi

# ---- 3. download + read version ----------------------------------------------
group "Download $NAME"
curl -fL --retry 3 --retry-delay 5 -A "$UA" -o "$APK" "$SRC_URL"
ls -lh "$APK"
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
if [ "$FORCE" != "true" ] && [ "${VCODE:-0}" -le "$PREV_CODE" ]; then
  log "$NAME: versionCode $VCODE not newer than $PREV_CODE — skipping."
  out built false
  exit 0
fi

# ---- 4. patch (this is the test) ---------------------------------------------
OUT="$WORK/${APP_ID}-${VNAME}-morphe.apk"
group "Patch $NAME $VNAME"
set +e
java -jar "$MORPHE_CLI" patch \
  --force \
  "${PATCH_ARGS[@]}" \
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
  echo "::error::$NAME $VNAME failed to patch (rc=$RC). A patch fingerprint likely broke on the new app version." >&2
  out built false
  out failed true
  out version "$VNAME"
  exit $RC
fi
ls -lh "$OUT"

# ---- 5. publish to rolling release -------------------------------------------
MPP_VER=$(basename "$MPP" | sed -E 's/^patches-(.*)\.mpp$/\1/')
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$WORK/state.json" <<EOF
{
  "package": "$PACKAGE",
  "version_name": "$VNAME",
  "version_code": ${VCODE:-0},
  "etag": "${ETAG}",
  "last_modified": "${LASTMOD}",
  "content_length": "${CLEN}",
  "patches_version": "$MPP_VER",
  "built_at": "$BUILT_AT"
}
EOF

NOTES="$WORK/notes.md"
{
  echo "### $NAME $VNAME"
  echo
  echo "- Package: \`$PACKAGE\`"
  echo "- versionCode: \`$VCODE\`"
  echo "- Patched with Morphe patches \`$MPP_VER\` ([xob0t/morphe-patches](https://github.com/xob0t/morphe-patches))"
  echo "- Built: $BUILT_AT"
  echo
  echo "Unmodified upstream APK from the official source, patched and re-signed with a stable key so updates install over previous Morphe builds."
} >"$NOTES"

if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  gh release edit "$RELEASE_TAG" --title "$NAME (latest)" --notes-file "$NOTES"
else
  gh release create "$RELEASE_TAG" --title "$NAME (latest)" --notes-file "$NOTES"
fi
gh release upload "$RELEASE_TAG" "$OUT" "$WORK/state.json" --clobber

log "$NAME: published $VNAME to release '$RELEASE_TAG'."
out built true
out version "$VNAME"
