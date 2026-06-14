# Digitalis lite-translator microbenchmark

A tiny on-device benchmark that isolates distinct translator hot paths, so any
performance change lands with a real before/after number instead of a
hand-wave.

## Kernels

| kernel | what it stresses |
|--------|------------------|
| `alu` | tight dependent integer ALU loop, no branches/memory — baseline JIT throughput |
| `branch` | data-dependent `CMP`+`B.cond` in a tight loop (LCG-random, unpredictable) — condition evaluation and branch/loop codegen |
| `syscall` | raw `svc #0` getpid loop — the guest syscall path, not the proxy getpid trampoline |
| `memcpy` | bulk 64 KiB `memcpy` — mem / proxy-libc path |
| `regpress` | 16 coupled accumulators in a branch-free dependent loop — more live values than the lite tier's 13 host registers, so it isolates the two-gear heavy tier's global register allocation (lite spills per iteration) |

The `syscall` kernel deliberately issues a raw `svc #0` (`__NR_getpid`, x8=172)
rather than calling `getpid()`: the proxy libc intercepts `getpid()` as a
direct host trampoline (~3 ns) that never exercises the guest `SVC` path. The
raw `svc` forces the translator's actual syscall path — the one real
binder/ioctl/futex traffic takes.

## Usage

```bash
# 1. Build the arm64 binary (uses the newest installed NDK; override with
#    ANDROID_NDK_HOME / API_LEVEL):
digitalis/scripts/bench/build.sh

# 2. With a booted Digitalis emulator, capture the median ns/iter per kernel:
digitalis/scripts/bench/run-bench.sh --reps 5 --label before
#   ... make the translator change, rebuild + redeploy libberberis ...
digitalis/scripts/bench/run-bench.sh --reps 5 --label after
```

`run-bench.sh` repeats the run (`--reps`, default 5) and reports the median
`ns_per_iter` per kernel — the least-noisy single number to quote. Trailing
args after `--` override the five iteration counts
(`alu branch syscall memcpy regpress`) for slower hosts.

## Two-gear vs lite (2026-06-14)

Median ns/iter over 5 reps on `sdk_phone64_x86_64_digitalis`, comparing the
single-gear lite tier against the two-gear default (`BERBERIS_MODE`):

| kernel | lite | two-gear | note |
|--------|------|----------|------|
| alu | 1.70 | 1.70 | neutral (fits lite's register budget) |
| branch | 4.30 | 4.34 | neutral (stays lite — sub-threshold region) |
| syscall | 316 | 313 | neutral |
| memcpy | 788 | 795 | neutral |
| regpress | 9.94 | **4.85** | **2.05× faster** — heavy's global register allocation beats lite's per-iteration spills |

Two-gear is neutral on the kernels that fit the lite tier's 13-register mapping
and ~2× faster where register pressure forces lite to spill — the case the
heavy tier's global allocation targets.

## Contract

No perf claim ships without a before/after pair from this harness. Keep the
`BENCH <name> iters=… ns_total=… ns_per_iter=…` output prefix stable —
`run-bench.sh` parses it.

> Note: editors using a host (x86_64) toolchain flag the `x0`/`x8` register
> names in the raw-`svc` asm as unknown — a false positive. The binary is built
> only with the arm64 NDK cross-compiler (`build.sh`), where they are valid.
