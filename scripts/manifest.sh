#!/usr/bin/env bash
#
# Consolidate per-app build state into a single manifest.json on the rolling release,
# then refresh the release notes from it. Per-app state arrives as workflow artifacts
# (one state-<id>.json each) downloaded into STATES_DIR by the manifest job. Apps not
# rebuilt this run keep their previous manifest entry.
#
# Required env: CONFIG, GH_TOKEN. Optional: RELEASE_TAG, STATES_DIR (default "states").
set -euo pipefail
CONFIG="${CONFIG:?}"
RELEASE_TAG="${RELEASE_TAG:-$(jq -r '.release_tag // empty' "$CONFIG")}"
if [ -z "$RELEASE_TAG" ]; then
  echo "manifest: RELEASE_TAG is empty and config has no release_tag" >&2
  exit 1
fi
STATES_DIR="${STATES_DIR:-states}"
TITLE=$(jq -r '.release_title // "Morphe patched APKs"' "$CONFIG")
RETENTION_DAYS=$(jq -r '.asset_retention_days // 7' "$CONFIG")
if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
  echo "manifest: asset_retention_days must be a non-negative integer" >&2
  exit 1
fi
WORK="${RUNNER_TEMP:-/tmp}/manifest"; mkdir -p "$WORK"

# Start from the existing manifest's apps (so apps skipped this run are preserved).
gh release download "$RELEASE_TAG" -p manifest.json -D "$WORK" --clobber 2>/dev/null || true
APPS='{}'
if [ -f "$WORK/manifest.json" ] && jq -e '.apps' "$WORK/manifest.json" >/dev/null 2>&1; then
  APPS=$(jq -c '.apps' "$WORK/manifest.json")
fi

# Garbage-collect only old APKs that are not referenced by the currently published
# manifest. A newly uploaded replacement is intentionally too young to be removed;
# the old manifest asset remains referenced until the new manifest is uploaded below.
REFERENCED_ASSETS=$(
  {
    jq -r '.[]?.asset // empty' <<<"$APPS"
    for state in "$STATES_DIR"/state-*.json; do
      [ -f "$state" ] || continue
      jq -r '.asset // empty' "$state" 2>/dev/null || true
    done
  } | sed '/^$/d' | sort -u
)
CUTOFF_EPOCH=$(( $(date -u +%s) - RETENTION_DAYS * 86400 ))
while IFS=$'\t' read -r asset created_at; do
  [[ "$asset" == *.apk ]] || continue
  grep -Fxq "$asset" <<<"$REFERENCED_ASSETS" && continue
  created_epoch=$(date -u -d "$created_at" +%s 2>/dev/null || echo 0)
  if [ "$created_epoch" -gt 0 ] && [ "$created_epoch" -le "$CUTOFF_EPOCH" ]; then
    echo "Deleting unreferenced APK asset older than ${RETENTION_DAYS}d: $asset"
    gh release delete-asset "$RELEASE_TAG" "$asset" --yes \
      || echo "::warning::Could not delete old unreferenced asset $asset"
  fi
done < <(
  gh release view "$RELEASE_TAG" --json assets \
    --jq '.assets[] | [.name, .createdAt] | @tsv' 2>/dev/null || true
)

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
jq -n --arg now "$NOW" --argjson retentionDays "$RETENTION_DAYS" --argjson apps "$APPS" \
  '{schema: 2, updated_at: $now, asset_retention_days: $retentionDays, apps: $apps}' \
  >"$WORK/manifest.json"

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

# The manifest is the publication pointer: upload it last among machine-consumed
# build artifacts, then refresh the human-readable notes from that exact manifest.
gh release upload "$RELEASE_TAG" "$WORK/manifest.json" --clobber
gh release edit "$RELEASE_TAG" --title "$TITLE" --notes-file "$N"

# Migration / tidy: drop any legacy per-app state-<id>.json assets from the release.
LEGACY=$(gh release view "$RELEASE_TAG" --json assets -q '.assets[].name' 2>/dev/null \
  | grep -E '^state-.*\.json$' || true)
for a in $LEGACY; do echo "Deleting legacy asset $a"; gh release delete-asset "$RELEASE_TAG" "$a" --yes || true; done

echo "manifest.json updated for '$RELEASE_TAG' ($UPDATED app(s) updated)."
