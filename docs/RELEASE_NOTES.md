# Digitalis — Prebuilt-App Stability & Translator Update (June 2026)

We started a **prebuilt-APK stability campaign**: instead of testing only our own
sample apps, Digitalis now installs, launches, and soaks **real ARM64-only top
apps and games** on the x86_64 emulator, and whenever one crashes we fix the
**root cause in the binary translator** — never the app.

## Verified prebuilt APKs

### Apps

| App | Package |
|---|---|
| WeChat | `com.tencent.mm` |
| WhatsApp | `com.whatsapp` |
| Facebook | `com.facebook.katana` |
| Douyin | `com.ss.android.ugc.aweme` |
| NetEase Cloud Music | `com.netease.cloudmusic` |
| Baidu Maps | `com.baidu.BaiduMap` |
| AMap | `com.autonavi.minimap` |
| Tencent Map | `com.tencent.map` |
| Tencent App Store | `com.tencent.android.qqdownloader` |
| QQ Input | `com.tencent.qqpinyin` |
| CoolApk | `com.coolapk.market` |
| AliExpress | `com.alibaba.aliexpresshd` |
| Brave Browser | `com.brave.browser` |
| Firefox | `org.mozilla.firefox` |
| Vulkan Caps Viewer | `de.saschawillems.vulkancapsviewer` |

### Games

| Game | Package |
|---|---|
| Crossy Road | `com.yodo1.crossyroad` |
| Temple Run 2 | `com.imangi.templerun2` |
| Temple Run | `com.imangi.templerun` |
| Subway Surfers | `com.kiloo.subwaysurf` |
| Hill Climb Racing | `com.fingersoft.hillclimb` |
| Space Mafia | `com.innersloth.spacemafia` |

### Partial

Launches and runs, with one intermittent residual that is *not* a translator bug
(its media player calls a private host graphics library, `libgui.so`, with no
guest equivalent):

| App | Package |
|---|---|
| Kuaishou | `com.smile.gifmaker` |

## Translator engine: two-gear JIT + broadened ISA coverage

**Two-gear optimizing JIT (now the default).** Digitalis runs ARM64 guest code
through three tiers: an **interpreter** (per-instruction fallback), a **lite
translator** (single-pass JIT — the first gear, for cold code), and a new
**heavy optimizer** (an optimizing second gear that engages on hot regions via a
hotness counter). The heavy tier lowers a whole region to a guest-agnostic SSA
machine IR and applies global register allocation and loop optimizations
(hoisting guest register/flag traffic out of loops), versus the lite tier's
per-instruction codegen. It is neutral-or-faster than lite across microbenchmarks
and ~2× faster on register-pressure-heavy loops; gear-up is gated to regions
large enough to recoup the optimization cost, so tiny loops are never regressed.
The heavy frontend covers integer ALU + NZCV flags, branches (including in-region
loops), loads/stores (with TBI + fault recovery), CSEL/CCMP, scalar FP (via the
intrinsic layer), NEON integer, SIMD/FP load-store, SIMD modified-immediate +
DUP, load/store-exclusive, division & wide-multiply, REV/CLS/SBFIZ, ADRP, and MRS
TPIDR_EL0 — bailing safely to the lite tier (correct, just not optimized) for
anything else.

**Broadened ARM64 instruction coverage.** Many instructions and newer ISA
extensions were implemented across the interpreter and lite JIT (and the
decoder), several surfaced by real apps and the sample probes:

- **Crypto / extensions:** SM3 (FEAT_SM3), SM4 (FEAT_SM4), CRC32C (via host
  SSE4.2 CRC32), RNDR/RNDRRS (FEAT_RNG).
- **Matrix / dot-product:** I8MM USDOT/SUDOT and SMMLA/UMMLA/USMMLA.
- **FP / SIMD:** FMOV (vector immediate), vector FCVTN/FCVTL (FP16↔FP32),
  FRINTTS (FRINT32/64, scalar + vector), SUQADD/USQADD, ADDHN/SUBHN/RADDHN/
  RSUBHN, FCMA complex, and the REV16-vector decoder fix.
- **Atomics / memory / tags:** EXT odd-imm4, LDXP/STXP exclusive pairs,
  generic-timer MRS, and the MTE tag group (ADDG/SUBG, LDGM/STGM/STZGM).
- **Correctness fixes from real apps:** FCSEL destination-aliasing, CCMN register
  clobber under register-mapping, LDPSW sign-extension, and IC-IVAU
  self-modifying-code cache invalidation.

This was developed against an extensive differential-fuzzing harness (JIT vs.
interpreter) for SIMD, scalar-FP, atomics, register-offset load/store, and
cross-region loops, plus a translator-throughput microbenchmark.

## Sample suite (85 modules)

The sample suite — 85 ARM64-only modules, all running under translation on the
x86_64 emulator — is the always-green spec the translator is validated against.

- **Platform APIs & graphics:** Vulkan (triangle, multisample FBO grids), OpenGL
  ES 1.x / 2.0 / 3.x (instanced rendering, NativeActivity/EGL, textured teapot
  scenes), audio (OpenSL ES, AAudio, Oboe), Camera2 NDK + CameraX, native MIDI,
  sensors, NDK binder (define/new + host-thread callback round-trip), NNAPI
  device enumeration, and WebView hardware-accel draw-functor registration.
- **ARM ISA probes (21):** NEON intrinsics (permutes, CRC32/CRC32C,
  URECPE/URSQRTE), vector & scalar FP, FP16 (Armv8.2), BF16 (Armv8.6), DotProd
  (Armv8.4 SDOT/UDOT), JSCVT (Armv8.3 FJCVTZS), FCMA complex, LSE atomics
  (Armv8.1 CAS/SWP/LDADD), LRCPC/LOR (Armv8.3/8.1), exclusive pairs
  (LDXP/STXP), barriers (DMB/DSB/ISB), AES + SHA-1/2 + SM3 crypto, widening
  multiplies (SMULL/UMULL/PMULL), generic-timer MRS, BTI (Armv8.5), PAC
  return-address signing, interleaved LD/ST, and sigaction/SIGSEGV + siglongjmp
  recovery.
- **UI engines:** Qt 6 widgets, React Native + Hermes (prebuilt bytecode), Lynx
  (ReactLynx + PrimJS).
- **Third-party native libraries (32):**
  - *Media:* ijkplayer (FFmpeg), libVLC, FFmpegKit, Oboe.
  - *Imaging:* Fresco, GPUImage, Tencent libpag, android-gif-drawable, PDFium,
    RenderScript Toolkit.
  - *Vision & ML:* OpenCV, TensorFlow Lite, LiteRT-LM, PyTorch Mobile, Tencent
    ncnn, ZXing, Tesseract.
  - *Crypto / storage / runtimes:* SQLCipher, Conscrypt, libsignal (Signal
    Protocol), Realm, ObjectBox, Tencent MMKV, zstd, QuickJS, Cronet.
  - *AndroidX-native:* bundled SQLite, graphics-path, CameraX core, Perfetto
    tracing SDK, AppSearch/Icing, Ink.
- **Proxy & regression probes:** GLES1 / AAudio / NNAPI / NDK-binder /
  WebView-functor proxy-library smoke tests, Digitalis libc/libm fast-path
  trampolines, and JIT regression probes for bugs once hit by Facebook/WhatsApp
  (LDP base aliasing, etc.).

(21 of the 85 are ports of Google's android/ndk-samples covering core JNI, GLES,
audio, camera, sensors, and codecs.)

## What was fixed in the prebuilt-app campaign, by theme

**Anti-tamper / integrity SDKs** (the hardest class — Chinese super-apps embed
aggressive anti-emulator/anti-debug SDKs):

- **Kuaishou** (`com.smile.gifmaker`) — its security SDK corrupted host
  fd-ownership via raw `close`/`close_range`/`dup3` (host `fdsan` abort), and
  armed a handler-less `SIGALRM` "deadman" watchdog that killed the process when
  the slow translated integrity check missed its deadline. Fixed by making guest
  fd ops fdsan-safe across the guest/host boundary and defaulting the host SIGALRM
  disposition to ignore.
- **Baidu Maps** (`com.baidu.BaiduMap`) — same fdsan class, plus its sofire SDK
  fed a null class into `GetStaticFieldID`, which the emulator's CheckJNI turned
  into a process-fatal abort; now returns a null field-id (matching production).
- **Amazon Shopping** (`com.amazon.mShop.android.shopping`) / **Microsoft Teams**
  (`com.microsoft.teams`) — a denied hidden-API `GetMethodID` left a pending JNI
  exception that aborted the next call; we clear pending exceptions after each
  lookup and grant guest apps a hidden-API exemption via host ART. (They reach
  further but remain blocked on Google Play Services, which the emulator lacks.)

**Douyin / WebView** (`com.ss.android.ugc.aweme`) — Douyin's Lynx UI engine calls
the WebView hardware-accel support library (`libwebviewchromium_plat_support`),
which was entirely uncovered by the proxy and aborted on first use. We covered it
(17/18 symbols), obtaining a valid host `JNIEnv` for the registration calls by
attaching the calling worker thread to the host VM.

**Instruction & codegen bugs surfaced by real apps:**

- `FCSEL` destination-aliasing corruption (made `strtod` return 0 → broke React
  Native/Hermes `parseInt`/`Number` and **NetEase Cloud Music**'s login render).
- `CCMN` clobbering its source register under register-mapping (NetEase blank
  login via Cronet).
- `LDPSW` sign-extension; `FMOV` (vector immediate), which unblocked the **Unity
  games** (Crossy Road, Temple Run 2) from OOM/SIGTRAP; `IC IVAU` cache
  invalidation for self-modifying JITs (PCRE2/ART/V8).

**fd / signal / proxy plumbing** — `ScopedFd` now closes with its current fdsan
tag to survive fd reuse (**Firefox** launch), and per-thread host `JNIEnv` tables
are each wrapped correctly.

## Known limitations

A handful of residual crashes are genuine **anti-emulator self-protection** or
**host-feature/GMS gaps**, not translator bugs (e.g. Kuaishou's intermittent
media-path crash, and Amazon/Teams needing Google Play Services). These are
documented rather than worked around. A separate host Vulkan-driver fix (GFXStream
`VK_EXT_memory_budget` clamp) was also needed for some games.
