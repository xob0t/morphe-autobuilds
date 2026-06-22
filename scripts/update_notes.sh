#!/usr/bin/env bash
#
# Regenerate the single rolling release's notes from the per-app state-<id>.json
# assets currently attached to it. Run after the build matrix.
#
# Required env: CONFIG, RELEASE_TAG, GH_TOKEN
set -euo pipefail
CONFIG="${CONFIG:?}"; RELEASE_TAG="${RELEASE_TAG:?}"
TITLE=$(jq -r '.release_title // "Morphe patched APKs"' "$CONFIG")
WORK="${RUNNER_TEMP:-/tmp}/notes"; mkdir -p "$WORK"

gh release download "$RELEASE_TAG" -D "$WORK" --clobber -p 'state-*.json' 2>/dev/null || true

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
N="$WORK/notes.md"
{
  echo "Auto-built APKs patched with [Morphe](https://morphe.software) — **every** compatible patch enabled (app-specific + universal). Rebuilt automatically whenever an app ships a new version."
  echo
  echo "| App | Version | Patches | Bundle | Built (UTC) |"
  echo "|-----|---------|:------:|--------|-------------|"
  for f in "$WORK"/state-*.json; do
    [ -e "$f" ] || continue
    nm=$(jq -r '.name' "$f"); vn=$(jq -r '.version_name' "$f")
    pc=$(jq -r '.patches_enabled // "?"' "$f"); pv=$(jq -r '.patches_version' "$f")
    bt=$(jq -r '.built_at' "$f")
    echo "| $nm | \`$vn\` | $pc | \`$pv\` | $bt |"
  done
  echo
  echo "APKs are unmodified upstream binaries from each app's official source, patched and re-signed with a stable per-app key so updates install over previous Morphe builds. Patches: [xob0t/morphe-patches](https://github.com/xob0t/morphe-patches)."
  echo
  echo "<sub>Notes refreshed $NOW.</sub>"
} >"$N"

gh release edit "$RELEASE_TAG" --title "$TITLE" --notes-file "$N"
echo "Updated notes for '$RELEASE_TAG'."
