# Digitalis — On-Screen Rendering, New Samples & Binary Distribution (2026-06-21)

This update adds a guest `libgui.so` stub that unblocks Google Filament's
on-screen render path under translation, grows the always-green sample suite to
**116 ARM64-only modules** with 11 more third-party native-library samples, and
ships Docker-based tooling to distribute Digitalis as binaries only.

## New: guest `libgui.so` stub — on-screen Filament rendering

Google Filament's Android platform layer `dlopen`s `libgui.so` and calls
`android::Surface::hook_perform` on its SwapChain present path. Digitalis ships no
guest `libgui.so` — surface/buffer management is proxied to the host GPU stack,
which is exactly why `hello-vulkan` renders on screen without any guest libgui — so
that `dlopen` returned NULL and the guest then executed a host address →
`berberis_HandleNoExec` SIGSEGV.

A *full* guest `libgui.so` is the wrong fix: it would run its own guest-side
BufferQueue/SurfaceFlinger client and fight the host-proxied present path. Instead
Digitalis now ships a minimal **guest-only `libgui.so` stub**
(`frameworks/libs/binary_translation/android_api/digitalis_libgui_stub`, installed
as `/system/lib64/arm64/libgui.so`) that exports `hook_perform` as a benign no-op
(the real `NATIVE_WINDOW_SET_*` operations belong to the host), so the
`dlopen`/`dlsym` succeed and the present path stays on the proxied route. The stub
is built in-tree as a native-bridge guest library and added to the distribution
set; the upstream riscv64 build is unaffected (arm64-only product wiring).

## New samples (sample suite → 116)

11 more third-party native-library samples now run under translation as part of the
always-green suite:

- **3D rendering:** Google Filament's physically-based renderer
  (`hello-filament`, a headless GPU-resource smoke test) and its native glTF loader
  gltfio (`hello-gltfio`). **`hello-filament-render`** draws a lit glTF cube on
  screen via Filament's Vulkan backend — a deterministic screenshot sample, enabled
  by the `libgui.so` stub above.
- **Numeric / scientific:** OpenBLAS (`hello-openblas`), FFTW (`hello-fftw`), the
  GNU Scientific Library (`hello-gsl`).
- **Physics:** Box2D 2D physics (`hello-box2d`).
- **Imaging / OCR pre-processing:** libyuv color conversion (`hello-libyuv`),
  Leptonica image processing (`hello-leptonica`).
- **Compression:** Snappy (`hello-snappy`).
- **Crypto:** secp256k1 Bitcoin-curve ECDSA (`hello-secp256k1`).

All run on the x86_64 emulator via NativeBridge translation; the full sample suite,
the host unit tests (2460 `Arm64*`), the screenshot tests, and the prebuilt-app gate
are green.

## Binary-only distribution (Docker)

New tooling under `digitalis/docker/` and `digitalis/scripts/` packages the
translator as **binaries only** for other AOSP x86_64 products to drop in: the
74-artifact distribution set defined in `berberis_config.mk`
(`libberberis_arm64.so`, the proxy libraries, program runners, the ARM64 guest
libraries, and configs), plus a generated consumer `.mk` and an integration README.
A reproducible `digitalis-build` Docker container reuses the host `out/` tree (bind-
mounted at the same path) so neither the container nor a normal host developer has
to rebuild the project. See `digitalis/docker/README.md`.

---

# Digitalis — Sample-Suite Expansion & Heap-Lifetime Fixes (2026-06-20)

This update grows the always-green sample suite to **104 ARM64-only modules**
(from 85) by adding ~20 third-party native-library samples, and fixes a
heap-lifetime translator bug and an intermittent heavy-allocation crash that
those new samples surfaced.

## New samples (sample suite: 85 → 104)

~20 new third-party native-library samples now run under translation on the
x86_64 emulator as part of the always-green suite:

- **Databases / storage:** Couchbase Lite (`hello-couchbase`), Tencent WCDB
  (`hello-wcdb`).
- **Crypto:** libsodium (`hello-libsodium`), Argon2 (`hello-argon2`), Themis
  (`hello-themis`).
- **On-device ML / speech / vision:** ONNX Runtime (`hello-onnxruntime`),
  MediaPipe (`hello-mediapipe`), Vosk offline speech (`hello-vosk`).
- **Graphics / maps / imaging:** MapLibre vector maps (`hello-maplibre`), Rive
  vector animation (`hello-rive`), libavif (`hello-avif`).
- **Media / RTC:** WebRTC (`hello-webrtc`).
- **Networking / VPN / P2P:** WireGuard (`hello-wireguard`), libtorrent4j
  (`hello-libtorrent4j`).
- **JS engines:** Duktape (`hello-duktape`), J2V8 (`hello-j2v8`), Javet V8
  (`hello-javet`).
- **JNI bridges:** JavaCPP (`hello-javacpp`), JNA (`hello-jna`), Facebook fbjni
  (`hello-fbjni`).

## Fixes

**MapLibre — `wstring_convert: from_bytes error` at native init
(`hello-maplibre`).** MapLibre's `FileSource::getAPIBaseUrl` frees its base-URL
`std::string` at one call site and re-reads it at the next — a use-after-free
that is benign on real hardware (the allocator does not recycle the chunk in
that window). Under translation the guest heap (host Scudo) is shared with the
translator's own allocations: once the freed chunk's Scudo region empties the
pages are released, and the lite/heavy translator's bump arena (`MmapPool`)
immediately re-grabs that address and zero-initialises an IR node over the
still-referenced bytes, so the guest converts zeros and throws. Root-caused with
an in-process `mprotect` memory watchpoint that caught the free and the arena's
overwrite. Fixed with a bounded **free-quarantine** in the `--wrap=free` proxy
(`libberberis_proxy_libc`): the most recent guest frees are deferred through a
fixed ring so a just-freed chunk and its region stay live across the window,
bringing free timing closer to hardware so benign guest use-after-frees stay
benign.

**Heavy-allocation crash — GWP-ASan guard-page underflow in the free probe.**
That same `--wrap=free` proxy peeks the 16 bytes before each freed pointer to
detect non-heap (Qt shared-null) frees. GWP-ASan (the platform sampling
allocator) flushes ~1/1000 allocations against a guard page, so the peek read
that guard page and intermittently crashed any heavy-allocation app. The probe
now skips the peek for page-boundary-adjacent pointers (always a real
GWP-ASan-guarded heap pointer, never a static shared-null).

**Javet V8 (`hello-javet`).** A `SIGABRT` at V8 startup was a compile-time
embedder/V8 sandbox build-config mismatch in the `javet-v8-android:5.0.8` arm64
AAR, not a translator bug; pinning to a consistent build (`4.1.7`) resolves it.

---

# Digitalis — Prebuilt-App Stability & Translator Update (2026-06-15)

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
