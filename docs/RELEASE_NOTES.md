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
swath of NEON/FP instructions so real apps' hot loops stay on the optimizing
path, and hardens the machine-learning and framework samples into real workloads
that assert an exact result — including ARM64 TensorFlow Lite, ONNX Runtime and
PyTorch Mobile now running real fixed-weight inference on the x86_64 emulator,
each verified **bit-exact** against a golden.

## Fixed: app-namespace symbol interposition (Honkai: Star Rail)

Isolated app classloader namespaces were given the guest `/system/lib64/arm64`
search path, which — combined with the guest linker config's single flat
`default` namespace — let an app load its own copies of non-public system
libraries (`libutils`, `libc++`, `libandroid_runtime`, …) directly into its own
scope. An app library's strong replaceable symbol then interposed for them —
notably Unity's `GLOBAL operator new` in `libunity.so` — so a system library
calling `operator new` was routed into the app's not-yet-initialized allocator
and crashed. Honkai: Star Rail hit this as a SIGILL on libunity's encrypted
lazy-init path.

Real Android keeps app namespaces isolated: an app reaches the NDK public
libraries through the framework's `linkNamespaces()` link to the system
namespace (shared instances that keep their own symbol scope), never by loading
system libraries into its own namespace. Digitalis now does the same — it no
longer appends the guest system path to app namespaces for the arm64 guest,
while proxy/public libs (`libandroid.so`, `libvulkan.so`, `libEGL.so`, …) still
resolve through the existing link to the guest `default` namespace. The riscv64
guest keeps its prior behaviour behind the guest-arch guard. Honkai: Star Rail
now reaches its login screen instead of crashing.

## Heavy optimizer: broad second-gear NEON/FP coverage

The heavy (second-gear) optimizer gained a large batch of instruction lowerings
so that hot regions in real apps engage the optimizing tier instead of silently
bailing to the single-pass lite tier. A bail is correct-but-slow, and for common
NEON/FP instructions it kept whole loops on the slow path. Newly lowered in the
second gear:

- **FP ↔ integer converts**: scalar and vector SCVTF / UCVTF / FCVTZS / FCVTZU,
  the round-mode variants FCVTNS/NU/PS/PU/MS/MU and ties-away FCVTAS / FCVTAU,
  across S and D forms.
- **FP rounding & math**: FRINTN/M/P/Z/X/I/A (scalar and vector), FSQRT,
  FMLA / FMLS, FMULX, and indexed (by-element) FMUL / FMLA / FMLS.
- **Integer NEON**: SMAX/SMIN/UMAX/UMIN and pairwise SMAXP/SMINP/UMAXP/UMINP +
  ADDP, halving add/sub (S/U/R HADD/HSUB), abs-diff/accumulate
  (SABD/UABD/SABA/UABA), widening multiply/accumulate
  (SMULL/UMULL/SMLAL/UMLAL/SMLSL/UMLSL, including by-element), BIC/ORN/CMTST.
- **Saturating & polynomial**: SQDMULH/SQRDMULH, SQDMULL/SQDMLAL/SQDMLSL,
  SQABS/SQNEG, SQXTN/UQXTN/SQXTUN, SUQADD/USQADD, and PMUL/PMULL/PMULL2.
- **Shifts & pair loads**: byte-lane SHL/SSHR/USHR (.8B/.16B), and D/S-pair
  LDP/STP — the last two now handled in both the lite and heavy tiers.

A region-level heavy-vs-interpreter differential fuzzer was added to gate the
expansion, and a backend codegen bug (a stale forwarded guest-context vreg
surviving a redefine) was fixed along the way.

## Real ML inference, verified bit-exact

Three ML samples previously only loaded their runtime and round-tripped a tensor
through the JNI bridge. They now build and run a real graph and check the output:

- **hello-tflite** runs a Conv2D(3×3) → ReLU → Flatten → Dense graph — exercising
  the TFLite convolution dot-product and fully-connected NEON kernels — and
  asserts the output `[27, 8, 13]`, replacing the trivial `out = 3·in` placeholder.
- **hello-onnxruntime** runs an ONNX `Gemm → ReLU → Gemm` graph via
  `OrtSession.run` and asserts `[-7, 16, -1]`.
- **hello-pytorch** runs a lite-interpreter TorchScript module
  (`Linear → ReLU → Linear`) via `Module.forward` and asserts `[-7, 16, -1]`.

Each model uses small-integer weights and inputs, so the float32 arithmetic is
exact and order-independent — the result is bit-identical on the host (where the
golden is computed) and on the device (where the translated kernels run). A
translator miscompile in the conv/GEMM/ReLU path now changes the numbers and
trips the golden instead of passing silently; on the emulator all three run with
`maxErr = 0.0`.

## Deeper self-checks across the suite

Several other samples gained deterministic golden assertions in place of
load-only smoke tests:

- **hello-nnapi** builds, compiles and executes a real two-op NNAPI graph
  (MUL then ADD with constant operands) and verifies the output tensor.
- **hello-fbjni** drives fbjni's *hybrid dispatch* end to end — a C++
  `HybridClass` peer created via `makeCxxInstance`, called through the generated
  native-method thunk (the machinery React Native and PyTorch Mobile rely on) —
  and asserts the returned value, not just that the library loaded.
- **hello-aaudio / hello-oboe / native-audio** checksum a deterministic
  synthesized PCM/DSP waveform and assert a golden, exercising the audio
  generation path.
- **hello-binder-ndk** marshals a typed payload through `AIBinder_transact` and
  asserts the round-tripped value.

## Reproducible model toolchain

A new `sample/hellodigitalis/tools/` toolchain generates the ML models offline:

- `setup-ml-generators.sh` bootstraps CPython 3.10 and three isolated,
  version-pinned virtualenvs matched to the on-device runtime AAR versions
  (torch 1.13.1, onnx 1.16.2 + onnxruntime 1.22.0, tensorflow-cpu 2.16.1).
- Per-sample `gen_model.py` scripts build each fixed-weight network, print the
  golden, and write the model straight into the sample's `assets/`.
- `README-ml-models.md` documents the full install → generate → verify workflow.

## Verification

Both `libberberis_arm64` and `libberberis_riscv64` build clean; the Arm64 host
test suite passes 3027/3027 (the heavy-tier lowerings ship with per-instruction
and region-level differential tests); and the sample suite is 130 PASS / 0 CRASH.
On the emulator, Honkai: Star Rail no longer hits the libunity operator-new
SIGILL, and the deepened ML/framework samples pass the on-device status gate and
are perturbation-proven (a wrong golden fails with the real translated value
shown).

# Digitalis — Crisp Web Text in Chromium Browsers (2026-06-30)

This update fixes garbled, sheared web-page text in Chromium-based browsers under
translation — the long-standing glyph-rendering issue. Helium (Chromium 149) now
renders article text **fully crisp**, matching the interpreter. The root cause was
two single-region lite-JIT codegen bugs in the ARM64 vector fixed-point conversion
instructions, both found with exhaustive host JIT-vs-interpreter differentials.

## Fixed: garbled web-text glyphs in Chromium / Skia

Chromium rasterizes glyph coordinates and coverage through the ARM64 vector
fixed-point conversions SCVTF / UCVTF / FCVTZS / FCVTZU (the `AdvSimdShiftByImm`
opcodes `0b11100` / `0b11111`). Two lite-JIT codegen bugs in those handlers
corrupted the converted values, so the renderer's web-content text — but not the
host-rendered browser chrome — came out sheared and fragmented, with some glyphs
missing entirely:

- **Only lane 0 was converted.** The handlers emitted scalar codegen (convert
  `Vn` lane 0, zero the rest of `Vd`) that the vector `.2S` / `.4S` / `.2D` forms
  also reached, so half — or three-quarters — of every converted vector came out
  zero. That sheared the rasterized text.
- **In-place conversions clobbered their source.** The per-lane fix initially
  zeroed `Vd` up front, which destroys `Vn` for the very common in-place forms
  (`ucvtf v0, v0` / `fcvtzs v0, v0`, which Skia applies to coordinate vectors),
  zeroing the result and blanking specific diagonal-stroke glyphs (w, v, k, A, T).
  The shipped fix writes each lane before reading the next and zeroes only the
  unused high bytes after the loop, so `rd == rn` is safe.

A latent interpreter undefined-behaviour bug in the same instructions — the `.2D`
maximum-fbits encoding computed its scale as `1u << 64` — was fixed in passing (it
now uses `ldexp`).

A prior investigation had concluded the corruption was an unreproducible
"cross-region / region-structural" effect. It was not: both bugs are ordinary
single-instruction miscompiles. An exhaustive `AdvSimdShiftByImm`
JIT-vs-interpreter differential — every encoding × input × `{rd != rn, rd == rn}`,
102,528 cases — pinned the lane-drop, and a high-register-pressure region fuzzer
surfaced the in-place clobber. Both differentials ship as permanent regression
tests. All three translation tiers are correct: the interpreter already looped
every lane (only the UB scale was fixed there), the lite JIT is fixed here, and the
heavy optimizer bails these instructions to the now-correct lite tier.

## Housekeeping: region-marker hygiene

Several Digitalis additions to shared, upstream-derived Berberis files were not
wrapped in the `// region digitalis` markers that keep the Digitalis delta
auditable and the upstream riscv64 build byte-for-byte unchanged. Authorship was
reconciled with `git blame` and the missing markers were added — comment-only, no
code changes — across the `kernel_api` guest `/proc/cpuinfo` path, the fork-safe
code pool, the JNI host-VM helper, the native-bridge namespace logging, and the
`arm64_to_x86_64` backend build modules.

## Verification

The Arm64 host test suite (**2534** tests), the rendering screenshot suite
(**14/14**), and both `libberberis_arm64` and `libberberis_riscv64` build clean.
On the emulator, Helium renders article text fully crisp, and the prebuilt-APK
gate is green except for two documented non-translator issues (a WhatsApp
app-level EULA lifecycle exception and a flaky Kuaishou media-player
missing-`libgui.so` gap).

---

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
