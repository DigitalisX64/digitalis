# Building and deploying a fixed emulator

Some Digitalis failures are not Digitalis failures. The emulator under
`prebuilts/android-emulator/` is a released binary that lags the emulator's own
source tree, so a host-side graphics fix that has already landed upstream is
still absent from the binary you run. When that happens the symptom is
distinctive and alarming: the **emulator process itself dies**, taking every app
with it, which no guest code should be able to cause.

This page covers the one such fix Digitalis currently needs, how to tell it
apart from a translator bug, and how to build and deploy an emulator that has
it.

## The symptom

The emulator aborts — the host process exits, `adb devices` goes empty — and the
emulator's own stdout ends with:

```
reservedunmarshal_extension_struct, Unhandled Vulkan structure type
VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT [1000237000], aborting.
```

It reproduces whenever an app queries `VK_EXT_memory_budget`. Chromium-based
apps do it as a matter of course, so any browser or WebView-heavy APK triggers
it within seconds of its GPU process starting; games hit it too.

The fix is host-side: `clampMemoryBudgetToGuestHeapSizes` in gfxstream's
`vk_emulated_physical_device_memory.cpp` clamps the reported budget to the
guest's heap sizes instead of letting the decoder fall over the struct. It is
merged upstream in the emulator source, and is not in the prebuilt binary.

## Confirming it is the emulator and not us

Do this before spending any time on the translator — the whole point of the
signature above is that it is *not* ours, and it is worth proving rather than
assuming:

1. **Who died?** A translator or guest fault leaves `Fatal signal`,
   `Undefined arm64 instruction`, or `FATAL EXCEPTION` in logcat and the
   emulator keeps running. This one kills the emulator process (exit 134) and
   leaves nothing in logcat.
2. **Does it predate the change you are testing?** Deploy the previous
   `libberberis_arm64.so` and run the same app. If it still aborts, the change
   under test is exonerated.
3. **Does it survive without the host Vulkan decoder?** Relaunch with
   `-gpu swiftshader_indirect` and run the app again. If it now runs and
   renders, the guest code translates correctly and the abort is entirely in
   the host's Vulkan decode path.

Step 3 is the decisive one: it separates "the app is broken under translation"
from "the host cannot decode what the app sends".

## Deploying a fixed emulator

### 1. Get the emulator source

The emulator is a separate checkout from AOSP, on the `emu-main-dev` branch,
which carries the merged fix:

```bash
mkdir emu-main-dev && cd emu-main-dev
repo init -u https://android.googlesource.com/platform/manifest -b emu-main-dev
repo sync -c -j"$(nproc)"
```

It is large; a full sync takes a while and needs tens of GB.

### 2. Build and deploy

```bash
digitalis/scripts/deploy-emulator.sh --emu-root /path/to/emu-main-dev
```

The script builds the emulator's host package and overlays it onto this tree's
`prebuilts/android-emulator/<host>/`. Both directories are parameters: it
deploys into the tree it is checked out in unless `--aosp-root` says otherwise,
so it works from any checkout without editing.

```bash
# deploy into a different Digitalis/AOSP tree
digitalis/scripts/deploy-emulator.sh --emu-root <emu-src> --aosp-root <other-tree>

# re-deploy without rebuilding (reuses external/qemu/objs)
digitalis/scripts/deploy-emulator.sh --emu-root <emu-src> --no-build

# undo — restore the original prebuilt
digitalis/scripts/deploy-emulator.sh --restore
```

The first deploy copies the untouched prebuilt to
`prebuilts/android-emulator/<host>.bak.pre-emu-deploy` and never overwrites that
backup afterwards, so `--restore` always returns you to the released binary no
matter how many times you redeploy.

### 3. Verify

The script fails rather than deploying if the fix is missing, and checks the
result after copying:

- the `clampMemoryBudgetToGuestHeapSizes` symbol is present in the freshly
  built backend (looked up in the unstripped twin, since gfxstream builds with
  hidden visibility);
- the stripped and unstripped backends share a BuildID, so a stale
  `distribution/` cannot be shipped;
- the deployed backend matches the built one by md5;
- every `android_*` / `emugl*` / `goldfish_*` import of `qemu-system-x86_64`
  resolves inside the package;
- `emulator -version` runs.

Then confirm the behaviour directly: launch a Chromium-based APK on the default
GPU and check that the emulator survives and its log contains no `aborting`
line.

## Why the whole package, not just the one library

Copying `libgfxstream_backend.so` alone does not work, for two reasons:

- The emulator ships a **fat** backend that rolls in the android-emu host layer.
  An AOSP tree's own Soong `out/host` build is the **slim** Cuttlefish flavor
  and is not a drop-in for the goldfish/ranchu emulator.
- Emulator releases are not ABI-stable across versions. A newer backend can drop
  exports the target's `qemu-system-*` binaries import — for example
  `emuglConfig_current_renderer_supports_snapshot` — so a single-library swap
  fails at load time. The interdependent set has to move together, which is why
  the script overlays the whole built package.

`source.properties` and `android-info.txt` are deliberately left alone so the
package keeps its original SDK identity for tooling; the binaries still
self-report their real version through `emulator -version`.

## Consequences for the gates

While an unfixed emulator is in place, any APK that queries
`VK_EXT_memory_budget` kills the run — including runs it is not the subject of.
Two practical notes:

- `test-prebuilts.sh` walks its APKs in one pass, so an abort partway through
  ends the gate and every later APK goes unchecked. A partial result is not a
  pass; re-run it after deploying a fixed emulator.
- An affected app restarts itself. Background processes come back after a crash,
  hit the same abort, and take the emulator down again with nobody having
  launched anything. If you need a long undisturbed run (a benchmark sweep, say)
  on an unfixed emulator, uninstall the app from the device first — leaving the
  APK in `sample/prebuilts/` so the gate still covers it.
