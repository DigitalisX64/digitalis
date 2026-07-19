# ARM64 Opcode Support Gaps

> **Status verified 2026-07-19** against the current decoder, lite translator,
> and heavy optimizer. This document describes the *current* state only; the
> history of coverage promotions lives in `RELEASE_NOTES.md`.

Four kinds of gap exist in the Digitalis ARM64 backend:

1. **Exception-generating instructions.** How `SVC`/`BRK`/`HLT`/`HVC`/`SMC`/`DCPS` are decoded and turned into guest signals. None abort the translator. Section 1 below.
2. **Not decoded — entire extension absent.** The decoder has no dispatch for the extension at all; instructions fall through to a high-level catch-all `Undefined()`. Section 2 below.
3. **Decoded and correct, but interpreter-only.** The instruction runs correctly, but the JIT (`lite_translator/arm64_to_x86_64/`) has no fast path for it. Every guest region containing one ends at that instruction, the interpreter executes it, and the dispatcher resumes JIT for the next region. Functionally correct, ~10–100× slower per instance. Section 3 below.
4. **Decoded and lite-translated, but heavy-tier-only.** The instruction runs correctly and even has a first-gear (lite) JIT fast path, but the second-gear **heavy optimizer** doesn't translate it yet, so a hot region containing one can't gear up. A *performance* gap only, never an `Undefined arm64 instruction`. Section 3a below.

A note on tiers: ARM64 guest code runs through three translation tiers — the **interpreter**, the **lite translator** (first-gear single-pass JIT), and the **heavy optimizer** (second-gear optimizing JIT, the default for hot regions). Gaps 1–3 are about correctness/coverage and apply to the lite + interpreter path. The heavy optimizer (gap 4) is a *performance* tier on top of that: an instruction it doesn't yet translate doesn't fail — the heavy frontend bails and the region keeps running its lite/interpreter translation, correctly, just without the second-gear speedup. So a "heavy-tier gap" is never an `Undefined arm64 instruction`; it only means a hot region containing that instruction won't gear up.

For everything that **is** JIT-translated (the fast path), see [Appendix B in `how-it-works.md`](how-it-works.md#appendix-b-arm64-to-x86_64-instruction-mapping). This document lists only what remains unsupported, interpreter-only, or lite-only (no heavy-tier fast path).

All line references are into `frameworks/libs/binary_translation/decoder/include/berberis/decoder/arm64/decoder.h` unless noted. The decoder is actively evolving — **re-validate line numbers against the codebase before relying on them.**

---

## 1. Exception-generating instructions

There are currently **no exception-generating instructions that abort the translator.** `SVC`, `BRK`, and `HLT` are decoded and deliver the correct synchronous guest signal (`SVC` → syscall, `BRK`/`HLT` → guest `SIGTRAP`). `HVC`, `SMC`, and `DCPS1/2/3` are UNDEFINED at EL0 and route through `Undefined()`, which delivers `SIGILL` to the guest — the architecturally-correct result for user-space — without aborting the translator. (Reserved/invalid encodings that *correctly* decode to `Undefined()`/`SIGILL` are expected behaviour, not gaps.)

**Note on BTI:** `BTI c/j/jc` is encoded as a `HINT` and routes to `Nop()`. It doesn't fault — it just has no effect. Apps relying on BTI for control-flow integrity won't get protection on Digitalis, but they will run.

---

## 2. Entire ARM extensions with no decoder dispatch at all

The decoder has no case for these — the instruction bits hit a high-level catch-all and produce `Undefined()`. None are encountered in typical Android NDK apps today.

| Extension | ARM rev | Representative instructions | Where it lands |
|---|---|---|---|
| **SVE** (Scalable Vector Extension) | ARMv8.2 / v9 | All Z-register ops: predicated arithmetic, gather/scatter, FFR, reductions, permute (`SPLICE/COMPACT/REV/UZP/ZIP/TRN`), `PTRUE`, `WHILELT`, … | top-level `default: Undefined()` (`DecodeInstruction`, `decoder.h:1985`, `op0 ∈ {0001,0010,0011}`) |
| **SVE2** | ARMv9 | Multiply, bitwise, bit-permute, FP, crypto-helper SVE2 instructions | same — `decoder.h:1985` |
| **SME** (Scalable Matrix Extension) | ARMv9.2 | `ZA` tile access, `MOVA`, `ADDHA/ADDVA`, `SMOPA/UMOPA/…`, SME load/store, streaming-mode entry/exit | same — `decoder.h:1985` |
| **FP8 / FAMINMAX / LUT** | ARMv9.x | FP8 convert/dot, `FAMAX/FAMIN`, `LUTI2/LUTI4` | no dedicated dispatch — these are SIMD&FP encodings (`op0 = x111`) that enter `DecodeSimdFp()` (`decoder.h:3045+`) and bottom out in one of its `Undefined()` paths |

**Deliberately deferred:** SVE/SVE2/SME/FP8 are a from-scratch undertaking (new Z/P register state, a separate decode tree, gather/scatter) and **no Android device exposes them to user code**, so they remain documented gaps rather than committed work. Note the blocker is structural, not per-instruction: SVE/SME need a whole new scalable-vector decode tree and the Z/P (data + predicate) register file added to the guest CPU state before any single instruction can be handled.

---

## 3. Decoded and correct, but interpreter-only (no JIT path)

These run correctly but force the dispatcher out of the JIT. The lite translator either has no case-arm or explicitly bails (`success_ = false`); the interpreter (`interpreter/arm64/interpreter.h`) implements them. All line refs in this section are into `lite_translator/arm64_to_x86_64/lite_translator.h`.

### Vector saturating accumulate
| Instructions | Why interpreter-only |
|---|---|
| `SUQADD/USQADD` **.1D/.2D only** | The 64-bit-element mixed-sign saturating accumulate needs 65-bit saturation logic. The `.8B/.16B/.4H/.8H` and `.2S/.4S` forms are JIT-lowered. |

### Dot-product / matrix-multiply (I8MM) — none interpreter-only
`USDOT/SUDOT` (vector + by-element) and `SMMLA/UMMLA/USMMLA` are all JIT-lowered (per-operand widening + `PMADDWD`, with `PHADDD` folds for the matrix forms).

### CRC32 and crypto
| Instructions | Why interpreter-only |
|---|---|
| `CRC32B/H/W/X` (IEEE) — **now JIT-lowered** (lite + heavy) | The IEEE 802.3 polynomial (0x04C11DB7) differs from the host SSE4.2 `crc32` (Castagnoli) instruction, so it is lowered via `PCLMULQDQ` reflected-Barrett reduction (per-size fold constants, gated on `kHasCLMUL`, bit-exact against the interpreter). The Castagnoli `CRC32C*` group is likewise JIT-lowered (host `crc32`). Neither is interpreter-only any more — listed here only to record the distinct lowering. |
| `SHA1*`, `SHA256*`, `SHA512*`, `SM3*`, `SM4*` | JIT bails in the crypto handlers; interpreter executes. Two independent blockers, both correctness-critical (a wrong hash-round silently corrupts output): (1) the x86_64 assembler has **no SHA-NI instruction definitions** (`sha1rnds4`/`sha1nexte`/`sha256rnds2`/`sha256msg1`/`sha256msg2` are absent from `insn_def_x86.json`), so even the SHA1/SHA256 forms that host SHA-NI *could* accelerate would need new assembler ops first; and (2) the ARM and x86 SHA round instructions decompose the compression function differently (non-isomorphic — ARM does a different bundling of rounds/message-schedule per instruction), so the mapping is subtle and easy to get wrong. `SHA512`/`SM3`/`SM4` have **no x86 baseline primitive at all**. Deferred as low-value: the interpreter is correct, and Android crypto routes through host BoringSSL/Conscrypt, so these guest instructions are rarely executed. `PMULL/PMULL2` (`.1Q` via `PCLMULQDQ`, `.8H` via per-bit widening) **is** JIT-lowered. `AESE/AESD/AESMC/AESIMC` are JIT-lowered in both the lite and heavy tiers via host AES-NI (gated on `kHasAES`): `AESE`=`PXOR`+`AESENCLAST`, `AESD`=`PXOR`+`AESDECLAST`, `AESMC`=`AESENC(AESDECLAST(x,0),0)` (the standalone-MixColumns identity), `AESIMC`=`AESIMC`. |

### Scalar system
| Family | Instructions | Notes |
|---|---|---|
| System registers (MRS/MSR) | Everything outside the small JIT-modelled set | The JIT lowers `MRS` reads of `NZCV`, `CTR_EL0`, `DCZID_EL0`, `MIDR_EL1`, `TPIDR_EL0` and `MSR` writes of `NZCV`, `TPIDR_EL0` (`lite_translator.h:796`/`850`); every other read/write bails to the interpreter, which models a larger set (FPCR/FPSR, RNDR/RNDRRS, CNTFRQ/CNTVCT/CNTPCT_EL0, …) as constants / no-ops. Low-value to promote — rarely on a hot path. |
| MTE data-processing & load/store | `IRG/GMI/SUBP/STG/LDG/…` | Decoded, but the JIT bails (`MteDataProc`/`MteLoadStore`); interpreter executes with no-MTE-backing semantics. Rarely hot. |

### Host-feature-gated fast paths
Where the host x86_64 CPU lacks a feature, the corresponding JIT path bails to the interpreter (still correct, just slower):
| Guest family | Host feature required |
|---|---|
| All FP16 (`F16C` round-trip) | `F16C` |
| `FMADD/FMSUB/FNMADD/FNMSUB` and FMA-based FP-vector MAC | `FMA` |
| `CRC32CB/CH/CW/CX` (Castagnoli) | `SSE4.2` (`crc32`) — bails to the software-polynomial interpreter path when absent |
| Any `FP128` / `ftype == 0b10` scalar FP | n/a (reserved/quad — not lowered) |

The 64-bit-element signed arithmetic shifts (`SSHR/SSRA/SRSHR/SRSRA` scalar-D and `.2D`) are **not** gated on AVX-512 (`VPSRAQ`): the lite translator lowers them unconditionally via a 64-bit-GPR `Sarq` fallback (load each lane with `Movq`, `Sarq` by the shift count, write back), so they JIT on baseline x86_64. Only the reserved `.1D` form bails (`lite_translator.h:20446`).

### Why this matters

The interpreter is ~10–100× slower per instruction than JIT-translated code, and each interpreter-only instruction forces a region exit plus a dispatcher round-trip. For a tight inner loop, a single interpreter-only opcode can dominate runtime. The remaining interpreter-only compute paths are all low-value (rare or routed elsewhere):

| Promotion target | Status |
|---|---|
| IEEE `CRC32*` | Deferred — `PCLMULQDQ` per-size reflected-Barrett; zlib on Android uses software tables, not the intrinsic |
| `SHA1*` / `SHA256*` | Deferred — non-isomorphic SHA-NI mapping; crypto routes through host BoringSSL. (`AES*` is now JIT-lowered via AES-NI, above.) |
| `SUQADD/USQADD .1D/.2D` | Deferred — 64-bit-element 65-bit saturation; vanishingly rare |

Everything not listed in the tables above is JIT-lowered; the promotion history
(what moved from interpreter-only to the JITs and when, including the past
`SIGILL`/mis-decode correctness fixes) is recorded in `RELEASE_NOTES.md`.

---

## 3a. Heavy-tier-only gaps (lite/interpreter cover them; heavy bails)

These instructions are fully supported and correct via the lite translator and/or interpreter; the **heavy optimizer** (`heavy_optimizer/arm64/frontend.{h,cc}`) just doesn't translate them yet, so a hot region containing one bails out of the second gear and keeps running its lite translation — correct, only without the heavy-tier speedup. This is a *performance* gap, never an `Undefined arm64 instruction`.

A heavy bail is mechanical: the frontend callback calls `UndefinedReturningVoid()`/`UndefinedReturningReg()` → `Undefined()`, which sets `success_ = false`, appends a `PseudoJump(kExitGeneratedCode)`, and makes every later read-helper return a dead temp and every write-helper a no-op (so no IR lands in the already-terminated block). The runtime then re-lite-translates the whole region (`runtime/arm64/translator_x86_64.cc`), and the region settles permanently at the lite tier.

The heavy tier now mirrors essentially the whole lite-tier surface: the
common integer/branch/load-store core, scalar FP including FP16 (F16C-gated)
and FCSEL, the broad NEON compute families (three-same, three-different,
two-reg-misc, shifts, by-element, permute/copy/table, structured load/store),
the SIMD extensions (dot product, I8MM matmul, BF16, FCMA incl. indexed and
`.2d`), the full LSE atomics, CRC32C, AES, and the architected estimates.
For the complete per-instruction mapping see Appendix B of
[`how-it-works.md`](how-it-works.md); this document tracks only the remainder
below.

Still **heavy-tier-only** (the heavy frontend bails; lite/interpreter handle them). Grouped by family:

| Family | Bails on | Notes |
|---|---|---|
| Integer | *(none remaining — `ADC`/`SBC`, `RBIT`, and 64-bit `EXTR` now lower)* | The integer core is fully heavy-lowered. |
| System | `MRS` (any sysreg ≠ `TPIDR_EL0`), `MSR`, `IC IVAU`, `SVC`, `BRK` | Side-effecting / runtime-handled; heavy declines. |
| MTE | `ADDG`/`SUBG`, `IRG`/`GMI`/`SUBP`, `LDG`/`STG`/… | `MteDataProc`/`MteLoadStore` bail. |
| Scalar FP | FP16 scalar↔int converts (JIT fast path only — see note) | FP16 FMA now **lowers** (scalar + vector) by fusing in FP64, not FP32: FP64's 53-bit mantissa ≥ 2·11+2, so FP64-fuse-then-RNE-narrow-to-fp16 is correctly single-rounded (the earlier "must bail" note was wrong — interpreter and lite already did this). The FP16↔int scalar *conversions* are now **correct in all tiers** (they were mis-handled before); only the lite/heavy JIT fast path is unwritten, so those bail to the now-correct interpreter — a performance-only gap on a rare op. |
| NEON (residual) | all `.2D`/64-bit-lane integer forms (§3a.1, hardware-conditional); the FP16 vector residue — FMLA/FMLS (double-rounding unsafe), FMULX/FRECPS/FRSQRTS, the FP16 pairwise family, FP16 FCADD/FCMLA, and the FP16 vector converts/estimates; scalar saturating shifts `SQSHL`/`UQSHL`/`SQRSHL`/`UQRSHL` (a deeply branchy per-lane saturation sequence — routes correctly to lite; a rare op, so the heavy lowering is a low-value/high-risk perf gap left as-is) | Newly lowered: `FCVTXN`/`FCVTXN2` (round-to-odd, via a pure-SSE inexact-detect + LSB-force — no MXCSR needed), FP16 `FMULX` and the FP16 pairwise family, and FP16 vector FMA (FP64 fusion). The FP16 FMAX/FMAXNM/FMINNM ±0-tie bug (returned −0h where ARM says +0h) is **fixed** in both JIT tiers. |
| SIMD extensions | *(none remaining at baseline)* | The FP16 FCMA forms ride the FP16 row above. |
| Atomics (LSE) | *(none remaining)* | The full LSE surface lowers in all widths, including the pair forms via `LOCK CMPXCHG16B`. |
| Crypto | `AES*`, `SHA1*`/`SHA256*`/`SHA512*`, `SM3*`/`SM4*`, `EOR3`/`BCAX`/`RAX1`/`XAR` | Heavy bails (these are interpreter-only even at the lite tier — see §3). |

### 3a.1 Permanently-deferred `.2D` / 64-bit-lane forms (hardware-conditional, not translator gaps)

A distinct sub-class of the heavy bails above is **not** "not-yet-implemented" — it is **blocked by the absence of an AVX-512 backend in the translator** (and, for a few, SSE4.1/4.2). SSE2-era x86 has no 64-bit-lane packed integer compare, min/max, or multiply, and no packed FP64↔int64 convert; those ops exist only in AVX-512F-VL / AVX-512DQ (or SSE4.1/4.2 for the equality/greater-than compares), which are **EVEX-encoded**. The blocker is concrete and structural, not per-instruction: (1) the x86_64 assembler (`assembler/instructions/insn_def_x86.json`) has **no EVEX encoding support at all** — adding the `.2D` ops means first building an EVEX encoder (a new instruction-encoding format, a multi-part backend project), and (2) `runtime_primitives/platform.h` has **no AVX-512 capability flag** — the ops would additionally need CPUID detection plumbed through so they gate correctly and fall back on hosts without AVX-512. Because these `.2D` (and equivalent scalar-`D`/`.1D`) forms already run correctly via the lite/interpreter 64-bit-GPR fallbacks, the cost of an EVEX backend vastly exceeds the value (a second-gear speedup on 64-bit-lane SIMD, uncommon in real Android hot loops). This is a *hardware-conditional performance* characteristic behind a disproportionate infrastructure prerequisite, **not a translator gap and not a bug**. A future sweep should **not** re-chase these per-instruction — the correct unit of work here is "add an EVEX assembler backend + AVX-512 CPUID gating," after which the `.2D` lowerings become a small follow-up.

| `.2D` / 64-bit-lane family | Missing host op | Where it bails |
|---|---|---|
| Integer compare `CMEQ`/`CMGT`/`CMGE`/`CMHI`/`CMHS`/`CMTST` `.2D` | `PCMPEQQ` (SSE4.1) / `PCMPGTQ` (SSE4.2) for the 64-bit lane | `AdvSimdThreeSame` compare handlers (`frontend.h:~3006`, `~4404`, `~4455`) |
| Signed/unsigned min/max `SMAX`/`SMIN`/`UMAX`/`UMIN` and pairwise `SMAXP`/`SMINP`/`UMAXP`/`UMINP` `.2D` | `PMAXSQ`/`PMINSQ`/`PMAXUQ`/`PMINUQ` (AVX-512F-VL) | min/max + pairwise handlers (`frontend.h:~3715`, `~4155`, `~4304`) |
| Vector multiply `MUL` `.2D` | `VPMULLQ` (AVX-512DQ) — no SSE packed 64-bit multiply | `AdvSimdThreeSame` MUL (`frontend.h:~3387`) |
| Packed FP64↔int64 vector converts `FCVTZS`/`FCVTZU`/`SCVTF`/`UCVTF` `.2D` | `CVTTPD2QQ`/`CVTUQQ2PD` (AVX-512DQ) — no SSE packed FP64↔int64 convert (the FP32 `.2S`/`.4S` forms use `CVTTPS2DQ`); the scalar-`D` forms *are* heavy-lowered via the GP recipe | vector two-reg-misc convert (`frontend.h:~6545`) |
| Saturating add/sub `SQADD`/`UQADD`/`SQSUB`/`UQSUB` `.2D`; mixed-sign `SUQADD`/`USQADD` `.1D`/`.2D` | No SSE saturating 64-bit-lane add/sub; 65-bit saturation logic (see §3 — interpreter-only even at lite) | saturating handlers; `SUQADD`/`USQADD .1D/.2D` interpreter-only |
| Narrowing `SQXTN`/`SQXTUN`/`SQXTN2`/`SQXTUN2` from `.2D` (`.2S`←`.2D` manual 64-bit saturation) | No SSE 64→32 saturating pack | narrow handler (`frontend.h:~4564`) |

The signed arithmetic-shift `.2D` forms (`SSHR`/`SSRA`/`SRSHR`/`SRSRA`) are **not** in this list: the lite tier already lowers them unconditionally via a 64-bit-GPR `Sarq` fallback (see §3), so they do not depend on AVX-512 `VPSRAQ`.

---

## 4. Practical impact

What matters in practice for ARM64-only Android apps on the Digitalis emulator:

| Group | Apps likely to hit it | Severity |
|---|---|---|
| **IEEE CRC32 (perf)** | Compression/IO-heavy apps | **Low** — only the IEEE `CRC32*` polynomial is interpreter-speed; `CRC32C*` is JIT'd, and zlib uses its own software tables. |
| **SHA / AES (perf)** | TLS, content hashing | **Low–Medium** — correct, interpreter-speed; most TLS goes through host BoringSSL/Conscrypt anyway. |
| **`SUQADD/USQADD .1D/.2D`, MTE, non-modelled MRS/MSR (perf)** | Vanishingly rare | **None–Low** — correct, interpreter-speed; not on real hot paths. |
| **SVE / SVE2 / SME / FP8** | Effectively no shipping Android apps (no Android device exposes them to user code yet) | **None** — documented deferred gap. |
| **Heavy-tier-only ops (§3a: the `.2D` hardware-conditional forms, SHA/SM3/SM4, scalar saturating shifts, fp16-int-convert JIT, residual scalar-SIMD variants)** | Any app with a hot loop over one of these | **None–Low** — correct via lite/interpreter; the only cost is that such a hot region can't gear up. The FP16 surface (arith, FMA, FMULX, pairwise, converts), FCVTXN, IEEE/Castagnoli CRC32, the full LSE atomics, I8MM/BF16/FCMA, and the vector/scalar SIMD residue all gear up. |

The only remaining decoder gaps are the SVE/SME/FP8 scalable/matrix extensions (no Android user-space exposure). The remaining heavy-tier gaps (§3a) are purely a second-gear performance consideration, not a correctness gap. Within §3a, the `.2D` / 64-bit-lane forms of §3a.1 are **hardware-conditional** — they bail because the host emulator baseline lacks AVX-512 (a few need SSE4.1/4.2), not because the translator is missing an implementation; they are correct-and-slow via the lite/interpreter 64-bit-GPR fallbacks and are expected to stay heavy bails on any AVX-512-less host.

---

## 5. Where to add support

For a decoded-but-`Undefined()` instruction that should instead execute (already in the decoder's reach):

| Layer | File | What to add |
|---|---|---|
| **Decoder** | `decoder/include/berberis/decoder/arm64/decoder.h` | Replace the `Undefined()` with `insn_consumer_->Xxx(args)` |
| **Semantics bridge** | `decoder/include/berberis/decoder/arm64/semantics_player.h` | Add `Xxx()` forwarding the structured args to the consumer |
| **Interpreter** | `interpreter/arm64/interpreter.h` | Implement `Xxx()` |
| **Lite JIT (optional)** | `lite_translator/arm64_to_x86_64/lite_translator.h` | Implement `Xxx()` for the first-gear fast path |
| **Heavy JIT (optional)** | `heavy_optimizer/arm64/frontend.{h,cc}` | Translate `Xxx()` so hot regions containing it can gear up to the second gear |
| **Tests** | `lite_translator/arm64_to_x86_64/lite_translate_region_exec_tests.cc`, `heavy_optimizer/arm64/frontend_tests.cc` | Add a region exec test per tier exercising the new instruction |

For [Section 3](#3-decoded-and-correct-but-interpreter-only) (decoded, needs a JIT fast path), only the JIT case-arm and a region exec test are needed — the decoder and interpreter already handle the instruction.

For [Section 3a](#3a-heavy-tier-only-gaps-liteinterpreter-cover-them-heavy-bails) (decoded and lite-translated, but the heavy frontend bails) only the heavy frontend case-arm and a `frontend_tests.cc` exec test are needed — closing one of these lets a hot region gear up, but the instruction already runs correctly without it.

For entire extensions in [Section 2](#2-entire-arm-extensions-with-no-decoder-dispatch-at-all), the decoder needs new top-level dispatch cases under the relevant `op0` bit pattern in `DecodeInstruction()` first.

---

*Re-validate against the codebase before relying on the line numbers — the decoder, lite translator, and heavy optimizer are actively evolving.*
