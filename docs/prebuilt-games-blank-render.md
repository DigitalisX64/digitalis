# Two prebuilt games rendered blank -- both root-caused and fixed

Both failures in the 67-target prebuilt games corpus are fixed. Neither was a
translator bug, and neither was the host-GL bug this page originally claimed.

## `beachbuggy`: an unadvertised GL extension, not a render bug

`VuAndroidOglesGfx::init` (libmain.so vaddr 0x7adb88) resolves
`glDiscardFramebufferEXT` and stores it at `this+0xd0` **only** when
`VuOglesGfx::getExtension("GL_EXT_discard_framebuffer")` returns true.
`setRenderTarget` (0x7ade0c) then does

```
ldr  x8, [x20, #0xd0]
cbz  x8, skip          // the game DOES null-check it
...
blr  x8
```

gfxstream's GLES decoder has had a `glDiscardFramebufferEXT` entry point all
along, but its GLES translator never advertised the extension, so the member
was never written and the game branched through **uninitialised heap**. Whether
that crashed depended on what the slot happened to hold -- `0x300` here, which
is `GL_SRC_COLOR`, residue rather than a computed pointer.

That is why every earlier reading was wrong. It looked tier-dependent (the
residue differed), and ANGLE "fixed" it only because ANGLE advertises
`GL_EXT_discard_framebuffer`.

**Fix** (gfxstream, `host/gl/glestranslator/gles_v2/`): implement
`glDiscardFramebufferEXT` as `glInvalidateFramebuffer` -- the EXT is the ES 2
spelling of the same hint, with the same target and attachment tokens -- and
advertise `GL_EXT_discard_framebuffer` in `InitExtensionString`. The
translator's existing no-op fallback applies when the host lacks the entry
point, which a hint extension may legally do.

Verified on both translated tiers (`two-gear` and
`lite-translate-or-interpret`): process alive, zero fatal signals, 47/60
content cells.

## `ninjahands2`: virtio-gpu was never switched on for the 37.x emulator

The guest `advancedFeatures.ini` that goldfish installs is the **guest**
feature file. `VirtioGpuNativeSync` and `VirtioGpuFenceContexts` are **host**
features, read from the emulator's own `lib/advancedFeatures.ini`, which the
37.x build ships `off`. Listing them in the guest file only produced

```
WARNING | Please update the emulator to one that supports the feature(s):
          VirtioGpuFenceContexts, VirtioGpuNativeSync, VulkanVirtualQueue
```

so the guest had no `/dev/dri/*` and no Vulkan at all. With the host flags on,
the guest gets `card0`/`renderD128`, `cmd gpu vkjson` reports a device, and the
37.x gfxstream no longer exhibits the `AddressSpaceStream::speculativeRead`
lost wakeup that 36.3.10 did. The title renders its full menu (55/60 cells)
with Vulkan live.

`deploy-emulator.sh` already flips those two host flags on deploy; nothing in
goldfish needed to change.

## A trap worth keeping

An unhandled fatal guest signal used to spin forever instead of crashing
(binary_translation `96d92a7f`): `ProcessPendingSignalsImpl` called
`kFatalGuestHandlerStub` as guest code, which faulted, re-raised and looped at
100% CPU. Every tier then looked identically "process alive, frame black,
logcat silent", so the tier A/B that separates our bugs from the host's
returned the same answer for all three and the investigation pointed outward.

Before trusting any tier A/B, check `top -H` on the app's threads: a thread
pinned at 100% is a spin, and a spin makes every tier look alike.

## Superseded: the original `beachbuggy` gfxstream-GLES investigation

Vector Unit's own engine (`VuAndroidCommunityManager`), not Unity. 1920x1080
landscape, every pixel `(0,0,0)`.

The guest GLES driver loads and reports itself:

```
I GFXSTREAM: [eglDisplay.cpp(297)] Opening libGLESv2_emulation.so
V syscaps : ##> GL_RENDERER: Android Emulator OpenGL ES Translator (AMD Radeon RX 7800 XT ...)
V syscaps : ##> GL_VERSION: OpenGL ES 3.1 (4.6 (Core Profile) Mesa 26.0.8)
```

SurfaceFlinger has the app's `SurfaceView` layer and its background layer, so
the window exists. There are no shader-compile errors, no `GL_INVALID_*`, and
no incomplete-framebuffer complaints: the engine initialises GLES 3.1 and then
nothing it draws reaches the surface.

One EGL error does appear and is **not** the cause:

```
E GFXSTREAM: [egl.cpp(1491)] tid 5177: error 0x300c (EGL_BAD_PARAMETER)
```

`egl.cpp:1491` is `setErrorReturn(EGL_BAD_PARAMETER, EGL_FALSE)` inside
`eglBindAPI()` -- the app passed something other than `EGL_OPENGL_ES_API`.
Startup probe noise, before any surface work.

The host GL backend is not the culprit either. Running the emulator with
`-gpu swiftshader_indirect`, which replaces the host's native GL driver with a
software renderer, leaves the frame just as blank (one colour). Both host
backends share gfxstream's GLES translation layer, so the defect is in that
layer rather than in Mesa/radeonsi or anything host-driver specific. Don't
re-test this with a different host GPU or driver.

ANGLE renders this game because it reimplements GLES on Vulkan and never uses
gfxstream's GLES path. It is not a usable fix: measured over the same corpus,
ANGLE breaks `artblitz`, `bouncyhoops`, `bucketcrusher` and `burgerplease`,
which is why the product keeps gfxstream GLES (see
`sdk_phone64_x86_64_digitalis.mk`).

## `ninjahands2`: gfxstream Vulkan, uniform white

Unity/il2cpp, and it selects **Vulkan**, not GLES -- there is not a single
`GFXSTREAM:` line in the process, only the Vulkan loader's layer search. 1080x1920
portrait, every pixel `(255,255,255)`: a surface cleared and never drawn into.

Vulkan itself comes up: the host creates six Vulkan objects for "Ninja Hands 2"
and Unity reports the device normally. What fails is the present path, and a
thread dump taken while the frame is blank shows it is a deadlock, not idleness:

```
"UnityGfxDeviceW" sysTid=6552
 #02 vulkan.ranchu.so  AddressSpaceStream::speculativeRead      <- blocked on the host reply
 #03 vulkan.ranchu.so  AddressSpaceStream::readFully
 #05 vulkan.ranchu.so  VkEncoder::vkQueueWaitIdle
 #06 vulkan.ranchu.so  ResourceTracker::on_vkQueueSubmitTemplate<...>
 #07 vulkan.ranchu.so  gfxstream_vk_QueueSubmit2
 #08 vulkan.ranchu.so  vk_common_QueueSignalReleaseImageANDROID
 #09 libvulkan.so      vulkan::driver::QueuePresentKHR
 #10 libberberis_proxy_libvulkan.so  DoCustomTrampoline...
```

Two `UnityGfxDeviceW` threads sit there, so no frame is ever presented and the
window keeps its clear colour. Digitalis appears in the stack only as the
forwarding trampoline at the entry point; the blocking read is the Android
system's own native Vulkan driver waiting on the emulator.

Meanwhile **every qemu thread is at 0.0% CPU**. That matters, because the two
obvious explanations both predict otherwise:

* It is not the decoder's sequence-number spin. That loop is a `pause` loop and
  would burn a core; the host is idle. The
  `WARNING | Process=...is exitting. Skip processing seqno=1288` lines in the
  emulator log are the *consequence* of the gate force-stopping the app at the
  end of its watch, not the cause of the stall.
* It is not a missing sequence-number increment in the generated decoder.
  `vkQueueSubmit`, `vkQueueSubmit2`, `vkQueueSubmit2KHR`, `vkQueueWaitIdle` and
  `vkQueueSignalReleaseImageANDROID` all increment it. (Checked in 37.x source;
  the running emulator is the restored 36.3.10 prebuilt, so treat that as
  indicative rather than authoritative.)

Guest blocked on a reply while the host is idle means the command, or its
wakeup, never arrived -- a lost notification on the address-space transport
rather than anything mis-decoded. The AOSP 17 transport change is the obvious
suspect: the kernel retires the goldfish pipe and Vulkan now rides virtio-gpu
(Symptom 3 in `emulator-gfxstream-deploy.md`).

It is not a blanket transport failure: Genshin Impact is also Unity on Vulkan
and it passes, so whatever this is depends on how the app presents --
`vkQueueSubmit2` plus `QueueSignalReleaseImageANDROID` from two graphics
threads is the distinguishing shape to start from.

This also explains why ANGLE does nothing for it: ANGLE substitutes the GLES
driver, and this app never asks for GLES.

## The configuration trade-off

Disabling the virtio-gpu transport removes guest Vulkan, Unity falls back to
GLES, and `ninjahands2` renders normally -- 19629 distinct colours, with the ten
`GFXSTREAM:` lines that show the GLES driver in use. That isolates its cause
beyond doubt: the game is fine, the Vulkan path is not.

`beachbuggy` is unchanged by the same experiment (still one colour), which
confirms the two failures are independent: its GLES defect is not a transport
problem.

Measured across the three reachable configurations:

Both candidate configurations were measured over the whole corpus, one full
sweep each, nine batches on a fresh emulator per batch:

| Configuration | games | fails | guest Vulkan |
| --- | --- | --- | --- |
| gfxstream GLES + virtio-gpu (shipping) | **65 / 67** | beachbuggy, ninjahands2 | works -- host creates VkInstance for a Vulkan app |
| gfxstream GLES, no virtio-gpu | **66 / 67** | beachbuggy | **none** -- `cmd gpu vkjson` returns `{}` |
| ANGLE + virtio-gpu | not swept | beachbuggy passes, four others fail | works |

Dropping virtio-gpu costs no game: every Unity title falls back to GLES and all
64 other targets pass exactly as before, Genshin Impact included. What it costs
is Vulkan itself, platform-wide and not just for games -- with the transport
off the platform enumerates zero Vulkan devices, so anything Vulkan-only
(VkCapsViewer, 3DMark Wild Life) has nothing to run on. On AOSP 17 there is no
second transport to fall back to: the kernel retires the goldfish pipe
(Symptom 3 in `emulator-gfxstream-deploy.md`).

The shipping choice keeps 65 and keeps Vulkan, and is deliberate rather than
accidental:

* Dropping virtio-gpu buys exactly one game and removes a platform capability.
* ANGLE buys `beachbuggy` and costs four games that currently pass.

Judged on the games corpus alone the middle row wins by one game, and the
switch is two flags. Judged on the image it trades Vulkan for that one game,
which is why it is not the default. Revisit it if the Vulkan-only prebuilts
stop mattering; the decision is about the image, not about these two games.

## The better fix for beachbuggy: per-app ANGLE

Image-wide ANGLE costs four games, but Android can select ANGLE for named
packages only, and that is enough here:

```
settings put global angle_gl_driver_selection_pkgs   com.vectorunit.purple.googleplay
settings put global angle_gl_driver_selection_values angle
```

This works as intended. The emulator then logs exactly one ANGLE client:

```
Created VkInstance:0x... for application:'com.vectorunit.purple.googleplay' engine:'ANGLE'
```

against the image-wide case, which creates ANGLE instances for surfaceflinger,
launcher3, systemui and every app. So the one game that needs ANGLE can have it
while everything else keeps gfxstream GLES and keeps passing, and guest Vulkan
stays available. That is 66/67 with no capability given up -- better than either
configuration in the table above.

It is blocked by the emulator, not by the mechanism. On the shipped 36.3.10
prebuilt, the moment ANGLE initialises its device the emulator aborts:

```
reservedunmarshal_extension_struct, Unhandled Vulkan structure type [1000382000], aborting.
```

`1000382000` is `VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRIMITIVES_GENERATED_QUERY_FEATURES_EXT`
(`VK_EXT_primitives_generated_query`), which ANGLE queries during device
creation and that gfxstream's unmarshaller does not know. It is the same class
as Symptom 1 in `emulator-gfxstream-deploy.md` -- a struct the shipped host
predates -- and it needs a newer host, which is the 37.x build that will not
boot here (see Status).

Disabling the corresponding ANGLE feature does **not** avoid the abort. goldfish
already drives `debug.angle.feature_overrides_disabled` from
`ro.boot.hardware.angle_feature_overrides_disabled`, and the feature is named
`supportsPrimitivesGeneratedQuery` (it is in the guest `libGLESv2_angle.so`),
so this looked like a one-property fix. It is not: with
`debug.angle.feature_overrides_disabled=supportsPrimitivesGeneratedQuery` set
and ANGLE selected for that package alone, the emulator aborts on the identical
struct. ANGLE queries the physical-device feature chain for every extension the
driver advertises regardless of whether it will use the capability, and the
override only gates usage. Do not spend time on this property again.

Two further notes for whoever picks this up:

* ANGLE also needs the process-teardown fix (Symptom 4), because it routes every
  ANGLE client through the Vulkan decoder.
* `settings put global` lives in userdata, and every gate launch uses
  `-wipe-data`, so this cannot be a manual step: it has to be seeded by the
  product (goldfish) to survive a wipe and to mean anything for the gate.

## Status

Both are host graphics defects, one per API, with Digitalis eliminated by A/B.
Neither has a fix here yet.

`ninjahands2` is the better-characterised of the two: a reproducible deadlock
with the blocking frame identified, the host demonstrably idle, and two
plausible causes already eliminated. The next step is to find out whether the
guest's write reaches the host at all -- host-side gfxstream Vulkan logging for
that process, or a trace of the address-space stream doorbell -- rather than to
keep reading the decoder.

`beachbuggy` is the weaker lead: no error is reported anywhere, and it fails on
both transports, so there is no thread to pull beyond instrumenting gfxstream's
GLES path.

One experiment is blocked rather than finished. The newer 37.x emulator built
from `emu-main-dev` would be the obvious thing to try against both games, since
its gfxstream is months newer. It cannot be booted on this host at present: from
14:40 on 2026-10-26 every launch fails with
`kvm_user_backed_ram_map: error registering slot: File exists` and hangs without
serving adb, while the 36.3.10 prebuilt boots from the same tree, same AVD and
same locks cleared. A clean deploy (293 files, exactly the build output) fails
the same way as the hybrid package did, so the earlier `--delete` bug was real
but is not this. Retry after a host reboot before spending time on it.
