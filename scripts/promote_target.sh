#!/usr/bin/env bash
#
# Create one idempotent direct-to-main target-promotion PR per qualification file.
# The GitHub App token is kept out of the repository-owned bump script's environment.
set -euo pipefail

EVIDENCE_DIR="${EVIDENCE_DIR:?EVIDENCE_DIR required}"
PATCHES_REPO="${PATCHES_REPO:?PATCHES_REPO required}"
AUTOBUILD_REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
PROMOTION_TOKEN="${GH_TOKEN:?GH_TOKEN required}"

shopt -s nullglob
evidence_files=("$EVIDENCE_DIR"/qualification-*.json)
shopt -u nullglob
if [ "${#evidence_files[@]}" -eq 0 ]; then
  echo "No qualified targets to promote."
  exit 0
fi

# Promotions go directly to main, so require the release backmerge to have left dev
# containing main. This avoids creating a stable target that the development branch
# would later drop or conflict with.
sync_status=$(GH_TOKEN="$PROMOTION_TOKEN" gh api \
  "repos/$PATCHES_REPO/compare/main...dev" --jq '.status')
if [ "$sync_status" != "ahead" ] && [ "$sync_status" != "identical" ]; then
  echo "::error::$PATCHES_REPO dev does not contain main (compare status: $sync_status)." >&2
  exit 1
fi

pending_pr=$(GH_TOKEN="$PROMOTION_TOKEN" gh pr list \
  --repo "$PATCHES_REPO" \
  --state open \
  --json headRefName,url \
  --jq '[.[] | select(.headRefName | startswith("autobuild/target-"))][0].url // empty')
if [ -n "$pending_pr" ]; then
  echo "A target promotion is already pending: $pending_pr"
  exit 0
fi

for evidence in "${evidence_files[@]}"; do
  gh attestation verify "$evidence" --repo "$AUTOBUILD_REPO"

  app=$(jq -er '.app' "$evidence")
  package=$(jq -er '.package' "$evidence")
  version=$(jq -er '.version_name' "$evidence")
  version_code=$(jq -er '.version_code' "$evidence")
  apk_sha=$(jq -er '.apk_sha256' "$evidence")
  sha_short=${apk_sha:0:12}
  branch="autobuild/target-${app}-${version_code}-${sha_short}"
  title="fix(${app}): support version ${version}"

  existing_pr=$(GH_TOKEN="$PROMOTION_TOKEN" gh pr list \
    --repo "$PATCHES_REPO" \
    --state all \
    --head "$branch" \
    --json number,url,state \
    --jq '.[0].url // empty')
  if [ -n "$existing_pr" ]; then
    echo "Promotion already exists: $existing_pr"
    continue
  fi

  work="${RUNNER_TEMP:-/tmp}/promotion-${app}-${version_code}"
  mkdir -p "$work"
  repo_dir="$work/repo"
  git clone --depth 1 --branch main "https://github.com/${PATCHES_REPO}.git" "$repo_dir"

  (
    cd "$repo_dir"
    unset GH_TOKEN
    python3 .github/scripts/append_app_target.py \
      --app "$app" \
      --package "$package" \
      --version "$version" \
      --version-code "$version_code"
  )
  if git -C "$repo_dir" diff --quiet; then
    echo "$app $version ($version_code) is already present on main."
    continue
  fi

  git -C "$repo_dir" switch -c "$branch"
  git -C "$repo_dir" config user.name "morphe-autobuild[bot]"
  git -C "$repo_dir" config user.email "morphe-autobuild[bot]@users.noreply.github.com"
  git -C "$repo_dir" add -- \
    "patches/src/main/kotlin/app/${app}/patches/shared/Constants.kt"
  git -C "$repo_dir" commit -m "$title"

  GH_TOKEN="$PROMOTION_TOKEN" gh auth setup-git
  git -C "$repo_dir" push "https://github.com/${PATCHES_REPO}.git" "$branch"

  evidence_b64=$(base64 -w0 "$evidence")
  run_url=$(jq -er '.run_url' "$evidence")
  source=$(jq -er '.source' "$evidence")
  body=$(cat <<EOF
Target qualification succeeded for **${app} ${version}** (${version_code}).

- Package: \`${package}\`
- Source: \`${source}\`
- APK SHA-256: \`${apk_sha}\`
- Qualification run: ${run_url}

This PR appends one exact, non-experimental target. Required checks verify the
attested evidence and the append-only merge result before automatic stable release.

<!-- qualification-evidence-base64: ${evidence_b64} -->
EOF
)
  pr_url=$(GH_TOKEN="$PROMOTION_TOKEN" gh pr create \
    --repo "$PATCHES_REPO" \
    --base main \
    --head "$branch" \
    --title "$title" \
    --body "$body")
  GH_TOKEN="$PROMOTION_TOKEN" gh pr merge "$pr_url" \
    --auto \
    --squash \
    --subject "$title" \
    --body "Qualified automatically by ${run_url}."
  echo "Created target promotion: $pr_url"
  # Serialize promotions through stable release + main→dev backmerge. Any other
  # qualified app is rediscovered by the next scheduled reconciliation run.
  exit 0
done
