# Morphe auto-builds

Automatically rebuilds patched APKs whenever an upstream app ships a new version,
using the [Morphe](https://morphe.software) patcher and the
[`xob0t/morphe-patches`](https://github.com/xob0t/morphe-patches) bundle.

Each app has a rolling **`<app>-latest`** release that always holds the newest
patched build. The patched APKs are re-signed with a stable per-app key, so updates
install over previous Morphe builds without uninstalling.

> The patch step **is** the regression test: if an app update breaks a patch
> fingerprint, `morphe-cli` exits non-zero, the build fails, and an issue is opened.

## Apps

| App     | Source                                             | Release tag    |
|---------|----------------------------------------------------|----------------|
| Avito   | `https://www.avito.st/s/app/apk/avito.apk`         | `avito-latest` |
| T-Bank  | `https://acdn.t-bank-app.ru/download_apk/tbank_app.apk` | `tbank-latest` |

Ozon and Wildberries have no official "latest APK" URL; they can be added once an
alternative source (APKMirror / APKPure / RuStore) is wired into `config/apps.json`.

## How it works

`.github/workflows/build.yml` runs daily (06:00 UTC) and on manual dispatch. Per app:

1. **Change check** — `HEAD` the source URL; if its `ETag` (T-Bank) or
   `Content-Length` (Avito) matches the value recorded in the current release, skip
   without downloading.
2. **Download & version** — fetch the APK (browser User-Agent) and read
   `versionCode`/`versionName` with the runner's `aapt2`. Skip if not newer.
3. **Patch** — download the latest `morphe-cli` and the latest stable
   `patches-*.mpp`, then `morphe-cli patch …`. Failure here fails the job and opens
   a `[app] patch failing` issue.
4. **Sign** — signed by `morphe-cli` with the app's stable keystore.
5. **Publish** — create/update `<app>-latest`, upload the APK, and record
   `versionCode` + `ETag`/`Content-Length` for the next run's change check.

Patch selection is empty (`patch_args: []`) by default, meaning **morphe-cli's
default set** — this auto-includes new patches as the bundle evolves. Override per
app in `config/apps.json` with `--enable=Name` / `--disable=Name`.

## Required secrets

Each app needs its signing keystore as a base64 secret (referenced by
`keystore_secret` in `config/apps.json`):

| Secret               | App    |
|----------------------|--------|
| `AVITO_KEYSTORE_B64` | Avito  |
| `TBANK_KEYSTORE_B64` | T-Bank |

Create from a keystore file:

```bash
base64 -w0 avito-morphe.keystore | gh secret set AVITO_KEYSTORE_B64
base64 -w0 tbank-morphe.keystore | gh secret set TBANK_KEYSTORE_B64
```

The keystore is morphe-cli's own format; no password is needed (morphe-cli signs
with `--keystore` alone). Keep these keys stable so update installs don't break.

## Manual run

Actions → **Auto-build patched APKs** → *Run workflow*:

- `app` — an id from `config/apps.json`, or `all` (default).
- `force` — build even if the upstream version is unchanged.

## Adding an app

Add an entry to `config/apps.json` (id, package, source url + UA, `release_tag`,
`keystore_secret`, optional `patch_args`) and add the keystore secret. The app must
have patches in the configured `patches_repo` bundle.

## Disclaimer

For interoperability/personal use. APKs are unmodified upstream binaries patched and
re-signed; all trademarks belong to their owners.
