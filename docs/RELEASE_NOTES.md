# Digitalis — No Reachable Call Aborts: Full Audio-Proxy Coverage, 150 Samples (2026-08-15)

Every proxy library forwards guest calls through trampolines, and until now two
of the 21 — OpenSL ES and OpenMAX AL — still carried loaded guns: vtable
methods the upstream translation layer registers as
`LOG_ALWAYS_FATAL("not implemented")` stubs. These never showed up in the
`DoBadTrampoline` audit because they are not symbols. The audio proxies wrap
host interface vtables *lazily, by name*, when a guest first obtains an
interface through `GetInterface`; a method the upstream generator could not
marshal aborts the whole process on its first call. Nine OpenSL ES
`Register*Callback` methods were such stubs, and OpenMAX AL's entire
`XAObject::GetInterface` dispatch aborted on any interface ID outside its
six-entry set — including `XA_IID_SEEK` and `XA_IID_PREFETCHSTATUS`, which the
platform hands out to any media player that asks. This release closes all of
it; no app-reachable call aborts in any proxy library.

- **A fourth extras mechanism: named-trampoline overrides.** The existing
  symbol-level extras registry cannot reach a trampoline that never appears in
  a symbol table, so a new registry
  (`digitalis_extra_proxy/named_trampoline_override.{h,cc}`) intercepts by the
  one stable handle these wraps have — their registration name. Override files
  compiled into the owning proxy library declare `{name, replacement}` pairs
  from a constructor; a guarded hook inlined into `WrapHostFunctionImpl`
  installs the replacement at wrap time and records the displaced upstream
  trampoline, which an override can fetch back and delegate to. Because the
  hook lives in the inline header body, it compiles per consumer flavor: the
  riscv64 build compiles the original code byte-identically, and a weak
  reference keeps binaries that inline the header without the registry
  linking. One sharp edge is pinned by unit test: the registry records the
  incoming trampoline as the delegable original on every matching wrap, so it
  refuses to record an override as its own original — the self-wrap that would
  otherwise recurse forever.
- **libOpenSLES: all nine fatal callback registrations now marshal.** Each
  wraps the guest callback with `WrapGuestFunction` and forwards to the host
  method. Three are reachable from app code on the Android profile —
  `SLAndroidBufferQueueItf::RegisterCallback` (the AAC-ADTS streaming-decode
  path real players use), `SLDynamicInterfaceManagementItf::RegisterCallback`
  (implicit on every object), and
  `SLOutputMixItf::RegisterDeviceChangeCallback`. The other six
  (AudioIODeviceCapabilities ×3, MIDIMessage ×2, Visualization) sit behind
  interfaces the platform build never exposes (`USE_PROFILES=0`); covering
  them uniformly costs nothing and survives a profile change.
- **libOpenMAXAL: `GetInterface` marshals what the platform can hand out.**
  The override handles `XA_IID_SEEK` and `XA_IID_PREFETCHSTATUS` (method
  wrapping plus the `xaPrefetchCallback` custom trampoline), tolerates
  `XA_IID_OBJECT` (already wrapped — every object shares one static vtable),
  keeps `XA_IID_DYNAMICINTERFACEMANAGEMENT` ready, and delegates every other
  ID to the upstream dispatch unchanged, so behaviour is identical wherever it
  already worked.
- **Two platform findings, pinned rather than papered over.** The XA
  dynamic-interface-management interface sits in the media player'"'"'s class
  table as implicit, but the implementation ships no init hook for it, so
  `GetInterface` refuses it on native devices exactly as under translation.
  And the engine'"'"'s `AudioIODeviceCapabilities` interface is compiled
  unavailable by the platform'"'"'s profile setting. The probes assert the clean
  refusal in both cases and exercise the registrations only if a platform
  exposes the interface.
- **The suite grows to 150 modules.** A new `hello-opensles` probe registers
  the three reachable callbacks with golden result checks, round-trips the
  buffer-queue event mask, and streams a command item through the AAC-ADTS
  decode player — under translation the buffer-queue callback **fires**, host
  code calling back into translated guest code, so the round trip is proven
  end to end, not just the registration. `hello-openmaxal` gains a
  media-player section that obtains Seek and PrefetchStatus through the new
  dispatch and golden-checks loop state, position seeks, the prefetch
  events mask, status and fill-level getters, and both rejection paths.
  Before this release both probes aborted at their first fatal stub.

## Verification

Full `berberis_arm64_host_tests` binary: **3,687 pass, zero failures**
(including the three new named-override registry tests); `libberberis_arm64`
and `libberberis_riscv64` both build clean. Sample suite **150/150 PASS**,
prebuilt-APK gate **15 PASS / 0 FAIL**. The microbenchmark sweep against the
committed baseline is within noise on every unflagged row — expected, since
the hook runs only at wrap time and no translator tier is touched.

---

# Digitalis — The First Gear Stops Dropping Regions: +23% Geekbench, 3DMark at 88% of Native (2026-08-14)

This release is about the lite translator's role as gatekeeper. Heavy, the
optimizing tier, is only attempted for a region that is already hot — and
hotness is counted by a profiling counter that lite installs into the region
*it* translated. A region lite cannot translate installs `kInterpreted`,
carries no counter, and can never gear up; a region lite translates only
partially is clamped at the failure point, leaving hot loops as fragments too
small for heavy to accept. Two first-gear gaps of exactly that shape were
found by measuring real apps instead of guessing, and closing them moved
third-party benchmarks by double digits.

- **FP across-lanes reductions and vector `FADDP` now translate in the lite
  tier.** `FMAXV`, `FMINV`, `FMAXNMV`, `FMINNMV` and the vector form of
  `FADDP` had no lite lowering, so every region containing one was installed
  as `kInterpreted` — and the heavy frontend's long-standing implementations
  of these very opcodes were unreachable, because nothing below them could
  gear up. The FP32 forms are lowered with NaN-correct MAXPS/MINPS folding
  sequences (`FMAXNMV`/`FMINNMV` first suppress single-input NaNs via a
  self-compare mask, so a NaN survives only if both inputs are NaN); the
  FP16 forms still go to the interpreter, pending an F16C round-trip.
  Measured on Geekbench 6.7.1 with the translator as the only change:
  **single-core 369 → 455 (+23%), multi-core 1138 → 1388 (+22%)**. Its
  Object Remover workload — an FP32 patch-reduction kernel that had sat
  roughly 20× below its neighbours — went 25 → 522 single-core.
- **Register pressure now spills instead of failing the region.** A
  14-app sweep with a temporary failure-logging diagnostic (the new
  `litefail-sweep.sh`) measured **70,246 lite-translation failures, 94% of
  them `STP`/`LDP`**: an SP-based pair op needs six scratch registers (base,
  address, and a top-byte-ignore mask plus data temp per element), but the
  old adaptive reservation could admit it with only four, so at the pressure
  wall every callee-save prologue and epilogue failed its region and forced a
  clamp-and-retranslate split — fragments that also fell under the heavy
  tier's gear-up minimum. The allocator now holds a fixed six-register temp
  reserve (permanent guest-register mappings cap at 7 of the 13-register
  pool) and the early pool-low region break is gone: a full pool spills
  through `ThreadState` and translation runs to the region's natural end.
  Re-running the same sweep: **70,246 → 707 events (−99%), `STP`/`LDP`
  eliminated entirely**. Register-heavy lite workloads improved (bcrypt
  hashpw −16%, secp256k1 sign −11%, pcre2 match −10%); nothing regressed
  beyond noise.
- **3DMark went from crashing to running — and the crash was the emulator's,
  not ours.** Wild Life died ~45 s into loading with an "out of memory"
  dialog that no amount of guest RAM changed. The released prebuilt
  emulator's gfxstream hard-clamps **every guest-visible Vulkan heap to
  2 GB** (removed upstream by gfxstream `07d70ebe` precisely because it
  breaks apps); Wild Life's allocations exceed that mid-loading, the failed
  `vkAllocateMemory` surfaced as a null mapping 3DMark never checks, and the
  workload died by SIGSEGV — reproduced byte-for-byte on the same APK's
  native x86_64 half, exonerating the translator. `deploy-emulator.sh` now
  documents this second reason to redeploy, and the diagnostic is one
  command: `adb shell cmd gpu vkjson` showing 2048 MiB heaps on a bigger
  GPU. With a fixed emulator the guest sees the real heaps and Wild Life
  runs to its scorecard.

**Where that leaves the yardsticks** (Ryzen 9 7950X / RX 7800 XT, translated
arm64 vs the same app's native x86_64 build on the same emulator):

| Benchmark | Translated | Native x86_64 | Ratio |
|---|---|---|---|
| 3DMark Wild Life | 11,019 (66.0 FPS, "Maxed Out" — frame-capped) | frame-capped too | at cap |
| 3DMark Wild Life Extreme | **4,801** (28.75 FPS) | 5,458 (32.69 FPS) | **88%** |
| Geekbench 6 single-core | **456** | 2,511 | 18% |
| Geekbench 6 multi-core | **1,372** | 7,136 | 19% |

Wild Life Extreme is GPU-bound, so 88% measures the whole stack — translated
render thread, gfxstream encode, host GPU — not translation alone; the
CPU-bound Geekbench ratios are the translator's own scoreboard. Against the
start of this optimization arc, Geekbench is up **+23.6% single / +20.6%
multi** (369/1,138 → 456/1,372).

Tooling and docs that made the above findable, all landed this cycle: the
in-app microbenchmark sweep gained a **native x86_64 baseline** mode and a
vs-native column in `benchmark-results.md`; a **full-app benchmark harness**
(`benchmark-apps.sh`) measures ABI-paired third-party apps with ABBA legs and
positive proof the translator was in the path; `litefail-sweep.sh` histograms
first-gear failures on real apps (its lesson is written into the docs: rank
coverage work from dynamic sweeps, never from static disassembly of stripped
libraries, whose constant pools decode as plausible SVE/SME garbage);
`benchmarking.md`, `how-it-works.md`, `unsupported-opcodes.md` and
`emulator-gfxstream-deploy.md` are updated to match.

## Verification

Full `Arm64*` host suite: **3,630 pass, zero failures**; `libberberis_arm64`
and `libberberis_riscv64` both build clean. Sample suite **141/141 PASS** and
the prebuilt-APK gate **15 PASS / 0 FAIL** — both re-run twice, on the
released emulator and again on the redeployed heap-clamp-free emulator. The
microbenchmark sweep was re-run after each translator change and
`benchmark-results.md` regenerated; every movement beyond noise is an
improvement, and the two-gear tier is flat where it should be.

---

# Digitalis — Ask the Allocator: a Derived Stride, a Stale-Library Fix, and a Clean Prebuilt Gate (2026-08-09)

Three fixes, each of which began as something that looked like a translator bug.

- **`ANativeWindow_lock`'s repaired stride is now derived from the host, not
  guessed from the format.** The previous fix substituted the stride YV12
  specifies, `ALIGN(width, 16)`. That is a statement about the format, not the
  buffer: row padding is the allocator's choice and varies with the gralloc and
  the buffer's usage, and a stride that disagrees with the allocation shears
  every row. The override now allocates a throwaway `AHardwareBuffer` with the
  same format, geometry and usage on a window's first locked frame and reads the
  luma `rowStride` out of `AHardwareBuffer_lockPlanes`, keeping the format rule
  only as a fallback. Cached per window — the consumer usage it needs is a binder
  round trip.
- **An updated app no longer runs the previous version's native code.** Guest
  libraries shipped inside an APK are extracted to `<app>/cache/berberis_extract/`,
  and the extracted copy was reused whenever a file of that name existed. An
  app's cache survives an update; the APK does not. A cached copy must now be
  newer than the APK it came from. The benchmark runner had been clearing app
  data to dodge this, and records that a stale extract once produced an entirely
  fictitious 7.7x translator regression.
- **`hello-nativewindow` covers the surface both of those live on.** A proxy that
  mis-marshals `ANativeWindow` does not crash, it produces wrong pixels. The
  sample writes a pattern that is a pure function of (x, y, frame), reads every
  posted frame back off an `ImageReader`, and re-derives that function on the
  consumer side. Six geometries including 642x362, whose 656-pixel rows exercise
  real padding, plus a case covering the attribute/query calls and the
  `dequeueBuffer`/`queueBuffer`/`cancelBuffer` loop engines use instead of
  `lock()` — 31 assertions over ~25 entry points, up from 7.

Three failures turned out not to be ours:

- **A CPU-written YV12 SurfaceView composites to blank green on this emulator**,
  identically in a build with no translation in it at all.
- **The emulator process itself aborts** when an app queries
  `VK_EXT_memory_budget`. It is gfxstream's host decoder: it reproduces on an
  older translator library and disappears under `-gpu swiftshader_indirect`.
  `digitalis/scripts/deploy-emulator.sh` builds an emulator carrying the fix.
- **WhatsApp's long-standing gate failure needed another app to be installed.**
  With a second Meta app present it routes its EULA into cross-app account
  linking, tears the EULA down, and builds a Play-Store-delivered download
  manager on the main thread against its own thread guard — on an image with no
  Play Store. Uninstalling the other app fixed it against an unchanged
  translator; reinstalling brought it back. WhatsApp has since fixed it, and the
  prebuilt gate is now **15 PASS / 0 FAIL**, its first clean sweep.

Benchmarks: five SIMD workloads (`srshl-requant`, `sqrshl-requant`,
`recip-newton`, `rsqrt-newton`, `bf16-narrow`) rejoin the sweep in the modules
that now own those instructions, at 37-64x over the interpreter with the second
gear fastest in all five. The results table is regenerated from a full
22-workload sweep, so every row again corresponds to something that runs.

---

# Digitalis — Green Video Fixed: the Stride an ANativeWindow Lock Forgot (2026-08-02)

Kuaishou's feed rendered **solid green** video over a working UI. The cause was
ours, one field wide.

- **`ANativeWindow_lock` reports `stride = 0` for planar-YUV windows, and we
  passed it through.** The single `ANativeWindow_Buffer::stride` field cannot
  describe a planar layout — those strides belong in `android_ycbcr`'s
  `ystride`/`cstride` — so the host leaves it unset, while the gralloc
  implementations such apps are written against report the luma stride there. A
  CPU-side renderer addresses row *y* at `bits + y * stride`, so a zero stride
  collapses every row onto row 0 and the buffer is posted essentially as
  allocated. An untouched YUV buffer is all zeros, and **Y=U=V=0 converts to
  exactly RGB(0,135,0)** — that colour is the signature of "never written". A
  chained override now fills in the stride the format mandates (16-pixel-aligned
  luma for YV12, tightly packed for the single-plane Y formats) *only* when the
  host returned success and left the field at zero. Measured at the boundary:
  stride 0 → 576 on a 572×1024 window, frame buffers going from untouched to
  carrying real luma, and the feed from 15 colours / 0.0% frame-to-frame change
  to 1905 colours / 57.5%.
- **A failed JIT code-region allocation no longer kills the app.** Exhausting
  memory mid-playback used to abort the process from `MmapImplOrDie` under
  `TryLiteTranslateAndInstallRegion`. The interpreter can always run any region,
  so this is recoverable: allocation failure now installs an interpreted entry
  instead.
- **The interpreter now applies ARM64 top-byte-ignore.** The lite and heavy
  tiers always had it; the interpreter did not, so Scudo's tagged heap pointers
  faulted and no statically linked binary could run interpret-only.
- **Two JIT tiers gained coverage**: SHA-256 in both (lite and heavy), plus
  FRECPS/FRSQRTS, BFCVTN, 32-bit SRSHL/SQRSHL, SSHL/USHL, 2D integer compares
  and scalar DUP in the heavy optimizer; and lite fixes for SBFX/SBFIZ, exact
  MRS/MSR NZCV and MRS FPCR. Per-mnemonic heavy coverage 89.5% → 91.4%.
- **Test suite 3,565 → 3,674.** New this cycle: a committed 48,032-encoding
  decoder-vs-objdump corpus, memory differential fuzzers for both JIT tiers, an
  interpreter memory-semantics golden set pinned against the ARM ARM, an IC IVAU
  invalidation test, and a per-tier translation-coverage table.

## Not ours, and now proven so

The `anon_inode:sync_file` fence-fd leak that accompanied the green video is
**not a Digitalis bug**. Rebuilding our own `native-activity` sample — which
draws through `ANativeWindow_lock` every frame — with `abiFilters = "x86_64"`
and running it natively on the same emulator leaks at **73.7/s**, against
**74.2/s** for the arm64-translated build. Same source, same device, same API
path; only the ABI differs, and the x86_64 process was confirmed to have zero
JIT regions mapped. It is emulator-side behaviour in the `dequeueBuffer` fence
path, unreachable from the translator.

Verified: `Arm64*` 3,674 passed (1 skipped, F16C-gated), both guest translators
build clean, samples 141/141, prebuilt gate 14 pass / 1 fail (WhatsApp's own
app-internal assertion), and no benchmark cell moved beyond noise across 22
workloads × 3 tiers.

---

# Digitalis — Width-Keyed Guest-Context Cache & the GWP-ASan Header Peek (2026-07-26)

Two silent-corruption fixes: no crash, no SIGILL, no JIT bail in either case.

- **The guest-context cache ignored access width.** Keyed on CPU-state byte offset
  alone, it forwarded a mapping established by a 64-bit `MOVSD` read of a vector
  register to a later 128-bit read — and `movsd xmm, m64` zeroes the upper half. A
  shipping bcrypt key schedule silently hashed wrong: correct under the interpreter
  and the lite tier, wrong under the default two-gear tier. Mappings now record
  `{size, is_simd}`, and the loop optimizer skips mixed-width slots. Pinned by four
  MachineIR unit tests and five guest-level differential regions.
- **`__wrap_realloc`'s Scudo header peek faulted into GWP-ASan guard pages.** The
  "emulator exhaustion" flake — a different app dying each run at `SEGV_ACCERR
  …ff0` — was random only in which process it hit. `free`'s page-boundary guard now
  covers `realloc` too, through one shared `InspectProbeHeader`.
- **Samples 138 → 140.** `hello-bcrypt` vendors the real crypt_blowfish/libbcrypt
  and reproduces the miscompile; `hello-blowfish` builds it from spec and does not.

Verified: `Arm64*` 3565 passed, riscv64 1144 passed, both translators build clean, samples 140/140, prebuilt gate 14 pass / 1 fail (WhatsApp's own app-internal assertion).

---

# Digitalis — Residual Sweep: FP16 FMA, IEEE CRC32, FCVTXN & Correctness Fixes for FP16 Converts and the ±0 Tie (2026-07-19)

The final coverage sweep over the "hard" residue — several items of which turned
out to be **correctness bugs, not missing performance**. `Arm64*` host suite
3517 → 3560 (+43, zero failures); both guest translators build clean; sample
suite 138/138; prebuilt gate 14 PASS / 1 FAIL (the known app-internal WhatsApp
assertion).

## Corrected — these were wrong, not just slow

- **FP16 scalar↔integer conversions** (FCVTZS/ZU/NS/…/AS/AU, SCVTF/UCVTF, incl.
  fixed-point) hit `Undefined()` or mis-scaled the fixed-point factor as FP64 in
  the interpreter — so they were *wrong everywhere* (the JITs bail to the
  interpreter). Now widen fp16→FP32 exactly and reuse the FP32 convert with the
  scale in the FP32 domain, then narrow RNE. The `FpSingleToHalfRN` helper was
  rewritten and verified bit-exact against hardware F16C over the full 2³²
  float space (0 non-NaN mismatches).
- **FP16 FMAX/FMAXNM *and* FMINNM ±0 tie:** returned −0h where ARM specifies
  max(+0,−0)=+0. Fixed in the lite and heavy tiers (the FP32/FP64 paths were
  already correct).

## FP16 FMA — the "must bail" verdict was wrong

The earlier note that FP16 fused multiply-add can't be JIT-lowered (double
rounding) was mistaken. The interpreter and lite tier already compute it
correctly by fusing in **FP64** — FP64's 53-bit mantissa ≥ 2·11+2, so
FP64-fuse-then-RNE-narrow-to-FP16 is correctly *single*-rounded — and only the
heavy tier bailed. Heavy now mirrors that FP64-fusion path (scalar
FMADD/FMSUB/FNMADD/FNMSUB + vector FMLA/FMLS `.4h`/`.8h`). A round-to-odd
approach was evaluated and rejected (it would diverge from the interpreter).

## Newly lowered

- **IEEE-802.3 CRC32B/H/W/X** (lite + heavy) via PCLMULQDQ reflected-Barrett
  reduction (gated `kHasCLMUL`, bit-exact against the interpreter, constants
  cross-checked against zlib's tables) — the "low-value, interpreter-only" item,
  now geared up. (Castagnoli CRC32C* was already lowered.)
- **FCVTXN/FCVTXN2** (`.2s←.2d` round-to-odd), heavy, via a **pure-SSE** recipe
  (round-trip inexact detection + LSB force — no MXCSR global-state hazard),
  verified bit-exact vs the interpreter over 20M fuzz doubles. This resolves the
  "needs MXCSR the heavy IR can't expose" deferral without any MXCSR.
- **FP16 FMULX** (0·∞→±2.0) and the **FP16 pairwise** family (FADDP/FMAXP/FMINP/
  FMAXNMP/FMINNMP), scalar + vector.

## Verified complete — nothing to implement

The **proxy surface** is confirmed clean: the bad-symbol enumerator reports
**0 uncovered** NDK-stable symbols (42 Digitalis-covered, exit 0); the
`eglGetProcAddress` failed-wrap log remains the standing watch signal for new
host-driver extensions.

## Documented deferrals (correct fallback in place)

Two items stay bailing by choice — both route to a correct fallback, both are
rare, both are high-risk to JIT-lower: scalar saturating shifts
SQSHL/UQSHL/SQRSHL/UQRSHL in heavy (a deeply branchy per-lane saturation
sequence; routes to lite) and the fp16-int-convert JIT fast path (routes to the
now-correct interpreter). And three remain blocked by disproportionate
infrastructure or lack of a host primitive, documented in
`unsupported-opcodes.md`: the `.2D`/64-bit-lane AVX-512 forms (need an EVEX
assembler backend + CPUID plumbing built first), SHA/SM3/SM4 (the assembler has
no SHA-NI ops and the ARM↔x86 rounds are non-isomorphic — hash-corrupting if
wrong; SM3/SM4/SHA512 have no x86 primitive), and SVE/SME/FP8 (a from-scratch
scalable-vector decode tree + Z/P register file; no Android user-space exposure).

## Samples

`hello-fp16arith` gains FP16-FMA (against an FP64-fusion oracle on a
non-exactly-representable case), FMULX, and the fp16↔int converts;
`hello-neonmisc` gains FCVTXN round-to-odd and IEEE CRC32 — all golden-checked,
verified on device.

---

# Digitalis — JIT Coverage Parity & the Second-Gear Sweeps: AES, Full LSE Atomics, FCSEL, FP16, I8MM/BF16, the NEON Residue & the ANGLE Extension-Proc Fix (2026-07-14 – 2026-07-19)

This update closes the JIT-lowering gaps where an instruction ran correctly in
the interpreter (or one JIT tier) but a hotter tier bailed — bringing the lite
and heavy tiers to parity with, and in places ahead of, Google's shipped
Berberis 16.0.0 (Android 17's `libndk_translation.so`) — and then sweeps the
heavy tier's remaining bail surface in two parallel agent-team batches. Across
the arc the `Arm64*` host suite grew **3246 → 3517 (zero failures)**, with both
guest translators building clean and the on-device sample + prebuilt gates
green. A proxy-layer fix also landed: `eglGetProcAddress` now honors the
*advertised-implies-non-NULL* contract for ANGLE extension procs, ending the
Chromium GPU-process crash loop.

## Fixed: eglGetProcAddress NULLed advertised ANGLE extension procs (Chromium GPU-process crash loop)

ANGLE as the host GLES driver returns a non-NULL dispatch stub from
`eglGetProcAddress` for every proc it knows, and advertises the matching
extensions in `GL_EXTENSIONS`. The upstream libEGL proxy trampoline NULLs the
guest return whenever its generated wrap table cannot marshal a proc. Callers
that gate on the extension *string* rather than the probed pointer then call
NULL: a Chromium 149 GPU process saw `GL_ANGLE_robust_client_memory`
advertised, called the NULLed `glGetIntegervRobustANGLE` at context init,
jumped to guest PC 0 (`berberis_HandleNoExec` SIGSEGV, crashpad-swallowed), and
crash-looped until the browser aborted with "Timed out waiting for GPU
channel". Pinned via `berberis.tracing` ("Trying to execute non-executable code
at 0x0"), disassembly of the extension-flag-gated call site, and a
`--disable-gl-extensions` falsification run.

The fix stays entirely in `binary_translation/`:

- **`proxy_loader`:** new `ProxyLibraryBuilder::RegisterExtraTrampolineOverrides`
  — a Digitalis extra trampoline can now override a symbol whose primary
  trampoline is *working* but incomplete. `InterceptSymbol` installs the
  override with a `ChainedTrampoline{primary_marshal, primary_thunk}` callee so
  it runs the upstream behavior first and only post-processes guest state
  (chain slots dedupe across per-namespace re-interception; arm64-only, riscv64
  byte-identical).
- **`digitalis_extra_proxy`:** a libEGL `eglGetProcAddress` override that chains
  to the upstream trampoline (its full core-GL wrap table intact) and, when
  upstream returned NULL for a host-present proc, wraps it from a demand-driven
  table of ~80 ANGLE/CHROMIUM procs: the full `GL_ANGLE_robust_client_memory`
  set, `get_tex_level_parameter`, `multi_draw`, `polygon_mode`,
  `request_extension`, `shader_pixel_local_storage`, `CHROMIUM_copy_texture`,
  `CHROMIUM_bind_uniform_location`, `memory_object_flags`, `vulkan_image`, the
  blob-cache and EGL-debug callback procs (guest callbacks wrapped with
  `WrapGuestFunction`), and the sync-control queries. Procs of extensions ANGLE
  never advertises on Android (D3D streams, Metal shared events, macOS GPU
  power) deliberately stay NULL.

The Chromium-based Helium browser now renders content-rich pages on the default
GPU path with zero GPU-process crashes (previously a crash every ~500 ms) and
passes the prebuilt gate.

## Crypto: AES on host AES-NI (lite + heavy)

`AESE`/`AESD`/`AESMC`/`AESIMC` were interpreter-only in both JITs. They now lower
to host AES-NI (bit-exact, gated on `kHasAES`): `AESE` = `PXOR`+`AESENCLAST`,
`AESD` = `PXOR`+`AESDECLAST`, and `AESIMC` = `AESIMC`. x86 has no standalone
MixColumns, but `AESMC(x) = AESENC(AESDECLAST(x,0),0)` — the `AESDECLAST`
InvSubBytes/InvShiftRows exactly cancel the `AESENC` SubBytes/ShiftRows, leaving
MixColumns. Validated against the interpreter's from-scratch FIPS-197 vectors.
(SHA/SM3/SM4 stay interpreter-only.)

## LSE atomics: from first internal loop to complete coverage

The heavy optimizer had no fast path for the LSE read-modify-write atomics that
`std::atomic` fetch_or/and/xor and lock-free containers emit everywhere. It
first gained `LDCLR`/`LDSET`/`LDEOR`, `LDSMAX`/`LDSMIN`/`LDUMAX`/`LDUMIN`
(32/64-bit) and the 32-bit `CASP` pair via a `LOCK CMPXCHG` retry loop — the
heavy frontend's **first internal back-edge loop** (tractable because memory is
re-read fresh each iteration, so nothing is carried across the back-edge and
the linear-scan register allocator handles it cleanly). The sweep then closed
the rest: byte and halfword forms (sized zero-extending loads +
`LOCK CMPXCHGB/W`, with per-width sign-extension discipline for the signed
min/max), and the 128-bit pair operations — `CASP` 64-bit and `LDXP`/`STXP` in
both pair widths — via `LOCK CMPXCHG16B`, the heavy tier's first instruction
with four simultaneous fixed-register constraints (RAX/RDX/RBX/RCX). The lite
tier gained `LDXP`/`STXP` pair-exclusive as well.

## FCSEL: the deliberate bail is gone

FCSEL was the last *common* scalar-FP op the heavy tier refused: an earlier
lowering had miscompiled inside real regions, so the frontend bailed with a
do-not-re-enable warning. The sweep reproduced that historical crash in a
region-interaction test and identified the root cause as the
stale-forwarded-guest-context-vreg bug — the old blend mutated the cached read
of its source register in place, and a later read in the same region saw the
select result. That optimizer bug has since been fixed generally, and the
re-landed lowering is additionally defensive: it blends in a private temp, never
mutating the cached source reads, so it is correct even without the optimizer
fix. Fifteen exec tests (isolated, region-interaction, loop) plus three new
region differential fuzzers guard it.

## FP16 in the second gear (scalar + vector core)

The whole scalar FP16 surface — arithmetic, min/max, `FSQRT`, the `FRINT*`
family, compares (incl. conditional), `FCVT` to/from half, and `FMOV` including
immediates — lowers via the F16C round-trip (isolate the half, widen, compute
in FP32, narrow with round-to-nearest-even), which is *correctly rounded* for
add/sub/mul/div/sqrt because FP32 carries more than twice FP16's precision.
The vector core (`.4h`/`.8h`) followed via the two-half variant of the same
recipe: three-same FADD/FSUB/FMUL/FDIV, FMAX/FMIN/FMAXNM/FMINNM, FABD and
compares, plus two-reg-misc FABS/FNEG (pure bit ops, ungated), FSQRT, FRINT*
and compare-vs-zero. FP16 fused multiply-add is **deliberately still a bail**
in both shapes (the round-trip would double-round), as are the FP16
pairwise/FCMA/convert residue. One tier-consistent quirk is documented: lite
and heavy FP16 FMAX/FMAXNM return −0h on the ±0 tie where ARM specifies +0h
(the FP32/FP64 paths are correct); a coordinated lite+heavy fix is a follow-up.

## SIMD extensions, dot products, complex arithmetic, CRC32C

- `SDOT`/`UDOT` (vector + by-element, incl. I8MM `USDOT`/`SUDOT`) lower in the
  heavy tier (`PMOVSXBW`/`PMOVZXBW` widen → `PMADDWD` → `PHADDD`), so hot
  quantized-ML kernels gear up; **I8MM matrix multiply** `SMMLA`/`UMMLA`/
  `USMMLA` and **BF16** `BFDOT`/`BFMMLA`/`BFMLALB`/`BFMLALT` (vector and
  indexed, mirrored bit-exactly from the lite tier) complete the ML set.
- FP32 `FCADD` (±90°) and `FCMLA` (all four rotations) lower in the heavy tier,
  then gained the indexed FP32 form (lane broadcast) and the `.2d` FP64 form.
- `CRC32C` (Castagnoli) lowers in the heavy tier via SSE4.2 `crc32` (it was
  lite-only).

## The NEON residue and scalar completions

- **Vector FP-misc:** `FABS`/`FNEG`/`FSQRT` (FP32 + FP64), `FACGE`/`FACGT`,
  `FCVTL`/`FCVTN` (FP32↔FP64), `SQABS`/`SQNEG`, and the `FRECPE`/`FRSQRTE` and
  `URECPE`/`URSQRTE` estimates — the unsigned pair via the architected
  512-entry estimate table, bit-exact against the interpreter (not the x86
  estimate instructions, which give different results).
- **Byte-lane NEON:** `MUL`/`MLA`/`MLS` `.8b`/`.16b` and the byte
  `SSRA`/`USRA`/`URSHR` shifts; then the insert/rounding shifts
  `SLI`/`SRI`/`SRSHR`/`SRSRA`/`URSRA`, which bailed in *both* JIT tiers — new
  common coverage implemented in the lite translator and the heavy optimizer
  with per-tier tests, interpreter as ground truth.
- **Scalar SIMD forms:** integer D-form three-same (`ADD`/`SUB`/compares),
  saturating `SQADD`/`UQADD`/`SQSUB`/`UQSUB` (all widths), shifts
  `SSHL`/`USHL`/`SRSHL`/`URSHL` (D), `FABD`/`FMULX`/`FRECPS`/`FRSQRTS` (S/D,
  with the 0×∞→±2.0 and Newton-step special-case ladders),
  `SQRDMLAH`/`SQRDMLSH` (H/S), scalar pairwise (`ADDP`,
  `FADDP`/`FMAXP`/`FMINP`/`FMAXNMP`/`FMINNMP`), and scalar by-element
  `FMUL`/`FMLA`/`FMLS`/`FMULX`.
- **Scalar FP completions:** FP64 `FCVTAS`/`FCVTAU` (ties-away, bit-mirroring
  the lite recipe), `BFCVT` (RNE + NaN quieting), and the top-half
  `FMOV V.D[1]` moves in both directions. `FCVTXN` was evaluated and
  deliberately left bailing: round-to-odd needs MXCSR rounding-mode control the
  heavy machine IR does not expose, and the op is rare with a correct lite
  fallback.

Eight machine-IR ops were added to the backend allowlist (SSE3 `HADDPS`,
`SQRTPS`/`SQRTPD`, the FP32↔FP64 packed converts, the F16C half↔single
converts, and `SHUFPD`). Integration of the parallel batches caught real
cross-slice defects each round — a register-class crash shape, wrong hardcoded
test encodings (incl. a spurious bit 18 in a test-encoder base that tripped 13
compile-time asserts), stale bails-tests, and a broken FCVT-double-to-half
path — the kind of defect only the combined tree exposes. The differential
fuzzers pass over all new families.

## Correctness: scalar by-element SQDMULH/SQRDMULH/SQDMULL

The scalar by-element `SQDMULH`/`SQRDMULH`/`SQDMULL` encodings were routed to
`Undefined()` → guest `SIGILL` for well-formed user-space instructions. The
interpreter now implements them (signed-saturating doubling-multiply: high-half
for SQDMULH/SQRDMULH, widening for SQDMULL); the JITs bail to it.

## Eight new on-device golden probes

Every new instruction group is regression-protected by a sample module in the
established abort-on-mismatch pattern — a hot loop past the gear-up threshold
so the heavy tier compiles the region, with any wrong value crashing the sample
so the suite flags it (the suite grew to 138 exercised modules):

- **`hello-fcma`** — FCADD/FCMLA, all four rotations, ×4000 each.
- **`hello-lseatomics`** — LDSET/LDCLR/LDEOR, LDSMAX/LDSMIN/LDUMAX/LDUMIN, CASP,
  ×4000 each, with signed-vs-unsigned min/max distinguishing cases.
- **`hello-eglext`** — the eglGetProcAddress extension-proc contract: enforces
  *advertised-implies-non-NULL* in a real ES2 context (the exact landmine
  behind the Chromium GPU-process crash aborts the sample), then calls the
  wrapped procs — robust getters cross-checked bit-exact against the core
  `glGet*` API ×100, plus the EGL-debug guest-callback registration.
- **`hello-fcsel`** — FCSEL S/D in the region shapes that once miscompiled:
  a not-taken select followed by a re-read of the true-side source, flags kept
  live across the select for a later consumer, and multiple selects per region.
- **`hello-fp16arith`** — the scalar FP16 surface checked against hardcoded
  FP16 bit patterns, a widen-compute-narrow reference on a different
  instruction path for rounding boundaries, and a vector `.8h` family with
  distinct high-lane values (catches a wrong high-half recombine).
- **`hello-i8mm-bf16`** — SMMLA/UMMLA/USMMLA, BFDOT/BFMMLA/BFMLALB/T and
  indexed FCMLA with hand-computed exact goldens.
- **`hello-lsepair`** — byte/halfword LSE fetch-and-ops with
  signed-vs-unsigned distinguishing values and zero-extension checks, CASP-64
  match/mismatch, and LDXP/STXP read-modify-write loops in both pair widths.
- **`hello-neonmisc`** — vector FP-misc, FCVTL/FCVTN, the estimates (checked
  against the architected error bound), SQABS/SQNEG saturation corners,
  byte-lane multiplies and the full byte shift set (incl. SLI/SRI keep-mask
  and SRSHR/SRSRA/URSRA rounding checks), scalar pairwise and scalar
  by-element FP.

## Verification

Full `Arm64*` host suite: 3246 → **3517 pass, zero failures** across the arc;
`libberberis_arm64` and `libberberis_riscv64` both build clean throughout.
Fresh full `m` image booted with the lib baked in (md5-verified); sample suite
**138/138 PASS** and the prebuilt gate **14 PASS / 1 FAIL**. Of the prebuilt
FAILs seen at the start of the arc: helium was root-caused to the
eglGetProcAddress gap above and now passes; the Honkai install-conflict was a
gate artifact (the already-installed original-signature copy is now reused and
launch-tested); WhatsApp's failure is its own in-app main-thread assertion
during EULA teardown (a pure Java stack with no translator frame) and remains
the one correctly-reported FAIL.

---

# Digitalis — App-Namespace Isolation Fix, Heavy-Tier NEON/FP Coverage & Golden-Checked ML Samples (2026-07-10)

This update fixes a namespace-isolation bug that crashed a major Unity game
under translation, broadens the heavy (second-gear) optimizer across a large
swath of NEON/FP instructions, and hardens the ML and framework samples into
real workloads asserting exact results.

- **Fixed: app-namespace symbol interposition.** Isolated app namespaces were
  given the guest system search path, letting an app's strong replaceable
  symbol (Unity's global `operator new` in `libunity.so`) interpose over
  non-public system libraries and crash (a SIGILL on libunity's encrypted
  lazy-init path). Digitalis now matches real Android: app namespaces stay
  isolated and reach public libraries only through `linkNamespaces()`; the
  game boots to its login screen.
- **Heavy optimizer: broad NEON/FP coverage.** Newly lowered in the second
  gear: the FP↔integer convert families (SCVTF/UCVTF/FCVTZS/FCVTZU, round-mode
  variants, ties-away), FRINT*, FSQRT, FMLA/FMLS/FMULX (incl. by-element),
  integer NEON min/max/pairwise/halving/abs-diff/widening-multiply families,
  saturating + polynomial multiplies, byte-lane SHL/SSHR/USHR, and D/S-pair
  LDP/STP in both JIT tiers. A region-level heavy-vs-interpreter differential
  fuzzer gates the expansion; a stale-forwarded-vreg backend bug was fixed.
- **Real ML inference, verified bit-exact.** hello-tflite (Conv2D→ReLU→Dense),
  hello-onnxruntime (Gemm→ReLU→Gemm) and hello-pytorch (Module.forward) now run
  real fixed-weight graphs asserting exact goldens (small-integer weights make
  float32 exact); a reproducible offline model toolchain
  (`sample/hellodigitalis/tools/`) generates the models. hello-nnapi,
  hello-fbjni, the audio samples and hello-binder-ndk gained golden asserts.
- **Verification:** host suite 3027/3027; both translators build; samples
  130 PASS / 0 CRASH.

---

# Digitalis — Crisp Web Text in Chromium Browsers (2026-06-30)

Fixes the long-standing garbled/sheared web-page text in Chromium-based
browsers under translation; article text now renders fully crisp, matching the
interpreter.

- **Root cause:** two single-region lite-JIT codegen bugs in the ARM64 vector
  fixed-point conversions SCVTF/UCVTF/FCVTZS/FCVTZU (which Skia uses for glyph
  coordinates/coverage): the vector forms emitted scalar codegen (only lane 0
  converted), and the first fix's up-front destination zeroing clobbered the
  source for in-place `rd == rn` forms. The shipped lowering converts per lane
  and zeroes only the unused high bytes afterwards. A latent interpreter UB
  (`1u << 64` scale at max fbits) was fixed in passing.
- **Method:** an exhaustive JIT-vs-interpreter differential (every
  `AdvSimdShiftByImm` encoding × input × `{rd != rn, rd == rn}`, 102,528
  cases) plus a high-register-pressure region fuzzer; both ship as permanent
  regression tests. A prior "region-structural, unreproducible" conclusion was
  wrong — both were ordinary single-instruction miscompiles.
- Region-marker hygiene was reconciled across shared upstream-derived files
  (comment-only).
- **Verification:** host suite 2534; screenshot suite 14/14; both translators
  build; Helium renders crisp on the emulator.

---

# Digitalis — On-Screen Rendering, New Samples & Binary Distribution (2026-06-21)

- **Guest `libgui.so` stub.** A rendering engine's Android layer `dlopen`s
  `libgui.so` and calls `android::Surface::hook_perform` on its present path;
  with no guest copy the call jumped to a host address (`berberis_HandleNoExec`
  SIGSEGV). A minimal guest-only stub (`digitalis_libgui_stub`, installed at
  `/system/lib64/arm64/libgui.so`) exports the hook as a no-op so the present
  path stays on the host-proxied route — a full guest libgui would fight the
  proxied path and is deliberately not shipped.
- **Sample suite → 116 modules:** Filament (+ gltfio and an on-screen
  `hello-filament-render` cube via the stub above), OpenBLAS, FFTW, GSL, Box2D,
  libyuv, Leptonica, Snappy, secp256k1.
- **Binary-only distribution:** Docker tooling (`digitalis/docker/`,
  `digitalis/scripts/`) packages the 74-artifact distribution set from
  `berberis_config.mk` with a generated consumer `.mk`; the `digitalis-build`
  container bind-mounts the host `out/` at the same path so nothing rebuilds.
- **Verification:** host suite 2460; sample, screenshot and prebuilt gates green.

---

# Digitalis — Sample-Suite Expansion & Heap-Lifetime Fixes (2026-06-20)

- **Sample suite 85 → 104:** ~20 third-party native-library samples added —
  Couchbase Lite, WCDB, libsodium, Argon2, Themis, ONNX Runtime, MediaPipe,
  Vosk, MapLibre, Rive, libavif, WebRTC, WireGuard, libtorrent4j, Duktape,
  J2V8, Javet, JavaCPP, JNA, fbjni.
- **Fixed: guest use-after-free vs the translator's arena (MapLibre).** A
  benign in-app UAF became fatal under translation because the shared host
  heap let the translator's bump arena re-grab and zero a still-referenced
  chunk. Root-caused with an in-process `mprotect` watchpoint; fixed with a
  bounded free-quarantine in the `--wrap=free` proxy so free timing matches
  hardware closely enough that benign guest UAFs stay benign.
- **Fixed: GWP-ASan guard-page underflow** in that free probe's 16-byte peek
  (skip the peek for page-boundary-adjacent pointers).
- **Noted:** a V8-embedding sample SIGABRT was a broken upstream arm64 AAR
  (compile-time sandbox mismatch), not a translator bug; pinned to a working
  version.

---

# Digitalis — Prebuilt-App Stability & Translator Update (2026-06-15)

Start of the prebuilt-APK stability campaign: real ARM64-only top apps and
games are installed, launched and soaked on the x86_64 emulator, and every
crash is fixed at its **root cause in the translator** — never the app.

- **Verified apps:** WeChat, WhatsApp, Facebook, Douyin, NetEase Cloud Music,
  Baidu Maps, AMap, Tencent Map, Tencent App Store, QQ Input, CoolApk,
  AliExpress, Brave, Firefox, Vulkan Caps Viewer; **games:** Crossy Road,
  Temple Run 1/2, Subway Surfers, Hill Climb Racing, Space Mafia; Kuaishou
  partial (a private host-graphics-library gap, closed in a later release).
- **Two-gear optimizing JIT became the default:** interpreter + lite
  single-pass first gear + a heavy second gear that lowers hot regions to SSA
  machine IR with global register allocation and loop optimization —
  neutral-or-faster than lite, ~2× on register-pressure-heavy loops, gear-up
  gated by region size.
- **Broad ISA coverage** across decoder/interpreter/lite: SM3/SM4, CRC32C,
  RNDR, I8MM dot/matmul, FMOV vector-imm, FCVTN/FCVTL, FRINTTS, FCMA, MTE tag
  group, LDXP/STXP, and correctness fixes surfaced by real apps (FCSEL
  aliasing, CCMN clobber, LDPSW sign-extension, IC IVAU self-modifying-code
  invalidation) — developed against a JIT-vs-interpreter differential-fuzzing
  harness.
- **Campaign fixes by theme:** anti-tamper SDK faults (fdsan-safe guest fd
  ops, SIGALRM deadman neutralization, CheckJNI null-`jclass` tolerance,
  hidden-API exemption + pending-exception clearing), WebView hardware-accel
  proxy coverage (17/18 symbols with host-VM thread attach), and fd/signal
  plumbing (fdsan-tag-correct `ScopedFd`).
- **Sample suite: 85 always-green modules** spanning platform APIs/graphics,
  21 ARM ISA probes, UI engines (Qt 6, React Native + Hermes, Lynx), 32
  third-party native libraries, and proxy/regression probes.
- **Known limitations:** residual crashes that are anti-emulator
  self-protection or GMS gaps (documented, not worked around); a host
  GFXStream `VK_EXT_memory_budget` clamp was needed for some games.
