# ARM64 Opcode Support Gaps

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
| **SVE** (Scalable Vector Extension) | ARMv8.2 / v9 | All Z-register ops: predicated arithmetic, gather/scatter, FFR, reductions, permute (`SPLICE/COMPACT/REV/UZP/ZIP/TRN`), `PTRUE`, `WHILELT`, … | top-level `default: Undefined()` (`DecodeInstruction`, `decoder.h:1982`, `op0 ∈ {0001,0010,0011}`) |
| **SVE2** | ARMv9 | Multiply, bitwise, bit-permute, FP, crypto-helper SVE2 instructions | same — `decoder.h:1982` |
| **SME** (Scalable Matrix Extension) | ARMv9.2 | `ZA` tile access, `MOVA`, `ADDHA/ADDVA`, `SMOPA/UMOPA/…`, SME load/store, streaming-mode entry/exit | same — `decoder.h:1982` |
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
| `AESE/AESD/AESMC/AESIMC`, `SHA1*`, `SHA256*`, `SHA512*`, `SM3*`, `SM4*` | JIT bails in the crypto handlers; interpreter executes. The ARM and x86 AES/SHA instruction sets decompose rounds differently (non-isomorphic), so a correct AES-NI/SHA-NI mapping is high-effort; deferred as low-value (Android crypto routes through host BoringSSL/Conscrypt, rarely executing these guest instructions). `PMULL/PMULL2` (`.1Q` via `PCLMULQDQ`, `.8H` via per-bit widening) **is** JIT-lowered. |

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
| `AES*` / `SHA1*` / `SHA256*` | Deferred — non-isomorphic AES-NI/SHA-NI mapping; crypto routes through host BoringSSL |
| `SUQADD/USQADD .1D/.2D` | Deferred — 64-bit-element 65-bit saturation; vanishingly rare |

Recently promoted to the JIT (no longer interpreter-only): vector `FCVTN`/`FCVTL` (incl. FP16), the `.2D→.2S` saturating extracts, `URECPE`/`URSQRTE`, the I8MM `USDOT/SUDOT/SMMLA/UMMLA/USMMLA` family, `.2S<-.2D` `ADDHN/SUBHN/RADDHN/RSUBHN`, `.2S/.4S` `SUQADD/USQADD`, scalar `REV32`, and `PMULL`. The `ORR/BIC #imm` vector forms were also corrected to read-modify-write (they previously replaced `Vd`).

AdvSIMD modified-immediate correctness fix: **`FMOV` (vector, immediate)** (`cmode=0b1111`) was unimplemented in `ExpandSimdModifiedImm` (interpreter) and its JIT mirror — it byte-replicated `imm8` instead of running `VFPExpandImm`, so `fmov v.4s, #1.0` (`imm8=0x70`) yielded `0x70707070` (≈2.97e29f) per lane instead of `0x3F800000`. This corrupted any NEON `floorf()`/area computation that materialises a float constant via FMOV immediate — Unity 6 (Crossy Road, Temple Run 2) computed a garbage allocation size (`-N<<32`) and self-aborted with `raise(SIGTRAP)`. Now implements `VFPExpandImm` for single- and double-precision FMOV vector immediates in both backends (`op=1/cmode=0b1111`, `fmov v.2d`, was also mis-routed to MVNI). Covered by `FmovImm4S`/`FmovImm2D` exec tests.

---

## 3a. Heavy-tier-only gaps (lite/interpreter cover them; heavy bails)

These instructions are fully supported and correct via the lite translator and/or interpreter; the **heavy optimizer** (`heavy_optimizer/arm64/frontend.{h,cc}`) just doesn't translate them yet, so a hot region containing one bails out of the second gear and keeps running its lite translation — correct, only without the heavy-tier speedup. This is a *performance* gap, never an `Undefined arm64 instruction`.

A heavy bail is mechanical: the frontend callback calls `UndefinedReturningVoid()`/`UndefinedReturningReg()` → `Undefined()`, which sets `success_ = false`, appends a `PseudoJump(kExitGeneratedCode)`, and makes every later read-helper return a dead temp and every write-helper a no-op (so no IR lands in the already-terminated block). The runtime then re-lite-translates the whole region (`runtime/arm64/translator_x86_64.cc`), and the region settles permanently at the lite tier.

The heavy optimizer **now translates** (current `frontend.{h,cc}` coverage). The first gear's whole "common integer + branch + load/store" core is mirrored here, plus several recent SIMD/FP/atomic additions:

- **Integer ALU (immediate & register):** `ADD`/`SUB`/`ADDS`/`SUBS`/`CMP`/`CMN`, `AND`/`ORR`/`EOR`/`ANDS`/`TST`/`BIC`/`ORN`/`EON` (shifted register), extended-register add/sub, `MOVZ`/`MOVN`/`MOVK`.
- **Bitfield & extract:** full `SBFM`/`UBFM`/`BFM` (LSL/LSR/ASR, UXTB/UXTH/SXTB/SXTH/SXTW, `UBFX`/`SBFX`/`UBFIZ`/`SBFIZ`/`BFI`/`BFXIL`/`BFC`); `EXTR` 32-bit (64-bit non-zero-lsb still bails).
- **Multiply / divide / shifts:** `MADD`/`MSUB`/`SMADDL`/`UMADDL`/`SMULL`/`UMULL`/`SMULH`/`UMULH`, `UDIV`/`SDIV`, variable shifts `LSLV`/`LSRV`/`ASRV`/`RORV`.
- **Bit ops:** `REV`/`REV16`/`REV32`; `CLZ`/`CLS` (host-LZCNT-gated).
- **PC-relative / system:** `ADRP`/`ADR`, `MRS TPIDR_EL0`.
- **Branches & conditionals:** `B`/`BL`/`BR`/`BLR`/`RET`, `B.cond` (all conditions), `CBZ`/`CBNZ`, `TBZ`/`TBNZ`, `CSEL`/`CSINC`/`CSINV`/`CSNEG`, `CCMP`/`CCMN`.
- **Loads / stores:** integer `LDR`/`STR` all sizes (signed & unsigned), register-offset forms, `LDP`/`STP`/`LDPSW`, pre/post-index writeback — all with TBI masking and fault recovery.
- **Scalar FP (via the intrinsic layer):** `FADD`/`FSUB`/`FMUL`/`FDIV` (S/D), `FMOV` (register & immediate), `FABS`, `FNEG`.
- **NEON integer three-same:** `ADD`/`SUB`/`MUL` (supported element sizes) and `AND`/`ORR`/`EOR` (incl. the `ORR rn==rm` MOV-vector alias).
- **AdvSIMD modified-immediate:** `MOVI`/`MVNI`/`FMOV` (vector) / `ORR`/`BIC` (vector immediate), and `DUP` (general register).
- **SIMD&FP load/store:** `LDR`/`STR` (Q/D/S) and `LDP`/`STP` (Q pair).
- **Load/store-exclusive:** `LDXR`/`LDAXR`/`STXR`/`STLXR` (sized `LOCK CMPXCHG`), `LDAR`/`STLR`.

Promoting `ADRP`, `MRS TPIDR_EL0`, and `SBFX` in particular mattered: these appear in nearly every real-app region, so heavy bailing on them previously kept the second gear from ever engaging on real workloads.

Still **heavy-tier-only** (the heavy frontend bails; lite/interpreter handle them). Grouped by family:

| Family | Bails on | Notes |
|---|---|---|
| Integer | `ADC`/`SBC` (add/sub with carry), `RBIT`, `EXTR` 64-bit non-zero-lsb | No host carry-chain / bit-reverse / 64-bit `SHRD` IR op. |
| System | `MRS` (any sysreg ≠ `TPIDR_EL0`), `MSR`, `IC IVAU`, `SVC`, `BRK` | Side-effecting / runtime-handled; heavy declines. |
| MTE | `ADDG`/`SUBG`, `IRG`/`GMI`/`SUBP`, `LDG`/`STG`/… | `MteDataProc`/`MteLoadStore` bail. |
| Scalar FP (beyond the 6 above) | `FMAX`/`FMIN`/`FMAXNM`/`FMINNM`/`FNMUL`, `FCMP`/`FCMPE`, `FCCMP`, `FCSEL`, `FSQRT`, `FRINT*`, `FCVT`(precision)/`BFCVT`, all FP16, `FMADD`/`FMSUB`/`FNMADD`/`FNMSUB`, fixed-point & int conversions (`SCVTF`/`UCVTF`/`FCVTZS`/`FCVTZU`) | Only the four basic binops + FMOV/FABS/FNEG are heavy-lowered. |
| NEON (most) | three-same beyond `ADD`/`SUB`/`MUL`/`AND`/`ORR`/`EOR` (incl. `CMEQ`/`CMGT`/saturating/shifts/pairwise/FP-three-same); the unsupported `ADD`/`SUB`/`MUL` element sizes (8-/64-bit); `AdvSimdThreeDiff` (widening/narrowing); two-reg-misc; shift-by-imm; indexed-element; `EXT`/permute/`TBL`; multi-struct & single-struct; SIMD register-offset & literal load/store; SIMD&FP B/H `LDR`/`STR` and D/S pairs; `DUP`(element)/`INS`/`SMOV`/`UMOV` | The bulk of Advanced SIMD is still lite/interpreter-only at the heavy tier. |
| SIMD extensions | `FCADD`/`FCMLA` (FCMA), `BFDOT`/`BFMMLA` (BF16), `SDOT`/`UDOT`/`USDOT` (DotProduct), `SMMLA`/`UMMLA`/`USMMLA` (I8MM) | Heavy bails; lite JIT-lowers most of these. |
| Atomics | LSE: `CAS*`/`CASP*`/`SWP*`/`LDADD*`/`LDSET*`/… | Heavy bails; lite/interpreter handle them. |
| Crypto | `AES*`, `SHA1*`/`SHA256*`/`SHA512*`, `SM3*`/`SM4*`, `EOR3`/`BCAX`/`RAX1`/`XAR` | Heavy bails (these are interpreter-only even at the lite tier — see §3). |

---

## 4. Practical impact

What matters in practice for ARM64-only Android apps on the Digitalis emulator:

| Group | Apps likely to hit it | Severity |
|---|---|---|
| **IEEE CRC32 (perf)** | Compression/IO-heavy apps | **Low** — only the IEEE `CRC32*` polynomial is interpreter-speed; `CRC32C*` is JIT'd, and zlib uses its own software tables. |
| **SHA / AES (perf)** | TLS, content hashing | **Low–Medium** — correct, interpreter-speed; most TLS goes through host BoringSSL/Conscrypt anyway. |
| **`SUQADD/USQADD .1D/.2D`, MTE, non-modelled MRS/MSR (perf)** | Vanishingly rare | **None–Low** — correct, interpreter-speed; not on real hot paths. |
| **SVE / SVE2 / SME / FP8** | Effectively no shipping Android apps (no Android device exposes them to user code yet) | **None** — documented deferred gap. |
| **Heavy-tier-only ops (§3a: `RBIT`, `DUP`-element, LSE atomics, …)** | Any app with a hot loop over one of these | **None–Low** — correct via lite/interpreter; the only cost is that such a hot region can't gear up to the heavy optimizer. |

The only remaining decoder gaps are the SVE/SME/FP8 scalable/matrix extensions (no Android user-space exposure). The remaining heavy-tier gaps (§3a) are purely a second-gear performance consideration, not a correctness gap.

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
