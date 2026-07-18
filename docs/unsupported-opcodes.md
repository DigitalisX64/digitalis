# ARM64 Opcode Support Gaps

> **Status re-verified 2026-07-14** against the current decoder, lite translator (`.inc` split), and heavy optimizer (`frontend.cc`). §2 (SVE/SME/FP8 absent) is unchanged. §3 changed: **AES (`AESE/AESD/AESMC/AESIMC`) is now JIT-lowered via AES-NI** (lite + heavy) — only SHA/SM3/SM4 and IEEE-CRC32 remain interpreter-only crypto; scalar by-element `SQDMULH`/`SQRDMULH`/`SQDMULL` (previously `Undefined()`→`SIGILL`) are now implemented. §3a (heavy-tier coverage) was expanded again — the LSE bitwise + min/max atomics + `CASP` 32-bit pair, `CRC32C`, `SDOT`/`UDOT`, and FP32 `FCADD`/`FCMLA` now lower in the second gear (the heavy frontend gained its first internal `CMPXCHG` back-edge loop). §3a.1 (hardware-conditional `.2D`) is unchanged.

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

**Deliberately deferred:** SVE/SVE2/SME/FP8 are a from-scratch undertaking (new Z/P register state, a separate decode tree, gather/scatter) and **no Android device exposes them to user code**, so they remain documented gaps rather than committed work — per the project plan's beyond-manual tier.

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
| `CRC32B/H/W/X` (IEEE only) | The IEEE 802.3 polynomial (0x04C11DB7) differs from the host SSE4.2 `crc32` (Castagnoli) instruction. A `PCLMULQDQ` reflected-Barrett lowering is possible but needs per-size folding constants (the reduction exponent is `x^{8·nbytes}`, differing for B/H/W/X); deferred as high-effort/low-value since the interpreter is correct and zlib on Android uses its own software tables rather than the ARM CRC32 intrinsic. The Castagnoli `CRC32C*` group **is** JIT-lowered (host `crc32`). |
| `SHA1*`, `SHA256*`, `SHA512*`, `SM3*`, `SM4*` | JIT bails in the crypto handlers; interpreter executes. The ARM and x86 SHA instruction sets decompose rounds differently (non-isomorphic), so a correct SHA-NI mapping is high-effort; deferred as low-value (Android crypto routes through host BoringSSL/Conscrypt, rarely executing these guest instructions). `PMULL/PMULL2` (`.1Q` via `PCLMULQDQ`, `.8H` via per-bit widening) **is** JIT-lowered. `AESE/AESD/AESMC/AESIMC` are **now** JIT-lowered in both the lite and heavy tiers via host AES-NI (gated on `kHasAES`): `AESE`=`PXOR`+`AESENCLAST`, `AESD`=`PXOR`+`AESDECLAST`, `AESMC`=`AESENC(AESDECLAST(x,0),0)` (the standalone-MixColumns identity), `AESIMC`=`AESIMC`. |

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

The 64-bit-element signed arithmetic shifts (`SSHR/SSRA/SRSHR/SRSRA` scalar-D and `.2D`) are **no longer** gated on AVX-512 (`VPSRAQ`): the lite translator lowers them unconditionally via a 64-bit-GPR `Sarq` fallback (load each lane with `Movq`, `Sarq` by the shift count, write back), so they JIT on baseline x86_64. Only the reserved `.1D` form bails (`lite_translator.h:20446`).

### Why this matters

The interpreter is ~10–100× slower per instruction than JIT-translated code, and each interpreter-only instruction forces a region exit plus a dispatcher round-trip. For a tight inner loop, a single interpreter-only opcode can dominate runtime. The remaining interpreter-only compute paths are all low-value (rare or routed elsewhere):

| Promotion target | Status |
|---|---|
| IEEE `CRC32*` | Deferred — `PCLMULQDQ` per-size reflected-Barrett; zlib on Android uses software tables, not the intrinsic |
| `SHA1*` / `SHA256*` | Deferred — non-isomorphic SHA-NI mapping; crypto routes through host BoringSSL. (`AES*` is now JIT-lowered via AES-NI, above.) |
| `SUQADD/USQADD .1D/.2D` | Deferred — 64-bit-element 65-bit saturation; vanishingly rare |

Recently promoted to the JIT (no longer interpreter-only): the AES crypto instructions (`AESE/AESD/AESMC/AESIMC` via AES-NI, lite + heavy); vector `FCVTN`/`FCVTL` (incl. FP16), the `.2D→.2S` saturating extracts, `URECPE`/`URSQRTE`, the I8MM `USDOT/SUDOT/SMMLA/UMMLA/USMMLA` family, `.2S<-.2D` `ADDHN/SUBHN/RADDHN/RSUBHN`, `.2S/.4S` `SUQADD/USQADD`, scalar `REV32`, and `PMULL`. The `ORR/BIC #imm` vector forms were also corrected to read-modify-write (they previously replaced `Vd`).

Correctness fix (was `Undefined()`→`SIGILL`, now implemented in the interpreter with the JITs bailing to it): **scalar by-element `SQDMULH`/`SQRDMULH`/`SQDMULL`** (`AdvSimdScalarXIndexedElement`, opcodes 1100/1101/1011). These well-formed user-space encodings previously raised a guest `SIGILL`; the interpreter now computes the signed-saturating doubling-multiply (high-half for SQDMULH/SQRDMULH, widening for SQDMULL). The lite tier also gained native **`LDXP`/`STXP`** pair-exclusive lowering (via `CMPXCHG16B`).

AdvSIMD modified-immediate correctness fix: **`FMOV` (vector, immediate)** (`cmode=0b1111`) was unimplemented in `ExpandSimdModifiedImm` (interpreter) and its JIT mirror — it byte-replicated `imm8` instead of running `VFPExpandImm`, so `fmov v.4s, #1.0` (`imm8=0x70`) yielded `0x70707070` (≈2.97e29f) per lane instead of `0x3F800000`. This corrupted any NEON `floorf()`/area computation that materialises a float constant via FMOV immediate — Unity 6 (Crossy Road, Temple Run 2) computed a garbage allocation size (`-N<<32`) and self-aborted with `raise(SIGTRAP)`. Now implements `VFPExpandImm` for single- and double-precision FMOV vector immediates in both backends (`op=1/cmode=0b1111`, `fmov v.2d`, was also mis-routed to MVNI). Covered by `FmovImm4S`/`FmovImm2D` exec tests.

---

## 3a. Heavy-tier-only gaps (lite/interpreter cover them; heavy bails)

These instructions are fully supported and correct via the lite translator and/or interpreter; the **heavy optimizer** (`heavy_optimizer/arm64/frontend.{h,cc}`) just doesn't translate them yet, so a hot region containing one bails out of the second gear and keeps running its lite translation — correct, only without the heavy-tier speedup. This is a *performance* gap, never an `Undefined arm64 instruction`.

A heavy bail is mechanical: the frontend callback calls `UndefinedReturningVoid()`/`UndefinedReturningReg()` → `Undefined()`, which sets `success_ = false`, appends a `PseudoJump(kExitGeneratedCode)`, and makes every later read-helper return a dead temp and every write-helper a no-op (so no IR lands in the already-terminated block). The runtime then re-lite-translates the whole region (`runtime/arm64/translator_x86_64.cc`), and the region settles permanently at the lite tier.

The heavy optimizer **now translates** (current `frontend.{h,cc}` coverage). The first gear's whole "common integer + branch + load/store" core is mirrored here, plus several recent SIMD/FP/atomic additions:

- **Integer ALU (immediate & register):** `ADD`/`SUB`/`ADDS`/`SUBS`/`CMP`/`CMN`, `AND`/`ORR`/`EOR`/`ANDS`/`TST`/`BIC`/`ORN`/`EON` (shifted register), extended-register add/sub, `MOVZ`/`MOVN`/`MOVK`.
- **Bitfield & extract:** full `SBFM`/`UBFM`/`BFM` (LSL/LSR/ASR, UXTB/UXTH/SXTB/SXTH/SXTW, `UBFX`/`SBFX`/`UBFIZ`/`SBFIZ`/`BFI`/`BFXIL`/`BFC`); `EXTR` (32-bit and 64-bit, including non-zero lsb).
- **Multiply / divide / shifts:** `MADD`/`MSUB`/`SMADDL`/`UMADDL`/`SMULL`/`UMULL`/`SMULH`/`UMULH`, `UDIV`/`SDIV`, variable shifts `LSLV`/`LSRV`/`ASRV`/`RORV`.
- **Bit ops:** `REV`/`REV16`/`REV32`, `RBIT` (SWAR bit-reverse); `CLZ`/`CLS` (host-LZCNT-gated).
- **Add/sub with carry:** `ADC`/`SBC`/`ADCS`/`SBCS`.
- **PC-relative / system:** `ADRP`/`ADR`, `MRS TPIDR_EL0`.
- **Branches & conditionals:** `B`/`BL`/`BR`/`BLR`/`RET`, `B.cond` (all conditions), `CBZ`/`CBNZ`, `TBZ`/`TBNZ`, `CSEL`/`CSINC`/`CSINV`/`CSNEG`, `CCMP`/`CCMN`.
- **Loads / stores:** integer `LDR`/`STR` all sizes (signed & unsigned), register-offset forms, `LDP`/`STP`/`LDPSW`, pre/post-index writeback — all with TBI masking and fault recovery.
- **Scalar FP (S/D; FP16 still bails):** `FADD`/`FSUB`/`FMUL`/`FDIV`/`FNMUL`, `FMAX`/`FMIN`/`FMAXNM`/`FMINNM`, `FMOV` (register & immediate), `FABS`, `FNEG`, `FSQRT`, `FRINT{N,M,P,Z,X,I,A}`, `FCMP`/`FCMPE`, `FCCMP`/`FCCMPE`, `FMADD`/`FMSUB`/`FNMADD`/`FNMSUB` (host-FMA3-gated), `FCVT` single↔double, and the FP↔int / FP↔fixed-point conversions `SCVTF`/`UCVTF`/`FCVTZS`/`FCVTZU`/`FCVTNS`/`FCVTPS`/`FCVTMS` (+ unsigned) and FP32 `FCVTAS`/`FCVTAU`. (`FCSEL` deliberately still bails — a region-level miscompile; FP64 `FCVTAS/AU`, `FCVT`-to-half, and `BFCVT` bail.)
- **NEON three-same (8/16/32-bit lanes; `.2D` integer & FP16 bail):** `ADD`/`SUB` (incl. `.2D`), `MUL`/`MLA`/`MLS` (16/32-bit), `PMUL` (byte), `AND`/`ORR`/`EOR`/`BIC`/`ORN`, `BSL`/`BIT`/`BIF`, `CMEQ`/`CMGT`/`CMGE`/`CMHI`/`CMHS`/`CMTST`, `SMAX`/`SMIN`/`UMAX`/`UMIN` (+ pairwise), `SABD`/`UABD`/`SABA`/`UABA`, `SHADD`/`UHADD`/`SRHADD`/`URHADD`, `ADDP`, `SQADD`/`UQADD`/`SQSUB`/`UQSUB`, `SQDMULH`/`SQRDMULH`, and the FP forms `FADD`/`FSUB`/`FMUL`/`FDIV`/`FMLA`/`FMLS` (`.2S`/`.4S`/`.2D`), `FMAX`/`FMIN`/`FMAXNM`/`FMINNM`, `FCMEQ`/`FCMGE`/`FCMGT`, `FABD`.
- **NEON three-different (widening/narrowing):** `S/U ADDL`/`SUBL`/`ADDW`/`SUBW`, `S/U ABDL`/`ABAL`, `ADDHN`/`SUBHN`/`RADDHN`/`RSUBHN`, `S/U MULL`/`MLAL`/`MLSL`, `SQDMULL`/`SQDMLAL`/`SQDMLSL`, `PMULL`/`PMULL2` (byte→halfword, dword→qword).
- **NEON two-reg-misc (FP32 for the FP forms; `.2D` converts & FP16 bail):** `REV16`/`REV32`/`REV64`, `CNT`, `NOT`, `NEG`, `ABS`, compare-against-zero (`CMEQ/CMGT/…#0`, `FCM…#0`), `XTN`/`SQXTN`/`UQXTN`/`SQXTUN`, `SHLL`, `SUQADD`/`USQADD`, `CLZ`/`CLS`, across-lanes `ADDV`/`S U ADDLV`/`S U MAXV`/`MINV`/`F MAXV`/`MINV`/`MAXNMV`/`MINNMV`, `S/U ADDLP`/`ADALP`, and the FP32 converts `FCVTZS`/`FCVTZU`/`FCVTNS`/`FCVTPS`/`FCVTMS`(+U)/`FCVTAS`/`FCVTAU`/`SCVTF`/`UCVTF`, `FRINT*_V`.
- **NEON shift-by-immediate (16/32/64-bit; byte-lane, signed `.2D`, and vector fixed-point converts bail):** `USHLL`/`SSHLL` (`UXTL`/`SXTL`), `SHL`, `USHR`/`SSHR`, `SSRA`/`USRA`, `S/U RSHR`/`RSRA`, `SLI`/`SRI`, `SQSHL`/`UQSHL`/`SQSHLU`, `SHRN`/`RSHRN`, `SQSHRN`/`UQSHRN`/`SQSHRUN`/`SQRSHRN`/`UQRSHRN`/`SQRSHRUN`.
- **NEON by-element (vector):** `MUL`/`MLA`/`MLS`, `S/U MULL`/`MLAL`/`MLSL`, `SQDMULL`/`SQDMLAL`/`SQDMLSL`, and the FP `FMUL`/`FMULX`/`FMLA`/`FMLS` (FP32 `.2S`/`.4S` and FP64 `.2D`; FP16 bails). (Scalar by-element still bails.)
- **NEON permute / copy / table:** `EXT`, `ZIP1`/`ZIP2`/`UZP1`/`UZP2`/`TRN1`/`TRN2`, `TBL`/`TBX`, `INS` (general & element), `SMOV`/`UMOV`, `DUP` (general register & element). (`DUP` scalar bails.)
- **NEON structured load/store:** `LD1`-`LD4`/`ST1`-`ST4` (multi-structure de-interleave/interleave), `LD1R`, and the single-structure `LD1`/`ST1` forms.
- **AdvSIMD modified-immediate:** `MOVI`/`MVNI`/`FMOV` (vector) / `ORR`/`BIC` (vector immediate), and `DUP` (general register).
- **SIMD&FP load/store:** `LDR`/`STR` (Q/D/S) and `LDP`/`STP` (Q pair).
- **Load/store-exclusive & LSE atomics:** `LDXR`/`LDAXR`/`STXR`/`STLXR` (sized `LOCK CMPXCHG`), `LDAR`/`STLR`, `CAS*`, `SWP*`, `LDADD*`, and now the bitwise `LDCLR*`/`LDSET*`/`LDEOR*` and min/max `LDSMAX*`/`LDSMIN*`/`LDUMAX*`/`LDUMIN*` (32/64-bit, via a `CMPXCHG` retry loop — the heavy frontend's first internal back-edge loop) plus `CASP` 32-bit pair (packed `CMPXCHG`).
- **CRC32C (Castagnoli):** `CRC32CB/CH/CW/CX` via host SSE4.2 `crc32` (gated on `kHasSSE4_2`; IEEE `CRC32*` stays interpreter-only).
- **Dot product:** `SDOT`/`UDOT` (vector + by-element, incl. I8MM `USDOT`/`SUDOT`) via `PMOVSXBW/PMOVZXBW`+`PMADDWD`+`PHADDD`.
- **Complex arithmetic (FP32):** `FCADD` (±90°) and `FCMLA` (rotations 0/90/180/270), `.2s`/`.4s`. (FP16, FP64, and the indexed `FCMLA` still bail.)

Promoting `ADRP`, `MRS TPIDR_EL0`, and `SBFX` in particular mattered: these appear in nearly every real-app region, so heavy bailing on them previously kept the second gear from ever engaging on real workloads.

Still **heavy-tier-only** (the heavy frontend bails; lite/interpreter handle them). Grouped by family:

| Family | Bails on | Notes |
|---|---|---|
| Integer | *(none remaining — `ADC`/`SBC`, `RBIT`, and 64-bit `EXTR` now lower)* | The integer core is fully heavy-lowered. |
| System | `MRS` (any sysreg ≠ `TPIDR_EL0`), `MSR`, `IC IVAU`, `SVC`, `BRK` | Side-effecting / runtime-handled; heavy declines. |
| MTE | `ADDG`/`SUBG`, `IRG`/`GMI`/`SUBP`, `LDG`/`STG`/… | `MteDataProc`/`MteLoadStore` bail. |
| Scalar FP | `FCSEL`; all FP16 forms; `FCVT`-to-half & `BFCVT`; FP64 `FCVTAS`/`FCVTAU`; the `rmode=01` top-half `FMOV V.D[1]` | Most scalar FP now lowers (see the list above). `FCSEL` is a *deliberate* bail (a region-level miscompile), not a missing implementation. |
| NEON (residual) | all `.2D`/64-bit-lane integer forms (§3a.1, hardware-conditional); all FP16 vector forms; byte-lane (`MUL`/`MLA`/`MLS` 8-bit, byte-lane shifts); the vector FP-misc ops `FABS`/`FNEG`/`FSQRT`/`FRECPE`/`FRSQRTE`/`URECPE`/`URSQRTE`/`SQABS`/`SQNEG` and vector `FCVTL`/`FCVTN`/`FCVTXN`; `FACGE`/`FACGT`; scalar three-same (beyond scalar `SQDMULH`/`SQRDMULH`); scalar-pairwise; scalar by-element; scalar D-width saturating narrows | The broad NEON compute surface now lowers (three-same, three-diff, two-reg-misc, shifts, indexed, permute/copy/TBL, structured load/store — see the list above); this is the genuine remainder. |
| SIMD extensions | `FCADD`/`FCMLA` (FCMA), `BFDOT`/`BFMMLA` (BF16), `SDOT`/`UDOT`/`USDOT` (DotProduct), `SMMLA`/`UMMLA`/`USMMLA` (I8MM) | Still heavy-bails; lite JIT-lowers most of these. |
| Atomics (LSE) | `CASP` 128-bit pair (`.2D`), `LDXP`/`STXP` pair-exclusive | `LDAR`/`STLR`, `LDXR`/`STXR`, `CAS*`, `SWP*`, `LDADD*`, and now the **bitwise `LDCLR*`/`LDSET*`/`LDEOR*` and min/max `LDSMAX*`/`LDSMIN*`/`LDUMAX*`/`LDUMIN*` (32/64-bit) plus `CASP` 32-bit pair** all lower in the second gear (a `CMPXCHG` retry loop that re-reads memory each iteration, so nothing is carried across the loop back-edge — the heavy frontend's first internal loop). The 128-bit `CASP` (`CMPXCHG16B`, no simple machine-IR op) and the `LDXP`/`STXP` pair forms still bail (lite/interpreter handle them). Byte/halfword bitwise/min-max forms also bail (no zero-extending sized-load IR op). |
| Crypto | `AES*`, `SHA1*`/`SHA256*`/`SHA512*`, `SM3*`/`SM4*`, `EOR3`/`BCAX`/`RAX1`/`XAR` | Heavy bails (these are interpreter-only even at the lite tier — see §3). |

### 3a.1 Permanently-deferred `.2D` / 64-bit-lane forms (hardware-conditional, not translator gaps)

A distinct sub-class of the heavy bails above is **not** "not-yet-implemented" — it is **blocked by the host x86_64 baseline lacking AVX-512** (and, for a few, SSE4.1/4.2). SSE2-era x86 has no 64-bit-lane packed integer compare, min/max, or multiply, and no packed FP64↔int64 convert; those ops only exist in AVX-512F-VL / AVX-512DQ (or SSE4.1/4.2 for the equality/greater-than compares). The Digitalis host emulator baseline does not enable AVX-512, so these `.2D` (and the equivalent scalar-`D`/`.1D` packed) forms **bail to the lite tier / interpreter, which handle them correctly via 64-bit-GPR fallbacks — correct, only without the second-gear speedup.** This is a *hardware-conditional performance* characteristic, **not a translator gap and not a bug**, and it is expected to remain a heavy bail on any AVX-512-less host. A future sweep should **not** re-chase these as if they were unimplemented gaps.

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
| **Heavy-tier-only ops (§3a: `FCSEL`, 128-bit `CASP`/`LDXP`/`STXP`, `.2D`/FP16 vector, FP16/FP64 FCMA, BF16/I8MM-matmul, SHA/SM3/SM4)** | Any app with a hot loop over one of these | **None–Low** — correct via lite/interpreter; the only cost is that such a hot region can't gear up to the heavy optimizer. (AES, the 32/64-bit LSE bitwise/min-max atomics + `CASP`-32, `CRC32C`, `SDOT`/`UDOT`, and FP32 `FCADD`/`FCMLA` now gear up.) |

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
