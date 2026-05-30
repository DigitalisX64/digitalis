# apkmirror_fetch

Pure-Python tooling that downloads version-pinned `arm64-v8a` APKs from apkmirror.com
into `sample/prebuilts/` for Digitalis translator regression testing. No Java, no
external binaries — only `requests` and `cryptography`.

## Usage

```bash
cd digitalis/scripts
python3 fetch-prebuilt-apks.py --list            # show pinned vs local status
python3 fetch-prebuilt-apks.py                   # fetch/refresh all configured apps
python3 fetch-prebuilt-apks.py com.whatsapp      # fetch one app
python3 fetch-prebuilt-apks.py --force           # ignore the skip-if-current check
python3 fetch-prebuilt-apks.py --no-merge        # skip bundle-only apps
python3 fetch-prebuilt-apks.py --merge native    # native-libs-only bundle merge
python3 fetch-prebuilt-apks.py --dry-run         # decide actions, download nothing
```

Apps and pinned versions live in `digitalis/apkmirror-apps.json`. Update an app by
editing its `version` and re-running.

## What it does

1. Resolves the pinned version's apkmirror variant table and picks a single arm64-v8a
   APK (nodpi preferred), falling back to the arm64-v8a bundle (`.apkm`).
2. For bundles, merges base + arm64-v8a split (+ density/locale splits in `--merge full`)
   into one installable APK entirely in Python: `resources.arsc` table merge, binary
   AndroidManifest split-marker stripping, zipalign, and v1+v2 signing with a generated
   debug key cached in `digitalis/.cache/`. If full-resource merge fails for an app it
   degrades to native-only and warns.
3. Reports a per-app status table and a Google Mobile Services (GMS) dependency section
   — GMS-dependent apps may degrade on the AOSP (no-GMS) emulator.

## Tests

```bash
cd digitalis/scripts && python3 -m pytest apkmirror_fetch/tests -v
```

The `resources.arsc` merge is gated by a parse→serialize byte-identity test, and the v2
signature is checked by recomputing the content digest and verifying the embedded RSA
signature (plus `apksigner verify` when `apksigner` is on PATH).
