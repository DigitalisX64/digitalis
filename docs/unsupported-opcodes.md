# ARM64 Opcode Support Gaps

Two kinds of gap exist in the Digitalis ARM64 backend:

1. **Not supported at all** — the decoder either rejects the instruction with `Undefined()` or never decodes it. Sections 1 and 2 below.
2. **Supported but only by the interpreter** — the instruction runs, but the JIT (`lite_translator/arm64_to_x86_64/`) won't translate it. Every guest region containing one ends and the instruction is handled by per-instruction simulation. Functionally correct, but ~10–100× slower per instance. Section 3 below.

For everything that **is** JIT-translated (the fast path), see [Appendix B in `how-it-works.md`](how-it-works.md#appendix-b-arm64-to-x86_64-instruction-mapping).

All line references are into `frameworks/libs/binary_translation/decoder/include/berberis/decoder/arm64/decoder.h` unless noted.

---

## 1. Rejections inside the supported encoding space

The decoder reaches these instructions but explicitly calls `Undefined()` because no handler has been written. They produce a fatal decode error at runtime.

| Family | Instructions | ARM rev | Evidence |
|---|---|---|---|
| **Half-precision FP — scalar** | `FADD/FSUB/FMUL/FDIV Hd, Hn, Hm`, `FNEG/FABS/FSQRT H`, `FMOV Hd, #imm`, `FCVT` to/from H | ARMv8.0 (FP16 base) | `decoder.h:2474` — `if (ftype >= 2) { Undefined(); return; }` in FP 3-source / data-processing-1-source paths |
| **Half-precision FP — compare** | `FCMP Hn, Hm`, `FCMPE Hn, Hm` | ARMv8.0 (FP16) | `decoder.h:2520` — same `ftype >= 2` rejection in FP compare |
| **Half-precision SIMD — vector indexed** | `FMLA/FMLS/FMUL Vd.4H, Vn.4H, Vm.H[idx]` | ARMv8.0 (FP16) | `decoder.h:2945` — 16-bit element size in vector-indexed FP rejected |
| **Reserved SIMD indexed encodings** | `FMLA/FMLS` with `U=1`, `SMLAL/SMLSL` with reserved opcode | n/a (encoding-reserved) | `decoder.h:2953, 2957, 2974, 2981, 2985` |
| **Exception-generating (non-SVC)** | `BRK #imm`, `HLT #imm`, `DCPS1/DCPS2/DCPS3` | ARMv8.0 | `decoder.h:1272` — only `SVC` decoded; everything else: `// Other exception instructions not implemented yet. Undefined();` |
| **Add/subtract with tag (MTE)** | `ADDG`, `SUBG`, `ADDGS`, `SUBGS` (data-processing-immediate, tagged) | ARMv8.5 (MTE) | `decoder.h:982-984` — `case 0b011: // Add/subtract (immediate, with tags) - not implemented. Undefined();` |
| **Load/store catch-all** | Various exotic load/store-exclusive variants and SIMD load/store edge cases | mixed | `decoder.h:1510-1511` — `// Catch-all for other load/store variants not yet implemented (SIMD, exclusive, etc.). Undefined();` |

**Note on BTI:** `BTI #c/#j/#jc` is encoded as a `HINT` and currently routes to `Nop()` (see `decoder.h:1292`). The instruction doesn't fault — it just has no effect. Apps that rely on BTI for control-flow integrity won't get protection on Digitalis, but they will run.

---

## 2. Entire ARM extensions with no decoder dispatch at all

The decoder doesn't have any case for these — the instruction bits hit one of the high-level catch-alls and produce `Undefined()`. None of these are encountered in typical Android NDK apps today.

| Extension | ARM rev | Representative instructions |
|---|---|---|
| **PAC** (Pointer Authentication) | ARMv8.3 | `PACIA/PACIB/PACDA/PACDB`, `AUTIA/AUTIB/AUTDA/AUTDB`, `XPACI/XPACD`, `PACGA`, `LDRAA/LDRAB`, `RETAA/RETAB`, `BRAA/BLRAA`, PAC variants of `BR/BLR` |
| **FCMA** (FP complex multiply-accumulate) | ARMv8.3 | `FCMLA`, `FCADD` |
| **JSCVT** (FP→int JavaScript convert) | ARMv8.3 | `FJCVTZS` |
| **MTE** (Memory Tagging Extension) | ARMv8.5 | `IRG`, `GMI`, `STG`, `STZG`, `STGP`, `STGM`, `LDG`, `LDGM`, `STGV`, `LDGV`, `SETF8/16`, tagged system registers (`TCO`, `GCR_EL1`, `TFSR*_EL*`) |
| **BTI** (Branch Target Identification) | ARMv8.5 | `BTI #c/#j/#jc` — *decoded as `HINT` → no-op; runs but provides no protection* |
| **RNG** (Random Number Generator) | ARMv8.5 | `MRS X, RNDR`, `MRS X, RNDRRS` |
| **BFloat16** | ARMv8.6 | `BFDOT`, `BFMMLA`, `BFCVT`, `BFCVTN`, `BFCVTN2`, `BFMLALB`, `BFMLALT` |
| **Int8 matrix multiply (I8MM)** | ARMv8.6 | `SMMLA`, `UMMLA`, `USMMLA`, `SUDOT`, `USDOT` |
| **SVE** (Scalable Vector Extension) | ARMv8.2 / v9 | All Z-register ops: predicated arithmetic, gather/scatter loads, FFR predicate, reductions, permute (`SPLICE`, `COMPACT`, `REV`, `UZP`, `ZIP`, `TRN`), `PTRUE`, `WHILELT`, etc. |
| **SVE2** | ARMv9 | Multiply, bitwise, bit-permute, FP, cryptographic-helper SVE2 instructions |
| **SME** (Scalable Matrix Extension) | ARMv9.2 | `ZA` tile access, `MOVA`, `ADDHA/ADDVA`, `SMOPA/SMOPS/UMOPA/UMOPS/SUMOPA/USMOPA`, SME load/store, streaming-mode entry/exit |

---

## 3. Supported only in the interpreter (no JIT path)

These instructions run correctly but force the dispatcher out of the JIT. The lite translator either has no handler or explicitly falls back; the interpreter (`interpreter/arm64/interpreter.h`) implements them. Where a region contains one of these, the JIT terminates at that point, the interpreter executes the instruction, and the dispatcher resumes JIT for the next region.

### Scalar floating point

| Family | Instructions | Why interpreter-only |
|---|---|---|
| FP conversions | `FCVT Sd, Dd` (single↔double), `FCVTZS`, `FCVTZU`, `SCVTF`, `UCVTF` | Saturation / NaN edge cases differ between ARM and x86; lite translator falls through to `Undefined()` |
| Fused multiply-add | `FMADD`, `FMSUB`, `FNMADD`, `FNMSUB` | JIT sets `success_ = false` for the 3-source FP group (`lite_translator.h:1540`) |
| Single-source | `FABS`, `FNEG`, `FSQRT` | JIT 1-source handler only covers `FMOV`; others fall through (`lite_translator.h:2060`) |
| FP conditional select | `FCSEL Dd, Dn, Dm, cond` | Explicitly deferred — `lite_translator.h:1527`: *"FCSEL: fall back to interpreter (condition flag checking complex in JIT)"* |
| FP rounding | `FRINTA`, `FRINTN`, `FRINTP`, `FRINTM`, `FRINTZ`, `FRINTX`, `FRINTI` | All handled in interpreter at `interpreter/arm64/interpreter.h:2640+`; no JIT case |

### NEON / SIMD compute (vector)

The JIT supports SIMD **loads/stores** (`MOVI Vd.2D, #0`, `LDR Q/D/S/H/B`, `STR Q/D/S/H/B`, `LDP/STP Q,Q`) and the broadcast form of `DUP V, W` plus `ADD V` for some sizes. Almost every other vector op is interpreter-only:

| Group | Examples |
|---|---|
| Element-wise arithmetic | `ADD V`, `SUB V`, `MUL V`, `MLA V`, `MLS V` |
| Element-wise logical | `AND V`, `ORR V`, `EOR V`, `BIC V`, `ORN V`, `NOT V` |
| Compare | `CMEQ V`, `CMGT V`, `CMLE V`, `CMHI V`, `CMHS V`, `CMTST V`, `CMLT V` |
| Min / max | `SMAX V`, `SMIN V`, `UMAX V`, `UMIN V`, `FMAX V`, `FMIN V` |
| Single-source | `ABS V`, `NEG V`, `CNT V`, `REV16 V`, `REV32 V`, `REV64 V` |
| Pairwise & across-lanes | `ADDP V`, `ADDV V`, `SADDLV V`, `UADDLV V`, `UMAXV V`, `UMINV V` |
| Permute | `DUP V, V[i]` (element form), `INS V[i], X`, `UMOV X, V[i]`, `EXT V`, `TRN1/TRN2 V`, `ZIP1/ZIP2 V`, `UZP1/UZP2 V` |
| Multi-structure load / store | `LD2`, `LD3`, `LD4`, `ST2`, `ST3`, `ST4` (the single-reg `LD1`/`ST1` is JIT'd) |
| Widening arithmetic | `UADDL`, `SADDL`, `UMULL`, `SMULL`, `UMLAL`, `SMLAL` |
| Vector shifts by immediate | `SHL V`, `SSHR V`, `USHR V`, `SLI V`, `SRI V` |
| Vector FP — interpreter-supported | `FADD V`, `FSUB V`, `FMUL V`, `FMLA V`, `FMLS V` on `.4S` and `.2D`. |
| Vector FP — unsupported | `FDIV V`, `FMAX V`, `FMIN V`, `FCMEQ V`, `FCMGE V`, `FCMGT V`, `FRECPS V`, `FRSQRTS V`, `FABD V`, `FMULX V`, `FMAXNM V`, `FMINNM V`. Listed in [§1](#1-rejections-inside-the-supported-encoding-space). |
| Table lookup | `TBL`, `TBX` |
| CRC32 | `CRC32B/H/W/X`, `CRC32CB/CH/CW/CX` (Digitalis-specific addition; software polynomial) |

### Scalar bitfield & system

| Family | Instructions | Notes |
|---|---|---|
| General bitfield | `BFM` (full form), `SBFM` / `UBFM` outside the alias subset | Aliases the JIT *does* handle: `LSL imm`, `LSR imm`, `ASR imm`, `SXTB/H/W`, `UXTB/H`, `EXTR` (see Appendix B) |
| System registers (MRS / MSR) | Everything except the four JIT-handled ones: `TPIDR_EL0`, `NZCV`, `CTR_EL0`, `DCZID_EL0` | Interpreter generally implements these as no-ops or constants; see `interpreter.h` system-register switch |

### Why this matters

The interpreter is ~10–100× slower per instruction than JIT-translated code, plus each interpreter-only instruction forces a region exit and dispatcher round-trip. For a tight inner loop, a single interpreter-only opcode can dominate the loop's runtime. The highest-value optimisations are:

| Promotion target | Typical app affected |
|---|---|
| `FCVTZS` / `SCVTF` (scalar conversions) | Any code mixing ints and floats — graphics math, audio |
| Vector `FADD V` / `FMUL V` / `FMLA V` | Audio DSP, ML inference, vertex shaders |
| `FCSEL` | Branchless FP code |
| Multi-structure `LDn` / `STn` | Interleaved RGBA/PCM data |

---

## 4. Practical impact

What matters in practice for ARM64-only Android apps running on the Digitalis emulator:

| Group | Apps likely to hit it | Severity |
|---|---|---|
| **FP16 scalar / vector** | ML inference, video codecs, some game shaders | **High** — increasingly common in 2024+ NDK builds |
| **Exception ops (`BRK`)** | Sanitizer builds (ASAN/UBSAN/HWASAN), debug builds | **Medium** — affects developer/debug flows |
| **`FJCVTZS`** | JavaScriptCore / V8 JITs running inside an app | **Low** — rare in NDK apps |
| **PAC** | Pixel-class Bionic builds that PAC-sign return addresses | **Low–Medium** — most app `.so` files compiled for Play Store don't emit PAC |
| **MTE / BTI** | Opt-in security hardening, rarely emitted by NDK toolchains today | **Low** |
| **FCMA / BFloat16 / I8MM** | ML signal-processing kernels | **Low–Medium** for ML apps; ignorable elsewhere |
| **SVE / SVE2 / SME** | Effectively no shipping Android apps (no Android device exposes them to user code yet) | **None** |

---

## 5. Where to add support

For instructions in [Section 1](#1-rejections-inside-the-supported-encoding-space) (already in the decoder reach):

| Layer | File | What to add |
|---|---|---|
| **Decoder** | `decoder/include/berberis/decoder/arm64/decoder.h` | Replace the `Undefined()` with `insn_consumer_->Xxx(args)` |
| **Semantics bridge** | `decoder/include/berberis/decoder/arm64/semantics_player.h` | Add `Xxx()` forwarding the structured args to the consumer |
| **Interpreter** | `interpreter/arm64/interpreter.h` | Implement `Xxx()` |
| **JIT (optional)** | `lite_translator/arm64_to_x86_64/lite_translator.h` | Implement `Xxx()` for the hot path |
| **Tests** | `lite_translator/arm64_to_x86_64/lite_translate_region_exec_tests.cc` | Add a regression test exercising the new instruction |

For entire extensions in [Section 2](#2-entire-arm-extensions-with-no-decoder-dispatch-at-all), the decoder needs new top-level dispatch cases under the relevant `op0` bit pattern in `Decode()` first.

---

*Re-validate against the codebase before relying on the line numbers — the decoder is actively evolving.*
