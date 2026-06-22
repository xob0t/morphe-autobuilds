#!/usr/bin/env bash
#
# Consolidate per-app build state into a single manifest.json on the rolling release,
# then refresh the release notes from it. Per-app state arrives as workflow artifacts
# (one state-<id>.json each) downloaded into STATES_DIR by the manifest job. Apps not
# rebuilt this run keep their previous manifest entry.
#
# Required env: CONFIG, RELEASE_TAG, GH_TOKEN. Optional: STATES_DIR (default "states").
set -euo pipefail
CONFIG="${CONFIG:?}"; RELEASE_TAG="${RELEASE_TAG:?}"
STATES_DIR="${STATES_DIR:-states}"
TITLE=$(jq -r '.release_title // "Morphe patched APKs"' "$CONFIG")
WORK="${RUNNER_TEMP:-/tmp}/manifest"; mkdir -p "$WORK"

# Start from the existing manifest's apps (so apps skipped this run are preserved).
gh release download "$RELEASE_TAG" -p manifest.json -D "$WORK" --clobber 2>/dev/null || true
APPS='{}'
if [ -f "$WORK/manifest.json" ] && jq -e '.apps' "$WORK/manifest.json" >/dev/null 2>&1; then
  APPS=$(jq -c '.apps' "$WORK/manifest.json")
fi

# Overlay each freshly-built app's state, keyed by its id.
UPDATED=0
shopt -s nullglob
for f in "$STATES_DIR"/state-*.json; do
  jq -e . "$f" >/dev/null 2>&1 || { echo "skip malformed $f"; continue; }
  id=$(jq -r '.app' "$f")
  APPS=$(jq -c --arg id "$id" --slurpfile s "$f" '.[$id] = $s[0]' <<<"$APPS")
  UPDATED=$((UPDATED + 1))
  echo "manifest: updated $id"
done
shopt -u nullglob

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg now "$NOW" --argjson apps "$APPS" \
  '{schema: 1, updated_at: $now, apps: $apps}' >"$WORK/manifest.json"

# Notes table, rendered from the manifest (sorted by app name). The version cell
# links straight to that app's APK asset on this release.
N="$WORK/notes.md"
DL="../../releases/download/$RELEASE_TAG"
{
  echo "Latest [Morphe](https://morphe.software)-patched APKs, rebuilt automatically whenever an app **or** the patches bundle updates. **Every** compatible patch is enabled (app-specific + universal); APKs are re-signed with a stable per-app key so updates install over previous Morphe builds."
  echo
  echo "| App | Version | Download | Patches | Source | Bundle | Built (UTC) |"
  echo "|-----|---------|:-------:|:------:|:------:|--------|-------------|"
  jq -r --arg dl "$DL" '.apps | to_entries | sort_by(.value.name)[] | .value
         | "| \(.name) | `\(.version_name)` | [⬇ APK](\($dl)/\(.asset)) | \(.patches_enabled) | \(.source // "?") | `\(.patches_version)` | \(.built_at) |"' \
     "$WORK/manifest.json"
  echo
  echo "Each APK is the unmodified upstream binary (from RuStore or the vendor's own CDN), patched and re-signed. Machine-readable details: [\`manifest.json\`]($DL/manifest.json). Patches: [xob0t/morphe-patches](https://github.com/xob0t/morphe-patches)."
  echo
  echo "<sub>Updated $NOW.</sub>"
} >"$N"

gh release edit "$RELEASE_TAG" --title "$TITLE" --notes-file "$N"
gh release upload "$RELEASE_TAG" "$WORK/manifest.json" --clobber

# Migration / tidy: drop any legacy per-app state-<id>.json assets from the release.
LEGACY=$(gh release view "$RELEASE_TAG" --json assets -q '.assets[].name' 2>/dev/null \
  | grep -E '^state-.*\.json$' || true)
for a in $LEGACY; do echo "Deleting legacy asset $a"; gh release delete-asset "$RELEASE_TAG" "$a" --yes || true; done

# GitHub freezes a release's published_at at first publish — uploading assets or
# editing notes never moves it, so the release looks stale. When something actually
# built this run, bump it to "now" by re-publishing (draft off→on), keeping the
# Latest flag. Skipped on no-op runs so the date reflects real updates only.
if [ "$UPDATED" -gt 0 ]; then
  REPO="${GITHUB_REPOSITORY:?}"
  RID=$(gh api "repos/$REPO/releases/tags/$RELEASE_TAG" --jq '.id')
  gh api -X PATCH "repos/$REPO/releases/$RID" -F draft=true >/dev/null
  gh api -X PATCH "repos/$REPO/releases/$RID" -F draft=false -f make_latest=true >/dev/null
  echo "Re-published '$RELEASE_TAG' ($UPDATED app(s) updated) — published_at bumped to now."
else
  echo "No apps updated this run — leaving release date unchanged."
fi

echo "manifest.json updated for '$RELEASE_TAG'."
