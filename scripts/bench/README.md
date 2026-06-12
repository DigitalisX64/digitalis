# Digitalis lite-translator microbenchmark (plan2 P7 harness)

A tiny on-device benchmark that isolates the translator hot paths each plan2
performance item targets, so every P-item lands with a real before/after
number instead of a hand-wave. This is the "measure first" requirement (P7) the
plan makes a prerequisite for P1–P6.

## Kernels

| kernel | what it stresses | plan item |
|--------|------------------|-----------|
| `alu` | tight dependent integer ALU loop, no branches/memory | baseline JIT throughput |
| `branch` | data-dependent `CMP`+`B.cond` in a tight loop (LCG-random, unpredictable) | **P3** (CMP/B.cond fusion, NZCV elision), **P2** (in-region back edge) |
| `syscall` | raw `svc #0` getpid loop — the guest syscall path, not the proxy getpid trampoline | **P1** (syscall-in-JIT, done) |
| `memcpy` | bulk 64 KiB `memcpy` | mem / proxy-libc path |

The `syscall` kernel deliberately issues a raw `svc #0` (`__NR_getpid`, x8=172)
rather than calling `getpid()`: the proxy libc intercepts `getpid()` as a
direct host trampoline (~3 ns) that never exercises the guest `SVC` path. The
raw `svc` forces the translator's actual syscall path — the one P1 optimized
and the one real binder/ioctl/futex traffic takes.

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
args after `--` override the four iteration counts
(`alu branch syscall memcpy`) for slower hosts.

## Baseline (2026-06-13, current translator)

Median ns/iter over 5 reps on `sdk_phone64_x86_64_digitalis`:

| kernel | ns/iter |
|--------|---------|
| alu | 1.69 |
| branch | 4.25 |
| syscall | 303 |
| memcpy | 787 |

The `syscall` number reproduces P1's ~308 ns measurement (syscall-in-JIT). The
`branch` number is the figure P3/P2 must move.

## Contract

No plan2 perf claim ships without a before/after pair from this harness. Keep
the `BENCH <name> iters=… ns_total=… ns_per_iter=…` output prefix stable —
`run-bench.sh` parses it.

> Note: editors using a host (x86_64) toolchain flag the `x0`/`x8` register
> names in the raw-`svc` asm as unknown — a false positive. The binary is built
> only with the arm64 NDK cross-compiler (`build.sh`), where they are valid.
