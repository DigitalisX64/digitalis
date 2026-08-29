# Integrating Digitalis into an AOSP 16 product

How to add ARM64-to-x86_64 translation to your own AOSP 16 (API 36) based
project — an emulator image, an x86_64 PC/tablet, or any other x86_64 target.
Digitalis is wired into a product through the stock Android NativeBridge
mechanism, so integration is three small pieces of configuration plus two
source projects; nothing in the core platform is patched.

There are two routes:

- **[Source integration](#source-integration)** — add the Digitalis source
  projects to your manifest and let your product build them. This is what the
  reference emulator product does, and what you want if you build your image
  from source anyway.
- **[Binary integration](#binary-integration)** — overlay a prebuilt bundle of
  the translator artifacts onto an image built without the Digitalis sources.
  Useful when you consume AOSP as prebuilts or cannot add repos.

Both routes end at the same [verification checklist](#verifying-the-integration).

## What integration actually consists of

Android's runtime already knows how to run a "foreign" ABI through a native
bridge: the zygote consults `ro.dalvik.vm.isa.<guest>` and
`ro.dalvik.vm.native.bridge`, the package manager accepts APKs for any ABI in
the derived `ro.product.cpu.abilist`, and the linker consults
`/system/etc/ld.config.<guest>.txt` for guest namespaces. Digitalis plugs into
those seams:

| Piece | What it does |
|---|---|
| `libberberis_arm64.so` | The NativeBridge implementation: loader hooks, the three-tier translator (interpreter, lite JIT, heavy optimizer), syscall emulation |
| Guest libraries (`/system/lib64/arm64/`, `/system/bin/arm64/`) | Real ARM64 builds of bionic, `linker64`, `app_process64`, and the NDK surface, produced by the platform's `native_bridge` arch support |
| Proxy libraries (`libberberis_proxy_*`) | The guest↔host boundary: marshal each NDK call (libc, libm, EGL/GLES, Vulkan, AAudio, camera, binder, media, …) from guest ARM64 to the host implementation |
| `ld.config.arm64.txt`, `berberis.rc`, binfmt_misc entries | Guest linker namespaces, init setup, and standalone-executable support |

## Source integration

### 1. Manifest: two projects (plus the reference device, optionally)

Digitalis replaces AOSP's `frameworks/libs/binary_translation` (upstream
Berberis is RISC-V-only; the Digitalis fork adds the entire ARM64 backend) and
uses the stock `frameworks/libs/native_bridge_support` from the same AOSP 16
branch. A minimal local-manifest overlay:

```xml
<manifest>
  <remote name="digitalis" fetch="git@github.com:DigitalisX64"
          revision="android-latest-release" />

  <remove-project path="frameworks/libs/binary_translation"
                  name="platform/frameworks/libs/binary_translation" />
  <project path="frameworks/libs/binary_translation"
           name="platform_frameworks_libs_binary_translation" remote="digitalis" />
  <!-- frameworks/libs/native_bridge_support stays the stock AOSP project. -->
</manifest>
```

The reference tree also carries `device_generic_goldfish` (the emulator product
described below) and `sample_hello_digitalis` (the 150+-module integration test
suite); take them if they are useful to your project, but neither is required
to integrate the translator itself.

### 2. Board config: declare the native-bridge architecture

In your target's `BoardConfig.mk`, next to the existing x86_64 arch
definitions:

```makefile
TARGET_NATIVE_BRIDGE_ARCH := arm64
TARGET_NATIVE_BRIDGE_ARCH_VARIANT := armv8-a
TARGET_NATIVE_BRIDGE_CPU_VARIANT := generic
TARGET_NATIVE_BRIDGE_ABI := arm64-v8a
```

This is what makes Soong build the `native_bridge` flavor of bionic and the
NDK libraries (the guest ARM64 world under `/system/lib64/arm64/`), and what
appends `arm64-v8a` to the image's advertised ABI list so the package manager
will install ARM64-only APKs.

### 3. Product config: one inherit

In your product makefile:

```makefile
$(call inherit-product, frameworks/libs/binary_translation/enable_arm64_to_x86_64.mk)
```

That single inherit does the rest ([`enable_arm64_to_x86_64.mk`](../../frameworks/libs/binary_translation/enable_arm64_to_x86_64.mk)):

- adds `BERBERIS_PRODUCT_PACKAGES_ARM64_TO_X86_64` to `PRODUCT_PACKAGES` — the
  translator, all 21 proxy libraries, the prebuilt guest configs, the
  binfmt_misc program runners, and the guest-library packages;
- sets the runtime properties:
  `ro.dalvik.vm.native.bridge=libberberis_arm64.so`,
  `ro.dalvik.vm.isa.arm64=x86_64`, `ro.enable.native.bridge.exec=1`;
- registers the required Soong namespace and artifact-path allowlist entries;
- selects the arm64_to_x86_64 translation flavor via soong_config.

The package and artifact lists live in
[`berberis_config.mk`](../../frameworks/libs/binary_translation/berberis_config.mk)
— that file is the single source of truth for what a Digitalis image ships.

### 4a. Emulator targets

The reference product is
[`sdk_phone64_x86_64_digitalis.mk`](../../device/generic/goldfish/64bitonly/product/sdk_phone64_x86_64_digitalis.mk):
the stock `sdk_phone64_x86_64` emulator product plus the inherit above, and it
is worth reading as the worked example. Two emulator-specific choices it makes,
both optional but recommended:

- **`ro.hardware.egl=angle`** — GLES is implemented by ANGLE on top of Vulkan
  in-guest, so only Vulkan crosses to the host (via gfxstream's VkDecoder).
  This yields GLES 3.2 and correct MSAA without touching gfxstream's GLES
  path; pair it with `ro.opengles.version=196610`.
- **A larger data partition** in `config.ini` — prebuilt ARM64 apps and their
  asset downloads are large.

Two emulator-binary caveats that are *not* part of your image but will bite
integration testing: the released emulator prebuilts abort on
`VK_EXT_memory_budget` queries and clamp every guest Vulkan heap to 2 GB.
Both are fixed in current emulator sources; see
[`emulator-gfxstream-deploy.md`](emulator-gfxstream-deploy.md) for symptoms,
proof-it-is-not-the-translator steps, and a deploy script.

### 4b. Real devices and other x86_64 targets

Nothing in steps 1–3 is emulator-specific: the same board-config block and
product inherit apply to any x86_64 device product (a PC image, an x86 tablet,
a Chromebook-style target, a cloud Android instance). Differences to be aware
of:

- **Graphics go to your real driver.** The proxy `libvulkan` forwards guest
  Vulkan calls to whatever Vulkan ICD your device ships; gfxstream is an
  emulator component and is not involved. The ANGLE property choice is yours:
  if your device has a native GLES driver you may keep it; ANGLE-on-Vulkan is
  still a good default for conformance if your Vulkan driver is solid.
- **CPU features matter.** The translator's JIT uses host SSE4.2/AES/PCLMUL
  paths when present and falls back to the interpreter for a few
  host-feature-gated instruction groups when not. Any x86-64-v2+ CPU is fine;
  performance is best with AVX2-class hardware.
- **Memory.** Translation adds a JIT code cache and guest address-space
  bookkeeping per app. 4 GB RAM is a workable floor for app testing; give the
  device what you would give it for the equivalent native workload plus
  headroom.
- **SELinux.** Digitalis ships its policy with the packages above; building
  the product from source integrates it. If your target carries a hardened
  downstream policy, check `adb logcat -b events -s avc` on first boot for
  denials against `berberis`/native-bridge domains.

### Build

```bash
source build/envsetup.sh
lunch <your_product>-trunk_staging-userdebug
m
```

For the reference emulator product that is
`lunch sdk_phone64_x86_64_digitalis-trunk_staging-userdebug`.

## Binary integration

When you cannot add source projects, integrate the prebuilt bundle:

```bash
digitalis/scripts/build-and-package-prebuilts.sh          # produces digitalis/dist/digitalis-prebuilts-<date>-<sha>.tar.gz
digitalis/scripts/verify-digitalis-prebuilts.sh           # sanity-checks the bundle
```

The bundle contains exactly `BERBERIS_DISTRIBUTION_ARTIFACTS_ARM64` (parsed
from `berberis_config.mk`, never hardcoded): `libberberis_arm64.so`, the proxy
libraries, `system/bin/arm64/` + `system/lib64/arm64/` guest worlds,
`ld.config.arm64.txt`, `berberis.rc`, and the binfmt_misc entries, plus a
`MANIFEST.txt` stamping the source commits. Overlay it onto your image's
`/system`, and set the three properties from step 3 in your product (they
cannot be pushed at runtime — `ro.*` properties are write-once and the zygote
reads them at boot). Your image must still have been built with the
native-bridge board config from step 2, since the guest bionic variants and
ABI list derivation happen at image build time.

A containerized build environment for producing the bundle reproducibly is
described in the repo's Docker notes (`digitalis/docker/`), which reuse a host
`out/` tree via `ANDROID_BUILD_TOP`.

## Verifying the integration

In rough order of increasing depth — stop at the first failure and fix before
moving on:

1. **Properties.** `adb shell getprop ro.dalvik.vm.native.bridge` →
   `libberberis_arm64.so`; `getprop ro.dalvik.vm.isa.arm64` → `x86_64`;
   `getprop ro.product.cpu.abilist` includes `arm64-v8a`.
2. **Files.** `/system/lib64/libberberis_arm64.so` exists (host lib — it must
   NOT also be copied into `/system/lib64/arm64/`, which is the guest
   directory); `/system/bin/arm64/linker64` and `/system/lib64/arm64/libc.so`
   exist (guest world); `/system/etc/ld.config.arm64.txt` exists.
3. **Install.** `adb install` an ARM64-only APK (any module from
   `sample/hellodigitalis` — e.g. `hello-jni`). An integration miss shows up
   here as `INSTALL_FAILED_NO_MATCHING_ABIS`.
4. **Run + the translation oracle.** Launch the app, then check
   `adb shell cat /proc/$(adb shell pidof <pkg>)/maps | grep -c memfd:exec`.
   A nonzero count is the positive proof that Berberis's JIT cache is in the
   process and translation is actually executing — an app that "works" with
   zero `memfd:exec` mappings is running some other ABI.
5. **The suite.** If you carry `sample/hellodigitalis`,
   `.claude/scripts/test-samples.sh` runs every module with crash detection;
   the ARM-extension probes (`hello-neon`, `hello-lse`, `hello-fp16`, …) are
   the fastest way to smoke-test instruction coverage on a new target.
6. **Real apps.** Drop ARM64-only third-party APKs into `sample/prebuilts/`
   and run `.claude/scripts/test-prebuilts.sh`.

## Runtime flags (`ro.berberis.flags`)

The translator reads a comma-separated list of tuning flags from the
`ro.berberis.flags` system property (or, off-device, the `BERBERIS_FLAGS`
environment variable). Unknown tokens are logged and ignored. The list is read
once, early, so set the property in your product's `.prop` (or export the env
var before launch) rather than expecting a runtime change to take effect. The
authoritative flag set is the `ConfigFlag` enum in
`base/include/berberis/base/config_globals.h`; the ones an integrator is likely
to touch:

- **`glibc-host-thread-id-handoff`** — set this **only** when the translator
  runs on a **glibc host under a bionic compatibility layer** (a non-Android
  runtime such as Drion, not the stock Digitalis emulator or an Android device).
  When a new guest thread's static TLS is seeded, Berberis normally copies the
  host's `TLS_SLOT_THREAD_ID` (`%fs+0x08`) into the guest's thread-id slot,
  which is correct on a bionic host where that slot holds a
  `pthread_internal_t*`. On glibc that slot is the DTV pointer, so the guest
  would start with garbage where bionic expects the pthread record. With this
  flag on, `GuestThread::InitStaticTls` instead reads the id from
  `TLS_SLOT_NATIVE_BRIDGE_GUEST_STATE`, where such a host seeds a synthetic
  bionic pthread record before the thread starts. **Never set it on a real
  bionic host** — it is off by default, and with it off the generated code is
  byte-identical to before (the ordinary `TLS_SLOT_THREAD_ID` load).
- **`disable-ir-check`** — skip the MachineIR validation passes in the
  optimizing backend. The checks stay on by default (and in host tests); a
  production image can ship this to drop the per-translation validation cost.

## Version compatibility

Digitalis tracks AOSP 16 (API 36). The guest libraries are built from the same
platform sources as the host image, so mixing a Digitalis bundle from one
platform release into an image of another is unsupported — rebuild (or
re-bundle) against your tree. For the translator's own behavior and coverage,
see [`how-it-works.md`](how-it-works.md) and
[`unsupported-opcodes.md`](unsupported-opcodes.md).
