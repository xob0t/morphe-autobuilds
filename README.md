# Morphe auto-builds

Automatically rebuilds patched APKs whenever an upstream app ships a new version,
using the [Morphe](https://morphe.software) patcher and the
[`xob0t/morphe-patches`](https://github.com/xob0t/morphe-patches) bundle.

All apps publish to a **single rolling [`latest`](../../releases/tag/latest)
release** that always holds the newest patched build of each app. Every build
enables **all** compatible patches — app-specific **and** universal. The patched
APKs are re-signed with a stable per-app key, so updates install over previous
Morphe builds without uninstalling.

> The patch step **is** the regression test: if an app update breaks a patch
> fingerprint, `morphe-cli` exits non-zero, the build fails, and an issue is opened.

## Apps

| App         | Source                                               |
|-------------|------------------------------------------------------|
| Avito       | direct: `avito.st/s/app/apk/avito.apk`               |
| T-Bank      | direct: `acdn.t-bank-app.ru/download_apk/tbank_app.apk` |
| Ozon        | RuStore store API (no official direct URL)           |
| Wildberries | RuStore store API (no official direct URL)           |

All builds land in the single `latest` release as `<app>-<version>-morphe.apk`.

**Sources.** Each app has an ordered `sources` list, tried in turn until one resolves
an APK — so a broken store *or* a broken vendor URL doesn't stop the build. RuStore is
primary everywhere; Avito and T-Bank add their official direct URL as a fallback.

Source types:
- `rustore` — the official RU store's API: `overallInfo/<package>` → appId, then
  `v2/download-link` → a single non-split APK URL **and** the upstream `versionCode`.
  The versionCode is returned before downloading, so unchanged apps are skipped
  without fetching the (200–400 MB) APK. No auth/scraping; always the current version.
- `direct` — `url` is the APK (the vendor's own CDN); validated with a HEAD before use,
  change detected via `ETag`/`Content-Length`.

## How it works

`.github/workflows/build.yml` runs daily (06:00 UTC), on manual dispatch, and on a
`repository_dispatch` of type `patches-released`. Per app it rebuilds when **either**
the upstream app version **or** the Morphe patches bundle changed since its last build:

1. **Change check** — rebuild if the bundle version differs from the app's last build
   (`patches_version` in the manifest). Otherwise check the source: RuStore returns the
   `versionCode` up front; for direct URLs, `HEAD` and compare `ETag`/`Content-Length`.
   If nothing changed, skip without downloading.
2. **Download & version** — fetch the APK (browser User-Agent) and read
   `versionCode`/`versionName` with the runner's `aapt2`. Skip if not newer.
3. **Patch** — download the latest `morphe-cli` and the latest stable
   `patches-*.mpp`, then `morphe-cli patch …`. Failure here fails the job and opens
   a `[app] patch failing` issue.
4. **Sign** — signed by `morphe-cli` with the app's stable keystore.
5. **Publish** — upload the APK to the shared `latest` release (replacing the app's
   previous APK). Each app's build state is passed as a workflow artifact to a final
   job that merges them into a single **`manifest.json`** on the release and refreshes
   the notes. So the release holds only the APKs + one `manifest.json` (per-app
   version, versionCode, source, patch count, build time).

**Patch selection: everything.** Each build runs `list-patches -f <package>` to get
every compatible patch (app-specific + universal) and enables them all with
`--exclusive --enable=…`. This is self-maintaining — new patches are picked up
automatically. To keep a specific patch off for one app, add its name to that app's
`disable` array in `config/apps.json`.

## Required secrets

Each app needs its signing keystore as a base64 secret (referenced by
`keystore_secret` in `config/apps.json`):

| Secret               | App         |
|----------------------|-------------|
| `AVITO_KEYSTORE_B64` | Avito       |
| `TBANK_KEYSTORE_B64` | T-Bank      |
| `OZON_KEYSTORE_B64`  | Ozon        |
| `WB_KEYSTORE_B64`    | Wildberries |

Create from a keystore file:

```bash
base64 -w0 avito-morphe.keystore | gh secret set AVITO_KEYSTORE_B64
base64 -w0 tbank-morphe.keystore | gh secret set TBANK_KEYSTORE_B64
```

The keystore is morphe-cli's own format; no password is needed (morphe-cli signs
with `--keystore` alone). Keep these keys stable so update installs don't break.

### Optional: file failures on the patches repo

When a build fails because a patch went stale against a new app version, an issue is
opened naming the app, version and failed patch. By default it's filed on **this**
repo. To file it on the **patches** repo instead (where the fix belongs), add a PAT
with `issues:write` on `patches_repo` as the secret **`PATCHES_REPO_TOKEN`**. Without
it, reporting falls back to this repo. Issues are de-duplicated per app+version.

## Manual run

Actions → **Auto-build patched APKs** → *Run workflow*:

- `app` — an id from `config/apps.json`, or `all` (default).
- `force` — build even if the upstream version is unchanged.

## Build on a new patches release (optional, immediate)

The daily cron already picks up a new patches bundle within 24h. To rebuild the
moment a patches release ships, have the patches repo dispatch this workflow — add a
step to its release workflow (needs a PAT with `actions:write`/`contents:write` here):

```bash
gh api repos/<owner>/morphe-autobuilds/dispatches \
  -f event_type=patches-released
```

## Adding an app

Add an entry to `config/apps.json` (id, package, source url + UA, `keystore_secret`,
optional `disable` list) and add the keystore secret. The app must have patches in
the configured `patches_repo` bundle.

## Disclaimer

For interoperability/personal use. APKs are unmodified upstream binaries patched and
re-signed; all trademarks belong to their owners.
