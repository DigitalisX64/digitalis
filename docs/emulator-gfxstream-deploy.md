# Building and deploying a fixed emulator

Some Digitalis failures are not Digitalis failures. The emulator under
`prebuilts/android-emulator/` is a released binary that lags the emulator's own
source tree, so a host-side graphics fix that has already landed upstream is
still absent from the binary you run.

This page covers the two such fixes Digitalis currently needs — one that kills
the emulator process, one that silently starves apps of Vulkan memory — how to
tell each apart from a translator bug, and how to build and deploy an emulator
that has both.

## Symptom 1: the emulator process aborts on `VK_EXT_memory_budget`

The emulator's own stdout ends with:

```
reservedunmarshal_extension_struct, Unhandled Vulkan structure type
VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT [1000237000], aborting.
```

The emulator process exits, `adb devices` goes empty, and it reproduces
whenever an app queries `VK_EXT_memory_budget`. Chromium-based apps do it as a
matter of course, so any browser or WebView-heavy APK triggers it within
seconds of its GPU process starting; games hit it too. No guest code should be
able to kill the host process, and none does — the abort is entirely host-side.

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

## Symptom 2: every guest Vulkan heap is capped at 2 GB

The released emulator's gfxstream predates upstream commit `07d70ebe` ("Add
VulkanMaxSafeHeapSize feature"), which **removed a hard-coded 2 GB clamp on
every guest-visible Vulkan heap** — upstream's own rationale being that the
old default "can lead to some apps not work as expected". On an unfixed
emulator the guest sees 2048 MiB per heap no matter how much VRAM and host RAM
exist, and raising the AVD's `-memory` changes nothing.

This one does *not* kill the emulator, which is what makes it hard to
attribute. A workload whose allocations exceed 2 GiB — 3DMark Wild Life at
1440p is the canonical case — gets `vkAllocateMemory` failures mid-loading,
and what surfaces is whatever the app does with an allocation failure it never
expected: 3DMark dereferences an unchecked null mapping, crashes with
`SIGSEGV addr 0x0`, and reports "out of memory" although both guest RAM and
host VRAM are plentiful. The alloc-failure path in the guest Mesa driver is
silent, so the absence of graphics errors in logcat proves nothing.

The tell is one command:

```bash
adb shell cmd gpu vkjson    # look at "memoryHeaps"
```

Heaps of `0x80000000` (2048 MiB) on a host with a bigger GPU mean the clamp is
in place. After deploying a fixed emulator the same dump shows the real
sizes (e.g. ~30 GiB host-visible and ~16 GiB device-local on a 16 GB card).

To confirm the translator is not involved, run the same workload's x86_64
build: the failure reproduces identically with no translation in the path.

## Symptom 3: `vkCreateInstance` fails with `VK_ERROR_INITIALIZATION_FAILED`

Every Vulkan app gets `VkResult=-3` from `vkCreateInstance` and renders a black
frame. Nothing crashes, the guest driver loads and all of its dependencies
resolve, and `ro.hardware.vulkan=ranchu` with the Vulkan feature flags
advertised normally.

This is the opposite direction from Symptom 1: there the host binary was too
old for a struct the guest sent, here the *guest* driver is newer than any host
backend available. `vulkan.ranchu.so` grew from 2.0 MB to 4.5 MB between the
Android 16 and Android 17 images, and the newer one cannot complete the
gfxstream handshake with a host built from emulator source as of 2026-09-15.

### Confirming it is the image and not us

Four measurements, each of which rules something out:

1. **Rebuild the sample as native x86_64** (`abiFilters += "x86_64"`) and run
   it. It fails identically, with `0` `memfd:exec` regions and no
   `/system/lib64/arm64/` libraries in `/proc/<pid>/maps` -- no translated code
   is in the path at all, so it is not the translator.
2. **Run the older image under the newer emulator and vice versa.** The
   Android 16 image passes on the same emulator binary that the Android 17
   image fails on, so it is not the emulator binary.
3. **Swap only the guest driver.** `adb disable-verity`, reboot, `adb remount`,
   then copy the Android 16 `vulkan.ranchu.so` over the Android 17 one. Vulkan
   initializes immediately -- "Vulkan instance created", the GPU is named, and
   the screenshot test passes. That isolates the guest driver as the single
   incompatible component.
4. **Check the emulator source date.** If the newest source available is not
   newer than the emulator already deployed, rebuilding cannot help.

### What to do about it

Nothing, from this tree. `vulkan.ranchu.so` is built from
`hardware/google/gfxstream`, which is not a Digitalis modification surface, and
pinning the older driver would mean shipping an Android 16 component in an
Android 17 image. Re-test when a newer emulator source is available and deploy
it with `deploy-emulator.sh`; the swap in step 3 is the check that it worked.

Do not record this as a translator regression, and do not regenerate the
screenshot reference against the black frame -- the reference is correct and the
sample is correct.

## Deploying a fixed emulator

### 1. Get the emulator source

The emulator is a separate checkout from AOSP, on the `emu-main-dev` branch,
which carries both merged fixes:

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

Then confirm both behaviours directly: launch a Chromium-based APK on the
default GPU and check that the emulator survives with no `aborting` line in
its log, and run `adb shell cmd gpu vkjson` and check the guest heaps report
the host's real sizes rather than 2048 MiB.

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
- The heap clamp poisons full-app benchmarking: a GPU workload that dies at
  2 GiB "passes" smaller presets and fails bigger ones for reasons that have
  nothing to do with translation. Check `cmd gpu vkjson` before attributing any
  large-allocation failure.
