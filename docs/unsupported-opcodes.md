# ARM64 Opcode Support Gaps

Three kinds of gap exist in the Digitalis ARM64 backend:

1. **Not decoded — rejected inside the supported encoding space.** The decoder reaches the instruction but calls `Undefined()` because no handler has been written. Fatal decode error at runtime. Section 1 below.
2. **Not decoded — entire extension absent.** The decoder has no dispatch for the extension at all; instructions fall through to a high-level catch-all `Undefined()`. Section 2 below.
3. **Decoded and correct, but interpreter-only.** The instruction runs correctly, but the JIT (`lite_translator/arm64_to_x86_64/`) has no fast path for it. Every guest region containing one ends at that instruction, the interpreter executes it, and the dispatcher resumes JIT for the next region. Functionally correct, ~10–100× slower per instance. Section 3 below.

For everything that **is** JIT-translated (the fast path), see [Appendix B in `how-it-works.md`](how-it-works.md#appendix-b-arm64-to-x86_64-instruction-mapping). This document lists only what remains unsupported or interpreter-only.

All line references are into `frameworks/libs/binary_translation/decoder/include/berberis/decoder/arm64/decoder.h` unless noted. The decoder is actively evolving — **re-validate line numbers against the codebase before relying on them.**

---

## 1. Rejections inside the supported encoding space

The decoder reaches these instructions but explicitly calls `Undefined()` because no handler has been written. They produce a fatal decode error at runtime. (Reserved/invalid encodings that *correctly* decode to `Undefined()` are not listed here.)

| Family | Instructions | ARM rev | Evidence |
|---|---|---|---|
| **Exception-generating (non-BRK/SVC)** | `HLT #imm`, `HVC`, `SMC`, `DCPS1/2/3` | ARMv8.0 | Reach the decoder but stay fatal-with-diagnostic; no handler written. |

**Note on BTI:** `BTI c/j/jc` is encoded as a `HINT` and routes to `Nop()`. It doesn't fault — it just has no effect. Apps relying on BTI for control-flow integrity won't get protection on Digitalis, but they will run.

---

## 2. Entire ARM extensions with no decoder dispatch at all

The decoder has no case for these — the instruction bits hit a high-level catch-all and produce `Undefined()`. None are encountered in typical Android NDK apps today.

| Extension | ARM rev | Representative instructions | Where it lands |
|---|---|---|---|
| **SVE** (Scalable Vector Extension) | ARMv8.2 / v9 | All Z-register ops: predicated arithmetic, gather/scatter, FFR, reductions, permute (`SPLICE/COMPACT/REV/UZP/ZIP/TRN`), `PTRUE`, `WHILELT`, … | top-level `Undefined()` (`DecodeInstruction` default ~2009, `op0 ∈ {0001,0010,0011}`) |
| **SVE2** | ARMv9 | Multiply, bitwise, bit-permute, FP, crypto-helper SVE2 instructions | ~2009 |
| **SME** (Scalable Matrix Extension) | ARMv9.2 | `ZA` tile access, `MOVA`, `ADDHA/ADDVA`, `SMOPA/UMOPA/…`, SME load/store, streaming-mode entry/exit | ~2009 |
| **FP8 / FAMINMAX / LUT** | ARMv9.x | FP8 convert/dot, `FAMAX/FAMIN`, `LUTI2/LUTI4` | ~3590 |

**Deliberately deferred:** SVE/SVE2/SME/FP8 are a from-scratch undertaking (new Z/P register state, a separate decode tree, gather/scatter) and **no Android device exposes them to user code**, so they remain documented gaps rather than committed work — per the project plan's beyond-manual tier.

---

## 3. Decoded and correct, but interpreter-only (no JIT path)

These run correctly but force the dispatcher out of the JIT. The lite translator either has no case-arm or explicitly bails (`success_ = false`); the interpreter (`interpreter/arm64/interpreter.h`) implements them. All line refs in this section are into `lite_translator/arm64_to_x86_64/lite_translator.h`.

### Vector narrowing / lengthening / reciprocal-estimate
| Instructions | Why interpreter-only |
|---|---|
| `FCVTN`, `FCVTL` (vector) | FP narrowing/widening has no direct SSE lowering. |
| `SQXTN/UQXTN/SQXTUN` **.2D→.2S only** | The 64→32 saturating extracts have no x86 narrowing pack. |
| `URECPE`, `URSQRTE` | Bit-exact ARM integer estimate recurrences; the JIT bails via the default. |
| `SUQADD/USQADD` **.2S/.4S/.1D/.2D only** | The 32-/64-bit-element signed↔unsigned saturating-accumulate forms have no JIT path. |

### Three-different (widening) — the non-JIT subset
| Instructions | Why interpreter-only |
|---|---|
| `ADDHN`, `SUBHN`, `RADDHN`, `RSUBHN` **.2S<-.2D only** | The `.2S<-.2D` form has no x86 narrowing pack. |

### Vector immediate
| Instructions | Why interpreter-only |
|---|---|
| `ORR #imm` / `BIC #imm` (read-modify-write forms) | Both the interpreter and JIT treat `ORR/BIC #imm` as replace, not read-modify-write — a pre-existing semantic gap. |

### Dot-product / matrix-multiply (I8MM)
| Instructions | Why interpreter-only |
|---|---|
| `USDOT/SUDOT` (vector + by-element), `SMMLA/UMMLA/USMMLA` | I8MM mixed-sign dot / 8-bit matrix multiply-accumulate; decoded and executed, but no JIT case-arm. |

### CRC32 and crypto
| Instructions | Why interpreter-only |
|---|---|
| `CRC32B/H/W/X` (IEEE only) | The IEEE 802.3 polynomial (0x04C11DB7) differs from the host SSE4.2 `crc32` (Castagnoli) instruction, so it stays on the software-polynomial interpreter path. |
| `AESE/AESD/AESMC/AESIMC`, `SHA1*`, `SHA256*`, `SHA512*`, `SM3*`, `SM4*`, `PMULL/PMULL2` (except `.8H`) | JIT bails with `Undefined()` in the crypto handlers; interpreter executes. |

### Scalar bitfield & system
| Family | Instructions | Notes |
|---|---|---|
| Byte-reverse 32 | `REV32 Xd, Xn` (scalar, opcode2=000010) | No JIT arm in `DataProc1Src` (scalar `REV/REV16/CLZ/RBIT` *are* JIT). |
| System registers (MRS/MSR) | Everything except `NZCV`, `CTR_EL0`, `DCZID_EL0`, `MIDR_EL1`, `TPIDR_EL0` | The JIT handles those five; all other reads/writes bail to the interpreter (mostly modelled as constants / no-ops). |
| MTE data-processing & load/store | `IRG/GMI/SUBP/STG/LDG/…` | Decoded, but the JIT bails (`MteDataProc`/`MteLoadStore`); interpreter executes. |

### Host-feature-gated fast paths
Where the host x86_64 CPU lacks a feature, the corresponding JIT path bails to the interpreter (still correct, just slower):
| Guest family | Host feature required |
|---|---|
| All FP16 (`F16C` round-trip) | `F16C` |
| `FMADD/FMSUB/FNMADD/FNMSUB` and FMA-based FP-vector MAC | `FMA` |
| `CRC32CB/CH/CW/CX` (Castagnoli) | `SSE4.2` (`crc32`) — bails to the software-polynomial interpreter path when absent |
| `.2D` signed arithmetic shifts (`SSHR/SSRA/SRSHR/SRSRA` scalar/`.2D`) | `AVX-512` (`VPSRAQ`) — bails on baseline x86_64 |
| Any `FP128` / `ftype == 0b10` scalar FP | n/a (reserved/quad — not lowered) |

### Why this matters

The interpreter is ~10–100× slower per instruction than JIT-translated code, and each interpreter-only instruction forces a region exit plus a dispatcher round-trip. For a tight inner loop, a single interpreter-only opcode can dominate runtime. The remaining high-value promotions are:

| Promotion target | Typical app affected |
|---|---|
| `FCVTN`/`FCVTL` and the `.2D→.2S` narrowing saturating extracts | Pixel format conversion, audio downsampling, quantized ML |
| IEEE `CRC32*` | zlib/zstd framing, filesystem checksums |

---

## 4. Practical impact

What matters in practice for ARM64-only Android apps on the Digitalis emulator:

| Group | Apps likely to hit it | Severity |
|---|---|---|
| **Vector FP narrowing `FCVTN` (perf)** | Image/audio codecs, quantized ML | **Low** — correct but interpreter-slow on hot kernels. |
| **IEEE CRC32 (perf)** | Compression/IO-heavy apps | **Low** — only the IEEE `CRC32*` polynomial is interpreter-speed. |
| **SHA / AES (perf)** | TLS, content hashing | **Low–Medium** — correct, interpreter-speed; most TLS goes through host BoringSSL/Conscrypt anyway. |
| **SVE / SVE2 / SME / FP8** | Effectively no shipping Android apps (no Android device exposes them to user code yet) | **None** — documented deferred gap. |

The only remaining decoder gaps are the SVE/SME/FP8 scalable/matrix extensions (no Android user-space exposure).

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
