# digitalis

The arm64-to-x86_64 binary translation based on Berberis framework.

Built on **AOSP 16** (API 36).

Upstream AOSP Berberis publishes only a RISC-V backend. Google's own Android
Emulator *Google APIs* x86_64 system images do ship an ARM64 one — they register
`ro.dalvik.vm.native.bridge=libndk_translation.so`, a Berberis build whose symbol
table carries `berberis::intrinsics::Arm64ReadFpcr`, next to
`/system/etc/berberis/cpuinfo.arm64.txt` and `arm64_dyn`/`arm64_exe` binfmt_misc
handlers — but that implementation is closed. It is present in the Google APIs
images from Android 14 (API 34) through **Android 17** (API 37); the plain AOSP
images ship no native bridge at all. Digitalis is an open ARM64 backend for the
public framework.

## Init

```
mkdir digitalis
cd digitalis
repo init -b android17 -u git@github.com:DigitalisX64/manifest.git
```

Pick the branch for the platform you are building:

| Branch | AOSP | What it is |
|---|---|---|
| `android16` | `android16-qpr2-release` | the shipping development branch |
| `android17` | `android17-release` | the AOSP 17 port, **in progress** |
| `android-latest-release` | — | the latest stable Digitalis release |

`android17` brings up a complete AOSP 17 tree, but the translator is not
ported yet: `frameworks/libs/binary_translation` on that branch is still
upstream AOSP 17, which carries no ARM64 backend. It builds an ordinary
AOSP 17 emulator, not a translating one. Use `android16` for anything that
needs to actually run ARM64 apps.

AOSP 17 moved the translator sources under `cpu_emulation/`, and it now ships
its own ARM64 guest scaffolding for Google's closed backend, so the port is a
merge that has to reconcile both -- not a fast-forward.

## Sync code

```
repo sync -c -d --no-tags --force-sync
```

## Build

```
source build/envsetup.sh
lunch sdk_phone64_x86_64_digitalis-trunk_staging-userdebug
m
```

Or use the lunch shortcut (it sources `build/envsetup.sh` for you if needed), then `m`:

```
source digitalis/scripts/lunch-digitalis.sh
m
```

## Run

```
emulator
# And then build and install sample/hellodigitalis with Gradle to test
```

## Binary-only distribution (Docker)

Build the translator as a **binary-only** bundle that other AOSP x86_64 products can
drop in without compiling Berberis from source. The build runs in a reproducible
Docker container whose build identity defaults to `digitalis-build`, and it reuses
the host's existing `out/` so a normal developer never has to rebuild the tree.

```bash
# Build + package the prebuilt bundle (incremental; reuses out/).
digitalis/docker/build-digitalis.sh

# Verify the produced bundle (presence, ELF arch, native-bridge export, checksums).
digitalis/scripts/verify-digitalis-prebuilts.sh
```

The output `digitalis/dist/digitalis-prebuilts/` holds the translator, proxy libs,
ARM64 guest libs, and configs, plus a `digitalis-prebuilts.mk` a consumer product
inherits to enable native bridge. See [`docker/README.md`](docker/README.md) for the
build identity/uid parameters, host-path reuse details, and integration steps.

## Claude Code Integration

This repo includes a `/dispatch` slash command and an automated dispatch script for Claude Code.

### Usage

Inside Claude Code, run the automated multi-cycle dispatch loop:

```
/dispatch Fix STLR root cause
```

Or continue from where the last handoff left off:

```
/dispatch
```

This runs `.claude/scripts/digitalis-dispatch.sh`, which spawns subagents in a loop — each reads the latest handoff, does real work, writes the next handoff, and exits. The loop continues until `STATUS: COMPLETE`.

To run directly from the terminal:

```bash
.claude/scripts/digitalis-dispatch.sh "Implement FRECVTS instruction"
```

## Attribution

Digitalis is a modification of the [Android Open Source Project](https://source.android.com/)
and its [Berberis](https://cs.android.com/android/platform/superproject/main/+/main:frameworks/libs/binary_translation/)
binary-translation framework, © Google LLC, used under the Apache License 2.0.
Android, Berberis, ANGLE and GFXStream are projects and/or trademarks of Google LLC.
Digitalis is not affiliated with, endorsed by, or sponsored by Google.

Arm, AArch64 and NEON are trademarks of Arm Limited. Vulkan and OpenGL ES are
trademarks of the Khronos Group.

The sample apps under `sample/hellodigitalis/` link third-party libraries — among
them Qt, React Native, Lynx, OpenCV, TensorFlow Lite, PyTorch, ONNX Runtime,
FFmpeg, WebRTC, Realm and SQLCipher — each the property of its respective owners
and used under its own license.

Third-party application and product names and packages referenced in the docs and
test tooling are trademarks of their respective owners and appear solely to report
interoperability-testing results; no affiliation or endorsement is implied. No
third-party application is redistributed by this repository — the prebuilt APKs
used for regression testing are not committed.
