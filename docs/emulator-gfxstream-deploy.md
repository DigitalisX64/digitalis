# Building and deploying a fixed emulator

Some Digitalis failures are not Digitalis failures. The emulator under
`prebuilts/android-emulator/` is a released binary that lags the emulator's own
source tree, so a host-side graphics fix that has already landed upstream is
still absent from the binary you run. One of the fixes below is not upstream at
all yet and has to be made in the emulator source before building.

This page covers four host-side symptoms: two stale-binary fixes (one aborts
the emulator process, one silently starves apps of Vulkan memory), one that is
purely a launch-flag problem, and one live gfxstream bug that segfaults the
emulator. Each section says how to tell it apart from a translator bug, and the
last sections cover building and deploying a host that has all of them.

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
frame. Nothing crashes, the guest driver loads and all its dependencies
resolve, `ro.hardware.vulkan=ranchu` is set, and the Vulkan feature flags are
advertised normally. GLES apps are unaffected.

Unlike Symptoms 1 and 2 this is **not** a stale host binary. The Android 17
kernel retires the goldfish pipe: the guest has no `/dev/goldfish_pipe`, only
`/dev/goldfish_pipe_dprctd` ("deprecated"), and that image's newer gfxstream
Vulkan driver takes the virtio-gpu path instead. The emulator exposes
virtio-gpu only when asked, so without the feature flags there is no
`/dev/dri/*` for the driver to open and instance creation fails. GLES keeps
working because it still falls back to the deprecated pipe node.

### The fix: launch with virtio-gpu

```
emulator ... -feature VirtioGpuNativeSync,VirtioGpuFenceContexts
```

That is the whole fix and the minimal set -- measured, not guessed. With it the
guest gains `/dev/dri/card0` and `/dev/dri/renderD128`, and the app reports
`Using GPU: Virtio-GPU GFXStream` instead of failing. Neither `-gpu host` nor
`-feature Vulkan` is needed: `-gpu host -feature Vulkan` on its own leaves
`/dev/dri` absent and still fails, while the two flags above work with no
`-gpu` argument at all.

### Telling it apart from a translator bug

The black frame and the silent `-3` make this look like a guest-code fault. It
is not, and it is worth proving rather than assuming:

1. **Rebuild the sample as native x86_64** (`abiFilters += "x86_64"`). It fails
   identically, with `0` `memfd:exec` regions and no `/system/lib64/arm64/`
   libraries in `/proc/<pid>/maps` -- no translated code in the process at all.
   Remember to rebuild the arm64 APK afterwards; a stale x86_64 APK left
   installed will quietly answer later runs.
2. **Check `/dev/dri`.** Empty means the transport is missing and no amount of
   translator work will help.
3. **Swap the guest driver.** `adb disable-verity`, reboot, `adb remount`, then
   copy an older image's `vulkan.ranchu.so` over the newer one. If Vulkan then
   initializes, the driver and the transport it expects are the whole story.

Rebuilding and redeploying the emulator does *not* fix this one -- a host built
from 2026-10-21 source fails exactly like the shipped prebuilt -- so do not
reach for `deploy-emulator.sh` here. Check the launch flags first.

## Symptom 4: the emulator segfaults about a minute into every boot

The emulator reaches the launcher and then the process simply disappears.
`adb devices` goes empty, the telnet console stops answering, and the
emulator's own stdout ends without a fatal message -- the last lines are an
app's `VkInstance` being destroyed and:

```
ERROR | Failed to find process owned resources for puid 5.
```

The exit status is `139` (SIGSEGV), and the backtrace from the core is:

```
#0  VkDecoder::Impl::decode(...)            <- atomic RMW, c11.h
#1  gfxstream::host::RenderThread::main()
...
#5  FrameBuffer::Impl::cleanupProcGLObjects(unsigned long)
#8  RendererImpl::ProcessCleanupThread::CleanProcessResources
```

Two threads in one picture: a render thread is still decoding for a guest
process while the cleanup worker tears that same process down.

`RendererImpl::cleanupProcGLObjects()` removed the process's
`ProcessResources` **before** handing the puid to the cleanup worker, and only
the worker waits (inside `FrameBuffer::cleanupProcGLObjects()`) for that puid's
render threads to finish. In the window between the two, a render thread that
had not yet cached the pointer looks it up, gets the `nullptr` that prints the
error above, and passes it to the Vulkan decoder. The decoder guards the *read*
of the sequence number (`if (seqnoPtr && ...)`) but every one of its generated
`seqnoPtr->fetch_add(1, ...)` completion sites is unguarded, so the first
command it finishes does an atomic increment through address 0.

`bootanimation` exiting a few seconds after the launcher appears is what
reliably hits it, which is why the death is so reproducible and always at the
same point. It is *not* specific to any app or to the translator: no guest code
can legitimately kill the host process.

This surfaces only once ANGLE is the GLES driver, because then every app's
rendering goes through the Vulkan decoder. Under gfxstream's own GLES almost
nothing took that path, so the race was there but rarely won.

Unlike Symptoms 1 and 2 this is not a stale binary: a host built from
2026-10-21 emulator source crashes the same way, so the fix has to be made in
the source before building. In
`hardware/google/gfxstream/host/renderer_impl.cpp`, defer the removal to the
cleanup worker so it happens *after* the existing render-thread wait -- the
lifetime the code's own comment already assumes:

```c++
 void RendererImpl::cleanupProcGLObjects(uint64_t puid) {
-    std::unique_ptr<ProcessResources> resource =
-        FrameBuffer::getFB()->removeGraphicsProcessResources(puid);
-    mCleanupThread->cleanup(puid, std::move(resource));
+    mCleanupThread->cleanup(puid);
 }
```

and in the worker's visitor:

```c++
 WorkerProcessingResult operator()(CleanProcessResources resources) {
     FrameBuffer::getFB()->cleanupProcGLObjects(resources.puid);
+    FrameBuffer::getFB()->removeGraphicsProcessResources(resources.puid);
     return WorkerProcessingResult::Continue;
 }
```

`CleanProcessResources` then carries only the puid, and
`ProcessCleanupThread::cleanup()` loses its `std::unique_ptr` parameter.
Do not try to fix this in `host/vulkan/vk_decoder.cpp`: it is generated
("Please do not modify directly") from the Vulkan registry, and the hundreds of
unguarded increment sites come from the generator template.

Verify the fix behaviourally, not just by booting -- the unfixed build also
reaches the launcher before dying. A fixed host shows **zero**
`Failed to find process owned resources` lines and survives well past the
bootanimation teardown window.

## Symptom 5: an app calls through an uninitialised GL function pointer

Beach Buggy Racing crashed with `SIGSEGV si_addr=0x300` on every launch. The
guest code is

```
ldr  x8, [x20, #0xd0]      // glDiscardFramebufferEXT
cbz  x8, skip              // the game DOES null-check it
...
blr  x8                    // -> 0x300
```

The member at `+0xd0` is written only when
`getExtension("GL_EXT_discard_framebuffer")` returns true. gfxstream's GLES
decoder has had a `glDiscardFramebufferEXT` entry point for years, but the
translator never advertised the extension, so the member was never written and
the game branched through heap residue. `0x300` is `GL_SRC_COLOR` -- leftovers,
not a computed pointer, which is the tell for an uninitialised read.

Fixed in `host/gl/glestranslator/gles_v2/` by implementing
`glDiscardFramebufferEXT` as `glInvalidateFramebuffer` (the EXT is the ES 2
spelling of the same hint) and advertising the extension in
`InitExtensionString`.

The general shape is worth recognising: an app that *conditionally* resolves an
entry point and *unconditionally* calls it turns a missing extension into a
crash whose reproducibility depends on heap contents. It will look
tier-dependent, and switching GLES driver will "fix" it whenever the other
driver happens to advertise the extension.

## Symptom 6: the 37.x emulator boots but the guest has no Vulkan

`ls /dev/dri` is empty and `cmd gpu vkjson` returns `{}`, while the emulator
logs

```
WARNING | Please update the emulator to one that supports the feature(s):
          VirtioGpuFenceContexts, VirtioGpuNativeSync, VulkanVirtualQueue
```

Those are **host** features. The `advancedFeatures.ini` goldfish installs into
the system image is the *guest* feature file; host features are read from the
emulator's own `lib/advancedFeatures.ini`, which the 37.x build ships with
`VirtioGpuNativeSync = off` and `VirtioGpuFenceContexts = off`. Listing them on
the guest side only produces that warning.

`deploy-emulator.sh` flips both host flags on, so a deployed emulator is
correct; a build run straight out of `objs/` is not.

## Symptom 7: deploy refuses with a BuildID mismatch

```
ERROR: stripped/unstripped backend BuildID mismatch (... vs ...) -- stale distribution
```

`deploy-emulator.sh` packages from `objs/distribution/` and
`objs/distribution-unstripped/`, not from `objs/lib64/`. Building a single
library with `ninja lib64/libgfxstream_backend.so` therefore does **not** update
what gets deployed, and refreshing only one of the two trips this check. When
hand-patching a library into the package, update both:

```
strip --strip-unneeded -o objs/distribution/emulator/lib64/libgfxstream_backend.so \
                          objs/lib64/libgfxstream_backend.so
cp objs/lib64/libgfxstream_backend.so \
   objs/distribution-unstripped/emulator/lib64/libgfxstream_backend.so
```

The check is doing its job: without it the deployed emulator silently keeps the
old backend and the fix appears not to work.

## Symptom 8: later apps in a session render black (`Failed to create process resource`)

```
WARNING | Failed to create process resource for puid 2.
WARNING | Failed to create process resource for puid 6.
```

`createGraphicsProcessResources()` warns when `try_emplace` fails, which means
the puid is still in `m_procOwnedResources`. A new guest process reusing that
puid then inherits a dead process's entry and renders black. In a gate batch the
symptom is positional: the first few titles pass and later ones are blank.

This was self-inflicted. An earlier fix here deferred
`removeGraphicsProcessResources()` into the cleanup worker so that a render
thread still decoding could not lose its sequence number. That kept the *map
entry* alive, not just the object, and leaked puids. Measured on the gate's
batch 1, with nothing else changed:

| teardown | `burgerplease` |
|---|---|
| removal deferred into the worker | 16/60 cells |
| upstream (immediate removal) | 54/60 cells |

Seven Unity titles failed that way.

The constraint that motivated the deferral is real, so the fix has to satisfy
both halves:

* **Remove the map entry immediately**, as upstream does, so a new process with
  the same puid can create its own resources. The object itself still outlives
  the threads: `removeGraphicsProcessResources()` hands the `unique_ptr` to the
  cleanup worker, which destroys it only after `cleanupProcGLObjects()` has
  waited for that puid's render threads.
* **Never hand the decoder a null sequence number.** When a draining thread's
  lookup misses, `RenderThread` now falls back to a private `ProcessResources`
  instead of `nullptr`. The generated Vulkan decoder increments that pointer on
  every completed command with no null check, and the sequence number only
  orders commands within one live process -- a process that is going away needs
  no ordering with anyone.

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
