# Morphe auto-builds

Automatically rebuilds patched APKs whenever an upstream app **or** the
[`xob0t/morphe-patches`](https://github.com/xob0t/morphe-patches) bundle ships a new
version, using the [Morphe](https://morphe.software) patcher.

All apps publish to a **single rolling [`latest`](../../releases/tag/latest)
release** that always holds the newest patched build of each app. Every build
enables **all** compatible patches — app-specific **and** universal. The patched
APKs are re-signed with a stable per-app key, so updates install over previous
Morphe builds without uninstalling.

> The patch step is the validation gate. App-specific patches list exact known-good
> versions and require every advertised hook or surface to be present. An unlisted
> version is first patched in qualification mode and is never published directly.
> Success opens an append-only target PR, releases a stable patch bundle, and runs
> the normal exact-target build again. Failure opens an issue and leaves the
> published APK unchanged.

## Apps

| App         | Primary source     | Fallback                              |
|-------------|--------------------|---------------------------------------|
| Avito       | RuStore store API  | `avito.st/s/app/apk/avito.apk`        |
| T-Bank      | RuStore store API  | `acdn.t-bank-app.ru/download_apk/tbank_app.apk` |
| Ozon        | RuStore store API  | — (no official direct URL)            |
| Wildberries | RuStore store API  | — (no official direct URL)            |

All builds land in the single `latest` release under immutable, content-addressed
names such as `<app>-<version>-morphe-<sha12>.apk`.

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
3. **Patch or qualify** — exact listed targets run normally. An unlisted
   `versionName` + `versionCode` runs once with `--force`, but publication is disabled.
   In both paths, the result report must contain exactly the selected patch multiset;
   a failed, missing, or unexpected patch fails the job.
4. **Promote** — successful qualification is attested, then a narrowly scoped GitHub
   App opens one append-only target PR directly against `morphe-patches/main`. Required
   checks verify the attestation, author, changed file, and target list before
   auto-squash-merge.
5. **Release and rebuild** — the merged target produces a stable patch release and
   dispatches this workflow. The ordinary, non-forced exact-target build is the final
   authoritative check; source drift since qualification is rechecked here.
6. **Publish transactionally** — sign with the app's stable keystore, upload an
   immutable APK, download it again to verify its digest, and only then update
   **`manifest.json`**, which is the active publication pointer. If any step fails,
   the previous manifest entry and APK remain available. Unreferenced APKs are
   removed only on later runs after `asset_retention_days` (seven days by default).

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

### Target-promotion GitHub App

Install one GitHub App on both `xob0t/morphe-autobuilds` and
`xob0t/morphe-patches`, with repository **Contents: read/write** and **Pull
requests: read/write**. Add its App ID and private key to both repositories as
`PROMOTION_APP_ID` and `PROMOTION_APP_PRIVATE_KEY`.

On `morphe-patches`:

- set the repository variable `PROMOTION_BOT_LOGIN` to the App's exact bot login
  (for example, `my-app[bot]`);
- enable squash merging and auto-merge;
- protect `main` and require the `Build` pull-request check before merging;
- add this App to the `main` ruleset bypass list with **Always allow**.
  Semantic-release authenticates as the App for its generated release commit; target
  promotion still uses ordinary `--auto` merging and therefore waits for `Build`.

The App token exists only in dedicated promotion and release/dispatch steps. The
repository-owned target editing script runs with that token removed from its
environment.

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

## Build on a new patches release

The patches release workflow dispatches this workflow immediately after every stable
release. The daily cron remains a reconciliation fallback if dispatch or promotion
fails.

## Adding an app

Add an entry to `config/apps.json` (id, package, source url + UA, `keystore_secret`,
optional `disable` list) and add the keystore secret. The app must have patches in
the configured `patches_repo` bundle.

## Disclaimer

For interoperability/personal use. APKs are unmodified upstream binaries patched and
re-signed; all trademarks belong to their owners.
