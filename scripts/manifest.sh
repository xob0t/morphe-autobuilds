#!/usr/bin/env bash
#
# Publish workflow-staged APK candidates to the single rolling release, then
# activate them with manifest.json. Public APK names stay clean. Existing assets
# are renamed to run-scoped backups immediately before replacement and restored
# if any upload, digest verification, manifest update, or notes update fails.
#
# Required env: CONFIG, GH_TOKEN, GITHUB_REPOSITORY.
# Optional: RELEASE_TAG, PUBLICATIONS_DIR (default "publications").
set -euo pipefail

CONFIG="${CONFIG:?CONFIG required}"
REPOSITORY="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
RELEASE_TAG="${RELEASE_TAG:-$(jq -r '.release_tag // empty' "$CONFIG")}"
PUBLICATIONS_DIR="${PUBLICATIONS_DIR:-publications}"
TITLE=$(jq -r '.release_title // "Morphe patched APKs"' "$CONFIG")
RUN_KEY="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
WORK="${RUNNER_TEMP:-/tmp}/publisher"
VERIFY_DIR="$WORK/verify"
OLD_MANIFEST="$WORK/old-manifest.json"
NEW_MANIFEST="$WORK/manifest.json"
OLD_NOTES="$WORK/old-notes.md"
NEW_NOTES="$WORK/notes.md"

if [ -z "$RELEASE_TAG" ]; then
  echo "publisher: RELEASE_TAG is empty and config has no release_tag" >&2
  exit 1
fi

mkdir -p "$WORK" "$VERIFY_DIR"

asset_id() {
  local name=$1
  gh release view "$RELEASE_TAG" --json assets \
    | jq -r --arg name "$name" \
      '.assets[] | select(.name == $name) | .apiUrl | split("/")[-1]' \
    | head -1
}

asset_digest() {
  local name=$1
  gh release view "$RELEASE_TAG" --json assets \
    | jq -r --arg name "$name" \
      '.assets[] | select(.name == $name) | .digest // empty' \
    | head -1
}

matching_backup_id() {
  local name=$1 digest=$2
  gh release view "$RELEASE_TAG" --json assets \
    | jq -r --arg name "$name" --arg digest "sha256:$digest" '
        [
          .assets[]
          | select(
              (.name | startswith("backup-"))
              and (.name | endswith("-" + $name))
              and .digest == $digest
            )
        ]
        | sort_by(.updatedAt)
        | last
        | .apiUrl // empty
        | split("/")[-1]
      '
}

latest_manifest_backup_id() {
  gh release view "$RELEASE_TAG" --json assets \
    | jq -r '
        [
          .assets[]
          | select(
              (.name | startswith("backup-"))
              and (.name | endswith("-manifest.json"))
            )
        ]
        | sort_by(.updatedAt)
        | last
        | .apiUrl // empty
        | split("/")[-1]
      '
}

rename_asset() {
  local id=$1 name=$2
  gh api --method PATCH "repos/$REPOSITORY/releases/assets/$id" \
    -f name="$name" --silent
}

delete_asset() {
  local name=$1 id
  id=$(asset_id "$name")
  if [ -n "$id" ]; then
    gh api --method DELETE "repos/$REPOSITORY/releases/assets/$id" --silent
  fi
}

download_and_verify() {
  local name=$1 expected=$2 destination=$3 actual
  rm -f "$destination"
  gh release download "$RELEASE_TAG" --pattern "$name" \
    --dir "$(dirname "$destination")" --clobber
  actual=$(sha256sum "$destination" | cut -d' ' -f1)
  if [ "$actual" != "$expected" ]; then
    echo "publisher: digest mismatch for $name (expected $expected, got $actual)" >&2
    return 1
  fi
}

# Recover a manifest rename if a runner was terminated in the narrow swap window.
if [ -z "$(asset_id manifest.json)" ]; then
  stale_manifest_backup_id=$(latest_manifest_backup_id)
  if [ -n "$stale_manifest_backup_id" ]; then
    echo "publisher: restoring manifest.json left by an interrupted publication."
    rename_asset "$stale_manifest_backup_id" manifest.json
  fi
fi

# Snapshot and reconcile the currently active publication before starting another
# transaction. This makes a later run self-heal if a runner was terminated after
# an asset rename but before its normal EXIT rollback completed.
gh release download "$RELEASE_TAG" --pattern manifest.json \
  --dir "$WORK" --clobber 2>/dev/null || true
APPS='{}'
HAVE_MANIFEST=false
if [ -f "$NEW_MANIFEST" ] && jq -e '.apps | type == "object"' "$NEW_MANIFEST" >/dev/null 2>&1; then
  mv "$NEW_MANIFEST" "$OLD_MANIFEST"
  APPS=$(jq -c '.apps' "$OLD_MANIFEST")
  HAVE_MANIFEST=true
fi

if [ "$HAVE_MANIFEST" = "true" ]; then
  while IFS=$'\t' read -r active expected; do
    [ -n "$active" ] || continue
    current_digest=$(asset_digest "$active")
    if [ "$current_digest" != "sha256:$expected" ]; then
      backup_id=$(matching_backup_id "$active" "$expected")
      if [ -z "$backup_id" ]; then
        echo "publisher: active asset $active does not match manifest and has no valid backup" >&2
        exit 1
      fi
      echo "publisher: restoring interrupted asset swap for $active"
      delete_asset "$active"
      rename_asset "$backup_id" "$active"
    fi
  done < <(
    jq -r '.apps[] | [.asset, .output_sha256] | @tsv' "$OLD_MANIFEST"
  )

  # Once every manifest entry is verified, any other APK is unreferenced staging,
  # legacy, or backup data and can be removed safely.
  KEEP_APKS=$(jq -r '.apps[]?.asset // empty' "$OLD_MANIFEST" | sort -u)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! grep -Fxq "$name" <<<"$KEEP_APKS"; then
      echo "publisher: deleting unreferenced APK $name"
      delete_asset "$name" || echo "::warning::Could not delete unreferenced APK $name"
    fi
  done < <(
    gh release view "$RELEASE_TAG" --json assets \
      | jq -r '.assets[] | select(.name | endswith(".apk")) | .name'
  )
fi

shopt -s nullglob
STATE_FILES=("$PUBLICATIONS_DIR"/state-*.json)
shopt -u nullglob
if [ "${#STATE_FILES[@]}" -eq 0 ]; then
  echo "publisher: no workflow candidates; active release verified and unchanged."
  exit 0
fi

# Snapshot release notes for rollback.
RELEASE_INFO=$(gh release view "$RELEASE_TAG" --json name,body)
OLD_TITLE=$(jq -r '.name // ""' <<<"$RELEASE_INFO")
jq -r '.body // ""' <<<"$RELEASE_INFO" >"$OLD_NOTES"

# Validate every workflow state/candidate pair before changing the public release.
declare -A SEEN_APPS=()
declare -A SEEN_ASSETS=()
for state in "${STATE_FILES[@]}"; do
  jq -e '
    type == "object"
    and (.app | type == "string" and length > 0)
    and (.version_name | type == "string" and length > 0)
    and (.version_code | type == "number")
    and (.asset | type == "string" and test("^[0-9A-Za-z._+-]+\\.apk$"))
    and (.output_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
  ' "$state" >/dev/null

  id=$(jq -r '.app' "$state")
  asset=$(jq -r '.asset' "$state")
  expected=$(jq -r '.output_sha256' "$state")
  version=$(jq -r '.version_name' "$state")
  candidate="$PUBLICATIONS_DIR/candidate/$asset"
  configured_package=$(jq -r --arg id "$id" '.apps[] | select(.id == $id) | .package' "$CONFIG")
  state_package=$(jq -r '.package' "$state")

  if [ -z "$configured_package" ] || [ "$configured_package" != "$state_package" ]; then
    echo "publisher: state package does not match configured app $id" >&2
    exit 1
  fi
  if [ "$asset" != "${id}-${version}-morphe.apk" ]; then
    echo "publisher: unexpected clean asset name '$asset' for $id $version" >&2
    exit 1
  fi
  if [ -n "${SEEN_APPS[$id]:-}" ] || [ -n "${SEEN_ASSETS[$asset]:-}" ]; then
    echo "publisher: duplicate app or asset in workflow candidates: $id / $asset" >&2
    exit 1
  fi
  if [ ! -f "$candidate" ]; then
    echo "publisher: missing workflow candidate $candidate" >&2
    exit 1
  fi
  actual=$(sha256sum "$candidate" | cut -d' ' -f1)
  if [ "$actual" != "$expected" ]; then
    echo "publisher: workflow candidate digest mismatch for $asset" >&2
    exit 1
  fi

  SEEN_APPS[$id]=1
  SEEN_ASSETS[$asset]=1
  APPS=$(jq -c --arg id "$id" --slurpfile state "$state" \
    '.[$id] = $state[0]' <<<"$APPS")
done

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg now "$NOW" --argjson apps "$APPS" \
  '{schema: 2, updated_at: $now, asset_retention_days: 0, apps: $apps}' \
  >"$NEW_MANIFEST"

DL="../../releases/download/$RELEASE_TAG"
{
  echo "Latest [Morphe](https://morphe.software)-patched APKs, rebuilt automatically whenever an app **or** the patches bundle updates. **Every** compatible patch is enabled (app-specific + universal); APKs are re-signed with a stable per-app key so updates install over previous Morphe builds."
  echo
  echo "| App | Version | Download | Patches | Source | Bundle | Built (UTC) |"
  echo "|-----|---------|:-------:|:------:|:------:|--------|-------------|"
  jq -r --arg dl "$DL" '.apps | to_entries | sort_by(.value.name)[] | .value
         | "| \(.name) | `\(.version_name)` | [⬇ APK](\($dl)/\(.asset)) | \(.patches_enabled) | \(.source // "?") | `\(.patches_version)` | \(.built_at) |"' \
     "$NEW_MANIFEST"
  echo
  echo "Each APK is the unmodified upstream binary (from RuStore or the vendor's own CDN), patched and re-signed. Machine-readable details: [\`manifest.json\`]($DL/manifest.json). Patches: [xob0t/morphe-patches](https://github.com/xob0t/morphe-patches)."
  echo
  echo "<sub>Updated $NOW.</sub>"
} >"$NEW_NOTES"

declare -a NEW_ASSETS=()
declare -a BACKUP_IDS=()
declare -a BACKUP_ORIGINALS=()
MANIFEST_BACKUP_ID=""
MANIFEST_NEW=false
NOTES_TOUCHED=false
COMMITTED=false

rollback() {
  local i current_id
  set +e
  echo "::warning::Publication failed; restoring the previous release."

  if [ "$MANIFEST_NEW" = "true" ]; then
    delete_asset manifest.json
  fi
  if [ -n "$MANIFEST_BACKUP_ID" ]; then
    rename_asset "$MANIFEST_BACKUP_ID" manifest.json
  fi

  for ((i=${#NEW_ASSETS[@]}-1; i>=0; i--)); do
    delete_asset "${NEW_ASSETS[$i]}"
  done
  for ((i=${#BACKUP_IDS[@]}-1; i>=0; i--)); do
    current_id=$(asset_id "${BACKUP_ORIGINALS[$i]}")
    [ -n "$current_id" ] && delete_asset "${BACKUP_ORIGINALS[$i]}"
    rename_asset "${BACKUP_IDS[$i]}" "${BACKUP_ORIGINALS[$i]}"
  done

  if [ "$NOTES_TOUCHED" = "true" ]; then
    gh release edit "$RELEASE_TAG" --title "$OLD_TITLE" --notes-file "$OLD_NOTES" \
      || echo "::warning::Could not restore previous release notes."
  fi
}

finish() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ "$COMMITTED" != "true" ]; then
    rollback
  fi
  exit "$rc"
}
trap finish EXIT

# Replace each public APK only after its workflow candidate has been validated.
for state in "${STATE_FILES[@]}"; do
  asset=$(jq -r '.asset' "$state")
  expected=$(jq -r '.output_sha256' "$state")
  candidate="$PUBLICATIONS_DIR/candidate/$asset"
  existing_id=$(asset_id "$asset")
  if [ -n "$existing_id" ]; then
    backup="backup-${RUN_KEY}-${asset}"
    delete_asset "$backup"
    rename_asset "$existing_id" "$backup"
    BACKUP_IDS+=("$existing_id")
    BACKUP_ORIGINALS+=("$asset")
  fi

  NEW_ASSETS+=("$asset")
  gh release upload "$RELEASE_TAG" "$candidate"
  download_and_verify "$asset" "$expected" "$VERIFY_DIR/$asset"
  echo "publisher: verified public candidate $asset"
done

# Activate all replacements together by swapping manifest.json last.
existing_manifest_id=$(asset_id manifest.json)
if [ -n "$existing_manifest_id" ]; then
  manifest_backup="backup-${RUN_KEY}-manifest.json"
  delete_asset "$manifest_backup"
  rename_asset "$existing_manifest_id" "$manifest_backup"
  MANIFEST_BACKUP_ID="$existing_manifest_id"
fi

MANIFEST_NEW=true
gh release upload "$RELEASE_TAG" "$NEW_MANIFEST"
NEW_MANIFEST_SHA=$(sha256sum "$NEW_MANIFEST" | cut -d' ' -f1)
download_and_verify manifest.json "$NEW_MANIFEST_SHA" "$VERIFY_DIR/manifest.json"

NOTES_TOUCHED=true
gh release edit "$RELEASE_TAG" --title "$TITLE" --notes-file "$NEW_NOTES"
COMMITTED=true

# The new manifest and notes are live. Cleanup is best-effort: a leftover backup
# is untidy but cannot invalidate the activated publication.
KEEP_APKS=$(jq -r '.apps[]?.asset // empty' "$NEW_MANIFEST" | sort -u)
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if ! grep -Fxq "$name" <<<"$KEEP_APKS"; then
    echo "publisher: deleting superseded APK $name"
    delete_asset "$name" || echo "::warning::Could not delete superseded APK $name"
  fi
done < <(
  gh release view "$RELEASE_TAG" --json assets \
    | jq -r '.assets[] | select(.name | endswith(".apk")) | .name'
)

if [ -n "$MANIFEST_BACKUP_ID" ]; then
  gh api --method DELETE "repos/$REPOSITORY/releases/assets/$MANIFEST_BACKUP_ID" --silent \
    || echo "::warning::Could not delete the previous manifest backup."
fi

echo "publisher: activated ${#STATE_FILES[@]} clean-name APK candidate(s)."
