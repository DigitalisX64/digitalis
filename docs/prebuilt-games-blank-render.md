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

Vulkan itself comes up. The host creates six Vulkan objects for "Ninja Hands 2",
and Unity reports the device normally. What fails is the command stream:

```
WARNING | Process=com.YsoCorp.NinjaHands2-29 is exitting. Skip processing seqno=1288 on thread=0x1e2486c0
```

That line is emitted from the sequence-number wait in `VkDecoder::Impl::decode`,
which spins `while ((seqno - seqnoPtr->load(...)) != 1)` until the expected
sequence number arrives and only escapes through `shouldExit`. The app's render
threads are parked there, so no frames are ever submitted and the window stays
at its clear colour.

This also explains why ANGLE does nothing for it: ANGLE substitutes the GLES
driver, and this app never asks for GLES.

## Status

Both are host graphics defects, one per API, with Digitalis eliminated by A/B.
Neither has a fix here yet. `ninjahands2` is the more tractable of the two: the
stall is in the same `vk_decoder` sequence-number mechanism as the
process-teardown crash in `emulator-gfxstream-deploy.md` (Symptom 4), which is
already known to be fragile, and the warning above names the thread and the
sequence number it is waiting for.
