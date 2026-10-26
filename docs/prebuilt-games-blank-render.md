# Two prebuilt games render blank, and neither is a translator bug

The prebuilt games corpus is 67 targets. 65 pass; `beachbuggy` and
`ninjahands2` present an empty frame. They look like one symptom and are two
unrelated host-side graphics problems, so they are written up together only to
keep the evidence that separates them in one place.

Both are reproducible on a pristine `-wipe-data` device with eight apps
installed, three launch attempts each, and both survive the gate's content
polling to its 120 s deadline (see `test-prebuilts.sh`: a blank frame is
re-checked every 30 s before it is failed, so these are not slow loads).

## Why they are not Digitalis bugs

| Game | Elimination |
|---|---|
| `beachbuggy` | Renders correctly under ANGLE on the *same* translator and image -- 1431 distinct colours against Android 16's 1434. Swapping only the GLES driver fixes it, so the fault is in the GLES driver, not in translation. |
| `ninjahands2` | Blank under `berberis.mode=interpret-only`, with the JIT entirely out of the path. Identical frame, so no JIT codegen bug. |

Keep suspecting Digitalis until an A/B says otherwise -- these are those A/Bs.

## `beachbuggy`: gfxstream GLES, uniform black

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
