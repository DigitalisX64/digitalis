# apkmirror_fetch

Tooling that downloads version-pinned `arm64-v8a` APKs from apkmirror.com into
`sample/prebuilts/` for Digitalis translator regression testing. Single-APK downloads
and the `--merge native` path are pure Python (`requests` + `cryptography` only). The
default split-bundle merge (`--merge full`) additionally shells out to
[APKEditor](https://github.com/REAndroid/APKEditor) (Java 8+), a pinned release jar
auto-vendored into `digitalis/.cache/tools/` on first use (sha256-verified).

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
2. For bundles, merges ALL splits (base + every config/density/locale split + every
   feature module) into one installable universal APK. `--merge full` (default) uses
   APKEditor's `m` command for a correct split resource-table merge — base, density,
   locale and feature-module tables are fused with proper string-pool/offset remapping
   (the earlier pure-Python `arsc.merge` only handled the classic non-sparse encoding
   and ignored feature modules, so it silently dropped split resources and apps crashed
   with `Resources$NotFoundException`). Foreign-ABI native libs are stripped to keep the
   artifact arm64-v8a-only, then it is re-signed (zipalign + v1+v2) with the generated
   debug key cached in `digitalis/.cache/`. `--merge native` is the dependency-free
   pure-Python base+arm64-lib merge (no per-split resources). If APKEditor is
   unavailable in `full` mode (no Java / jar fetch fails), the merge degrades to the
   native path and reports `native-fallback` (its resource table is base-only and the
   app may crash — install Java and re-run).
3. Reports a per-app status table and a Google Mobile Services (GMS) dependency section
   — GMS-dependent apps may degrade on the AOSP (no-GMS) emulator.

## Tests

```bash
cd digitalis/scripts && python3 -m pytest apkmirror_fetch/tests -v
```

The `resources.arsc` merge is gated by a parse→serialize byte-identity test, and the v2
signature is checked by recomputing the content digest and verifying the embedded RSA
signature (plus `apksigner verify` when `apksigner` is on PATH).
