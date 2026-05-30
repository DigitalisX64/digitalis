# ARM64 Opcode Support Gaps

Three kinds of gap exist in the Digitalis ARM64 backend:

1. **Not decoded — rejected inside the supported encoding space.** The decoder reaches the instruction but calls `Undefined()` because no handler has been written. Fatal decode error at runtime. Section 1 below.
2. **Not decoded — entire extension absent.** The decoder has no dispatch for the extension at all; instructions fall through to a high-level catch-all `Undefined()`. Section 2 below.
3. **Decoded and correct, but interpreter-only.** The instruction runs correctly, but the JIT (`lite_translator/arm64_to_x86_64/`) has no fast path for it. Every guest region containing one ends at that instruction, the interpreter executes it, and the dispatcher resumes JIT for the next region. Functionally correct, ~10–100× slower per instance. Section 3 below.

For everything that **is** JIT-translated (the fast path), see [Appendix B in `how-it-works.md`](how-it-works.md#appendix-b-arm64-to-x86_64-instruction-mapping).

> **The JIT has expanded enormously.** Earlier revisions of this document listed almost the entire NEON compute surface — element-wise arithmetic, logical, compare, min/max, shifts, widening, pairwise, reductions, the scalar/vector FP families, FCSEL, scalar FP conversions, fused multiply-add — as interpreter-only. **Nearly all of it is now JIT-lowered.** Likewise, several whole extensions previously listed as absent (FP16, PAC, FCMA, JSCVT, BFloat16, DotProd, LSE, LRCPC, BTI) are now decoded and executed. The lists below reflect the current state; see [§0](#0-what-changed) for a summary of what moved.

All line references are into `frameworks/libs/binary_translation/decoder/include/berberis/decoder/arm64/decoder.h` unless noted. The decoder is actively evolving — **re-validate line numbers against the codebase before relying on them.**

---

## 0. What changed

The following were listed as *unsupported* or *interpreter-only* in older revisions of this doc and are **now implemented**:

| Area | Now | Path |
|---|---|---|
| **Half-precision (FP16) scalar** — `FADD/FSUB/FMUL/FDIV/FMAX/FMIN/FNMUL H`, `FABS/FNEG/FSQRT/FRINT* H`, `FCVT` to/from H, FP16 compare, FP16 `FCCMP`/`FCCMPE` | Decoded + executed | The historic `if (ftype >= 2) Undefined()` gate is fully closed — all FP16 scalar forms decode. JIT via host F16C round-trip. |
| **FP16 vector** — three-same, two-reg-misc, scalar three-same, indexed `FMLA/FMLS/FMUL` | Decoded + JIT (F16C) | `DecodeAdvSimdFp16ThreeSame`, `…Fp16TwoRegMisc`, `…ScalarFp16ThreeSame` |
| **Scalar FP conversions** — `FCVTZS/FCVTZU/SCVTF/UCVTF`, `FCVTNS/MS/PS/AS…`, fixed-point conversions | JIT | `FpIntConversion`, `FpFixedPointConversion` |
| **`FCSEL`**, **`FMADD/FMSUB/FNMADD/FNMSUB`**, **`FABS/FNEG/FSQRT`**, **`FRINT*`** scalar | JIT | `FpCondSelect`, `FpDataProc3` (host-FMA), `FpDataProc1` |
| **NEON element-wise / logical / compare / min-max / halving / SABD / PMUL / SQDMULH** | JIT | `AdvSimdThreeSame` |
| **Saturating & rounding shifts by register** (`SSHL/USHL/SRSHL/URSHL/SQSHL/UQSHL/SQRSHL/UQRSHL`) | JIT | `AdvSimdThreeSame` |
| **Vector shifts by immediate** (`SSHR/USHR/SSRA/USRA/SHL/SLI/SRI/SQSHRN…`) | JIT | `AdvSimdShiftByImm` |
| **Widening MUL/MAC** (`SMULL/UMULL/SMLAL/UMLAL/SMLSL/UMLSL`) + widening add/sub (`SADDL/UADDL/SSUBL/…`) + by-element forms incl. `SQDMULL/SQDMLAL/SQDMLSL` | JIT | `AdvSimdThreeDiff`, `AdvSimdVecXIndexedElement` |
| **Single-source vector** (`ABS/NEG/NOT/CNT/CLS/CLZ/REV16/32/64`), **reductions** (`ADDV/SADDLV/UADDLV/SMAXV/…`), **pairwise** (`ADDP/SADDLP/UADDLP/SADALP/UADALP`) | JIT | `AdvSimdTwoRegMisc`, `AdvSimdThreeSame` |
| **AdvSimdScalarTwoRegMisc** (`FCVTXN/SCVTF/UCVTF/FCVTZS/FCVTZU/FCVTAS/FCVTAU/SQABS/SQNEG/FRECPE/FRSQRTE/SQXTN/UQXTN/SQXTUN`) | JIT | `AdvSimdScalarTwoRegMisc` |
| **Vector FP** (`FADD/FSUB/FMUL/FDIV/FMLA/FMLS/FMULX/FMAX/FMIN/FMAXNM/FMINNM/FCMEQ/FCMGE/FCMGT/FACGE/FACGT/FABD/FRECPS/FRSQRTS`) | JIT | `AdvSimdThreeSame` |
| **Permute / copy / extract / table** (`DUP/INS/UMOV/SMOV`, `ZIP/UZP/TRN`, `EXT`, `TBL/TBX`) | JIT | `AdvSimdCopy/Permute/Extract/TableLookup` |
| **PAC** (`PACIA/AUTIA/XPAC…`, `BRAA/BLRAA/RETAA/RETAB`, `PACGA`) | Decoded (PAC-blind / identity) | `DataProc1Src` (0x40 marker), `DecodeBranchReg`, `DataProc2Src` |
| **FCMA** (`FCADD/FCMLA` vector + indexed) | JIT | `AdvSimdFcma`, `AdvSimdFcmaIdx` |
| **JSCVT** (`FJCVTZS`) | JIT | `FpIntConversion` |
| **BFloat16** (`BFDOT/BFMMLA/BFMLALB/BFMLALT/BFCVT/BFCVTN`) | JIT (+ BFCVTN interpreter) | `AdvSimdBf16ThreeSame`, indexed BF16 |
| **DotProd** (`SDOT/UDOT` + indexed) | JIT | `AdvSimdDotProduct` |
| **RDM** (`SQRDMLAH/SQRDMLSH` vector + scalar + indexed) | JIT | `AdvSimd…RdmThreeSame` |
| **LSE atomics** (`LDADD/LDCLR/LDEOR/LDSET/LDSMAX/…/SWP/CAS/CASP`) | Decoded | `DecodeAtomicMemoryOp`, `DecodeLoadStoreExclusive` |
| **LRCPC** (`LDAPR`) | Decoded | `DecodeAtomicMemoryOp` |
| **BTI** (`BTI c/j/jc`) | Decoded as `HINT` → no-op | runs, provides no CFI protection |
| **CRC32 / Crypto** (`CRC32*`, `AES*`, `PMULL`, `SHA1/SHA2/SHA512`) | Decoded + interpreter-executed | see [§3](#3-decoded-and-correct-but-interpreter-only) |

The host-test exec suite that pins these (`lite_translate_region_exec_tests.cc`) now holds **~2070 cases**, up from ~45 when this doc was first written.

---

## 1. Rejections inside the supported encoding space

The decoder reaches these instructions but explicitly calls `Undefined()` because no handler has been written. They produce a fatal decode error at runtime. (Reserved/invalid encodings that *correctly* decode to `Undefined()` are not listed here.)

| Family | Instructions | ARM rev | Evidence |
|---|---|---|---|
| **Exception-generating (non-SVC)** | `BRK #imm`, `HLT #imm`, `HVC`, `SMC`, `DCPS1/2/3` | ARMv8.0 | Only `SVC` is decoded in the exception-generation class; everything else → `Undefined()` (`decoder.h` ~2321). Sanitizer / debug builds that emit `BRK` will fault. |
| **Add/subtract immediate with tag (MTE)** | `ADDG`, `SUBG` | ARMv8.5-MTE | `decoder.h` ~2032 — tagged add/sub-immediate not implemented. |
| **Bounded FP rounding** | `FRINT32X`, `FRINT32Z`, `FRINT64X`, `FRINT64Z` (vector + scalar) | ARMv8.5 | `decoder.h` ~5514 — vector two-reg-misc bounded-rounding opcodes rejected. |
| **MTE tag-block ops** | `LDGM`, `STGM`, `STZGM` | ARMv8.5-MTE | Not in the load/store-tag dispatch (`DecodeLoadStoreMemTag`). The tag *load/store* ops `STG/LDG/STZG/ST2G/STZ2G` and DP `SUBP/SUBPS/IRG/GMI` **are** decoded. |

**Note on BTI:** `BTI c/j/jc` is encoded as a `HINT` and routes to `Nop()`. It doesn't fault — it just has no effect. Apps relying on BTI for control-flow integrity won't get protection on Digitalis, but they will run.

---

## 2. Entire ARM extensions with no decoder dispatch at all

The decoder has no case for these — the instruction bits hit a high-level catch-all and produce `Undefined()`. None are encountered in typical Android NDK apps today.

| Extension | ARM rev | Representative instructions | Where it lands |
|---|---|---|---|
| **Int8 matrix multiply (I8MM)** | ARMv8.6 | `SMMLA`, `UMMLA`, `USMMLA`, `SUDOT`, `USDOT` | catch-all `Undefined()` (`DecodeSimdFp` ~3590). *Note: `SDOT`/`UDOT` (v8.4 DotProd) **are** implemented — only the v8.6 matmul/mixed-sign forms are absent.* |
| **SM3 / SM4** | ARMv8.2 | `SM3SS1`, `SM3TT1A/B`, `SM3TT2A/B`, `SM3PARTW1/2`, `SM4E`, `SM4EKEY` | ~3590. *SHA3 (`EOR3`/`BCAX`/`RAX1`/`XAR`) is now decoded + interpreter-executed.* |
| **SVE** (Scalable Vector Extension) | ARMv8.2 / v9 | All Z-register ops: predicated arithmetic, gather/scatter, FFR, reductions, permute (`SPLICE/COMPACT/REV/UZP/ZIP/TRN`), `PTRUE`, `WHILELT`, … | top-level `Undefined()` (`DecodeInstruction` default ~2009, `op0 ∈ {0001,0010,0011}`) |
| **SVE2** | ARMv9 | Multiply, bitwise, bit-permute, FP, crypto-helper SVE2 instructions | ~2009 |
| **SME** (Scalable Matrix Extension) | ARMv9.2 | `ZA` tile access, `MOVA`, `ADDHA/ADDVA`, `SMOPA/UMOPA/…`, SME load/store, streaming-mode entry/exit | ~2009 |
| **FP8 / FAMINMAX / LUT** | ARMv9.x | FP8 convert/dot, `FAMAX/FAMIN`, `LUTI2/LUTI4` | ~3590 |

**RNG note:** `MRS Xd, RNDR` / `MRS Xd, RNDRRS` are *decoded* (they reach the `Mrs` consumer like any other system-register read); correctness depends on the `Mrs` handler, which does not currently return real entropy.

---

## 3. Decoded and correct, but interpreter-only (no JIT path)

These run correctly but force the dispatcher out of the JIT. The lite translator either has no case-arm or explicitly bails (`success_ = false`); the interpreter (`interpreter/arm64/interpreter.h`) implements them. All line refs in this section are into `lite_translator/arm64_to_x86_64/lite_translator.h`.

### Vector narrowing / lengthening / reciprocal-estimate
| Instructions | Why interpreter-only |
|---|---|
| `SQXTN`, `UQXTN`, `SQXTUN`, `FCVTN`, `FCVTL`, `FCVTXN` (vector), `SHLL` | No vector case-arm in `AdvSimdTwoRegMisc`. *(`XTN`/`XTN2` **are** now JIT-lowered via mask-then-pack; scalar `SQXTN/UQXTN/SQXTUN/FCVTXN` are JIT in `AdvSimdScalarTwoRegMisc`.)* |
| `RBIT` (vector), `URECPE`, `URSQRTE`, `SUQADD`, `USQADD` | No vector case-arm. |

### Three-different (widening) — the non-JIT subset
| Instructions | Why interpreter-only |
|---|---|
| `SQDMULL/SQDMLAL/SQDMLSL` (vector three-diff form) | No three-diff case-arm. *(The **by-element** forms **are** JIT in `AdvSimdVecXIndexedElement`.)* |
| `ADDHN`, `SUBHN`, `RADDHN`, `RSUBHN` | Narrowing add/sub — no JIT path. |
| `PMULL`/`PMULL2` with `.8H` (size=00) | Only the `.1Q` (size=11) form is JIT-lowered via `PCLMULQDQ`. |

### Vector immediate
| Instructions | Why interpreter-only |
|---|---|
| `MOVI`/`MVNI`/`ORR #imm`/`BIC #imm`/`FMOV #imm` (vector forms) | `SimdModifiedImm` JIT-lowers **only** `MOVI Vd.2D, #0` (→ `pxor`); all other modified-immediate forms bail. |

### Structure load/store (de-interleaving)
| Instructions | Why interpreter-only |
|---|---|
| `LD2/LD3/LD4`, `ST2/ST3/ST4`, multi-register single-structure (`num_regs > 1`) | Only contiguous `LD1/ST1` and single-element `LD1R`/`LD1`/`ST1` (`num_regs == 1`) are JIT'd. |

### CRC32 and crypto
| Instructions | Why interpreter-only |
|---|---|
| `CRC32B/H/W/X`, `CRC32CB/CH/CW/CX` | No `DataProc2Src` JIT arm; software polynomial in the interpreter (Digitalis-specific addition). |
| `AESE/AESD/AESMC/AESIMC`, `SHA1*`, `SHA256*`, `SHA512*` | JIT bails with `Undefined()` in the crypto handlers; interpreter executes. |

### Scalar bitfield & system
| Family | Instructions | Notes |
|---|---|---|
| Byte-reverse 16 | `REV16 Xd, Xn` (scalar) | No JIT arm in `DataProc1Src` (scalar `REV/REV32/CLZ/RBIT` *are* JIT). |
| System registers (MRS/MSR) | Everything except `NZCV`, `CTR_EL0`, `DCZID_EL0`, `MIDR_EL1`, `TPIDR_EL0` | The JIT handles those five; all other reads/writes bail to the interpreter (mostly modelled as constants / no-ops). |
| MTE data-processing & load/store | `IRG/GMI/SUBP/STG/LDG/…` | Decoded, but the JIT bails (`MteDataProc`/`MteLoadStore`); interpreter executes. |

### Host-feature-gated fast paths
Where the host x86_64 CPU lacks a feature, the corresponding JIT path bails to the interpreter (still correct, just slower):
| Guest family | Host feature required |
|---|---|
| All FP16 (`F16C` round-trip) | `F16C` |
| `FMADD/FMSUB/FNMADD/FNMSUB` and FMA-based FP-vector MAC | `FMA` |
| `.2D` signed arithmetic shifts (`SSHR/SSRA/SRSHR/SRSRA` scalar/`.2D`) | `AVX-512` (`VPSRAQ`) — bails on baseline x86_64 |
| Any `FP128` / `ftype == 0b10` scalar FP | n/a (reserved/quad — not lowered) |

### Why this matters

The interpreter is ~10–100× slower per instruction than JIT-translated code, and each interpreter-only instruction forces a region exit plus a dispatcher round-trip. For a tight inner loop, a single interpreter-only opcode can dominate runtime. With the NEON compute surface now largely JIT-lowered, the remaining high-value promotions are narrower:

| Promotion target | Typical app affected |
|---|---|
| Vector narrowing `XTN`/`SQXTN`/`FCVTN` | Pixel format conversion, audio downsampling, quantized ML |
| De-interleaving `LD2`/`LD3`/`LD4` | Interleaved RGBA / planar-audio / vertex streams |
| Vector `MOVI`/`MVNI` immediate forms | Constant-vector setup in shader/DSP prologues |
| `CRC32*` | zlib/zstd framing, filesystem checksums |

---

## 4. Practical impact

What matters in practice for ARM64-only Android apps on the Digitalis emulator:

| Group | Apps likely to hit it | Severity |
|---|---|---|
| **`BRK` exception ops** | Sanitizer builds (ASAN/UBSAN/HWASAN), debug builds | **Medium** — affects developer/debug flows; still a hard `Undefined()`. |
| **Vector narrowing / de-interleave (perf)** | Image/audio codecs, quantized ML, interleaved I/O | **Medium** — correct but interpreter-slow on hot kernels. |
| **CRC32 (perf)** | Compression/IO-heavy apps | **Low–Medium** — correct, interpreter-speed. |
| **SHA / AES (perf)** | TLS, content hashing | **Low–Medium** — correct, interpreter-speed; most TLS goes through host BoringSSL/Conscrypt anyway. |
| **I8MM matmul** | Newer ML inference kernels | **Low–Medium** — `SDOT/UDOT` covered; only v8.6 matmul forms fault. |
| **MTE tag-block / `ADDG/SUBG`** | Opt-in memory-tagging hardening | **Low** — rarely emitted by NDK toolchains today. |
| **SHA3 / SM3 / SM4** | Region-specific crypto | **Low**. |
| **SVE / SVE2 / SME** | Effectively no shipping Android apps (no Android device exposes them to user code yet) | **None**. |

FP16, PAC, FCMA, JSCVT, BFloat16, DotProd, LSE, LRCPC and BTI — all previously called out as risks here — are now decoded and executed, so they no longer gate app bring-up.

---

## 5. Where to add support

For instructions in [Section 1](#1-rejections-inside-the-supported-encoding-space) (already in the decoder's reach):

| Layer | File | What to add |
|---|---|---|
| **Decoder** | `decoder/include/berberis/decoder/arm64/decoder.h` | Replace the `Undefined()` with `insn_consumer_->Xxx(args)` |
| **Semantics bridge** | `decoder/include/berberis/decoder/arm64/semantics_player.h` | Add `Xxx()` forwarding the structured args to the consumer |
| **Interpreter** | `interpreter/arm64/interpreter.h` | Implement `Xxx()` |
| **JIT (optional)** | `lite_translator/arm64_to_x86_64/lite_translator.h` | Implement `Xxx()` for the hot path |
| **Tests** | `lite_translator/arm64_to_x86_64/lite_translate_region_exec_tests.cc` | Add a region exec test exercising the new instruction |

For [Section 3](#3-decoded-and-correct-but-interpreter-only) (decoded, needs a JIT fast path), only the JIT case-arm and a region exec test are needed — the decoder and interpreter already handle the instruction.

For entire extensions in [Section 2](#2-entire-arm-extensions-with-no-decoder-dispatch-at-all), the decoder needs new top-level dispatch cases under the relevant `op0` bit pattern in `DecodeInstruction()` first.

---

*Re-validate against the codebase before relying on the line numbers — the decoder and lite translator are actively evolving.*
