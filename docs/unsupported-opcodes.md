# ARM64 Opcode Support Gaps

> **Verified 2026-08-09** against the decoder, lite translator and heavy optimizer.
> Current state only; the history of coverage promotions lives in `RELEASE_NOTES.md`.

## The authoritative source is generated, not this file

Per-mnemonic coverage lives in
`frameworks/libs/binary_translation/heavy_optimizer/arm64/arm64_tier_coverage.txt`
— 846 mnemonics over a 48,032-encoding corpus, four columns:

```
<mnemonic> <encodings> <lite-translates> <heavy-translates>
```

It is generated, and a gate (`Arm64TierCoverage.NoTierLosesCoverage`) fails if any
tier ever translates fewer encodings than recorded. Regenerate with:

```bash
berberis_arm64_host_tests --gtest_also_run_disabled_tests \
  --gtest_filter=Arm64TierCoverage.DISABLED_RegenerateTable
```

Where it is at:

| | encodings | share |
|---|---|---|
| Lite translator | 44,893 / 48,032 | 93.5% |
| Heavy optimizer | 43,945 / 48,032 | 91.5% |

136 mnemonics have no lite coverage and 156 no heavy coverage — but most of those
are SVE/SME/FP8 encodings that are undecoded by design (§2). 78 mnemonics are
lite-covered but weaker in heavy (§4).

**Read `0` as proof of absence; do not read a full count as proof of presence.**
The corpus samples encodings per mnemonic, so a mnemonic showing full coverage may
still have an unsampled form that bails.

## The four kinds of gap

1. **Exception-generating** (`SVC`/`BRK`/`HLT`/`HVC`/`SMC`/`DCPS`) — deliberately not
   JIT-lowered. None abort the translator. §1.
2. **Extension not decoded at all** — falls through to a catch-all `Undefined()`,
   which delivers `SIGILL`. §2.
3. **Decoded and correct, interpreter-only** — runs correctly, but forces a region
   exit and a dispatcher round trip. ~10–100× slower per instance. §3.
4. **Lite-translated, heavy bails** — a *performance* gap only: the hot region keeps
   its correct lite translation and simply doesn't gear up. Never an
   `Undefined arm64 instruction`. §4.

---

## 1. Exception-generating instructions

No exception-generating instruction aborts the translator. `SVC` becomes a syscall;
`BRK`/`HLT` deliver a guest `SIGTRAP`; `HVC`/`SMC`/`DCPS1-3` are UNDEFINED at EL0 and
route through `Undefined()` to `SIGILL` — the architecturally correct result for
user space.

`BTI c/j/jc` is encoded as a `HINT` and routes to `Nop()`: it doesn't fault, it just
has no effect. Apps relying on BTI for control-flow integrity run, without that
protection.

## 2. Extensions with no decoder dispatch

| Extension | Representative instructions | Where it lands |
|---|---|---|
| **SVE / SVE2** | Z-register ops: predicated arithmetic, gather/scatter, `PTRUE`, `WHILELT`, permutes | top-level `default: Undefined()` in `DecodeInstruction` (`op0 ∈ {0001,0010,0011}`) |
| **SME** | `ZA` tile access, `MOPA`/`MOPS` family, streaming-mode entry/exit | same |
| **FP8 / FAMINMAX / LUT** | FP8 convert/dot, `FAMAX`/`FAMIN`, `LUTI2`/`LUTI4` | SIMD&FP encodings that bottom out in a `DecodeSimdFp()` `Undefined()` path |

No Android device exposes these to user code today, so no shipping app reaches them.
Adding one means new top-level dispatch under its `op0` pattern first.

## 3. Decoded and correct, but interpreter-only

Both JIT tiers bail; the interpreter is correct. Filter the generated table for
`lite == 0` for the full list. The classes that matter:

| Class | Examples | Why |
|---|---|---|
| **Crypto residue** | `SHA1*`, `SHA512*`, `SM3*`, `SM4*`, `EOR3`/`BCAX`/`RAX1`/`XAR` | No x86 baseline primitive for SHA512/SM3/SM4; the ARM and x86 SHA round decompositions are non-isomorphic and a wrong round silently corrupts output. Deferred as low value — Android crypto routes through host BoringSSL/Conscrypt. |
| **MTE** | `ADDG`/`SUBG`, `IRG`/`GMI`/`SUBP`, `LDG`/`STG`/`STZG`/… | Interpreter executes with no-MTE-backing semantics. Rarely hot. |
| **System registers** | `MRS`/`MSR` outside the modelled set, `IC`, `MRRS`/`MSRR`, `SYSP` | The JITs model `NZCV`, `CTR_EL0`, `DCZID_EL0`, `MIDR_EL1`, `TPIDR_EL0`, `FPCR`; the interpreter models a larger set as constants/no-ops. |
| **Newer atomics** | `RCW*` (ARMv8.9), FP atomics (`LDFADD*`/`LDFMAX*`) | Not yet lowered; vanishingly rare in NDK output. |
| **AdvSIMD residue** | FP reductions (`FMAXV`/`FMINV`/`FMAXNMV`/…, pairwise `FMAXNMP`/`FMINNMP`), widening `FMLAL`/`FMLSL` family, `FRINT32Z`/`FRINT64Z`, replicating loads `LD2R`/`LD3R`/`LD4R`, `SUQADD`/`USQADD` `.1D`/`.2D` | Each needs a multi-instruction host sequence; none is common enough to have been worth it yet. |

**Already lowered, contrary to older revisions of this document:** `AES*` (host AES-NI),
**SHA-256** (`SHA256H`/`H2`/`SU0`/`SU1`, via a software GPR sequence — the x86 assembler
still has no SHA-NI definitions), `PMULL`/`PMULL2`, both the IEEE `CRC32*` (PCLMULQDQ
reflected Barrett) and Castagnoli `CRC32C*` (host `crc32`) groups, and the full I8MM
dot-product/matrix set.

### Host-feature-gated
Where the host CPU lacks a feature the JIT path bails to the interpreter — correct,
just slower: FP16 needs `F16C`, FMA-based paths need `FMA`, `CRC32C*` needs SSE4.2.

## 4. Heavy-tier-only gaps

Correct via lite/interpreter; the heavy frontend just doesn't translate them, so a hot
region containing one can't gear up. Filter the generated table for
`lite > 0 && heavy < lite` — 78 mnemonics. The largest, by encodings lost:

| Mnemonic | lite → heavy | 
|---|---|
| `FCVTN`/`FCVTN2`/`FCVTL`/`FCVTL2` | 128 → 62–69 |
| `SQDMULH` | 127 → 63 |
| `URSHL` (vector; scalar-D lowers) | 54 → 0 |
| `MRS` / `MSR` | 78 → 31, 27 → 4 |
| `SQSHL` / `SQRSHL` | 128 → 84, 128 → 90 |
| `FCMLA` | 55 → 21 |

Closing one lets hot regions containing it reach the second gear. This is the lever
behind the heavy-tier bail histogram (NEON ≈47%, scalar FP ≈24%, integer carry ≈17%,
LSE atomics ≈5% of observed bails).

### 4.1 `.2D` / 64-bit-lane forms — hardware-conditional, not translator gaps

These bail because the emulator's baseline host lacks the instruction, not because the
translator is missing an implementation, and are expected to stay bails on any
AVX-512-less host:

| Family | Missing host op |
|---|---|
| `.2D` integer compares | `PCMPEQQ` (SSE4.1) / `PCMPGTQ` (SSE4.2) |
| `.2D` min/max and pairwise min/max | `PMAXSQ`/`PMINSQ`/`PMAXUQ`/`PMINUQ` (AVX-512F-VL) |
| `MUL .2D` | `VPMULLQ` (AVX-512DQ) |
| Packed FP64↔int64 converts `.2D` | `CVTTPD2QQ`/`CVTUQQ2PD` (AVX-512DQ) |
| Saturating add/sub `.2D`, narrowing `SQXTN` from `.2D` | no SSE 64-bit-lane saturation or 64→32 saturating pack |

## 5. Adding support

| Layer | File | What to add |
|---|---|---|
| Decoder | `decoder/include/berberis/decoder/arm64/decoder.h` | replace `Undefined()` with `insn_consumer_->Xxx(args)` |
| Semantics bridge | `decoder/include/berberis/decoder/arm64/semantics_player.h` | `Xxx()` forwarding structured args |
| Interpreter | `interpreter/arm64/interpreter.h` | implement `Xxx()` |
| Lite JIT | `lite_translator/arm64_to_x86_64/lite_translator.h` | first-gear fast path |
| Heavy JIT | `heavy_optimizer/arm64/frontend.{h,cc}` | so hot regions can gear up |
| Tests | `lite_translate_region_exec_tests.cc`, `frontend_tests.cc` | a region exec test per tier |

A §3 gap needs only the JIT case-arm and a test — decoder and interpreter already
handle it. A §4 gap needs only the heavy case-arm and a `frontend_tests.cc` test. A §2
extension needs decoder dispatch first. Regenerate the coverage table in the same
commit that adds coverage, or the gate reports the difference.
