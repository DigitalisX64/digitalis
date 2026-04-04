# digitalis

The arm64-to-x86_64 binary translation based on Berberis framework.

## Init

```
mkdir digitalis
cd digitalis
repo init -b android-latest-release -u git@github.com:DigitalisX64/manifest.git
```

## Sync code

```
repo sync -c -d --no-tags --force-sync
```

## Build

```
source build/envsetup.sh
lunch sdk_phone64_x86_64_digitalis-trunk_staging-userdebug
m
```

## Run

```
emulator
# And then build and install sample/hellodigitalis with Gradle to test
```

## Known Issues

These are non-blocking but affect correctness and performance:

1. **STLR atomic store silently fails.** `STLR` (store-release) doesn't actually write to `once_flag` under translation. The root cause is unknown — currently masked by a futex workaround in `kernel_api/arm64/syscall_emulation.cc` that detects stuck `once_flag` values and writes `COMPLETE` directly. This means any code path relying on `STLR` for synchronization may have latent bugs beyond `once_flag`.

2. **ARM64 optimized memset broken under translation.** Bionic's SIMD memset (`dup v0.16b` + `stp q0, q0` loops) produces incorrect results. A workaround in `kernel_api/sys_mman_emulation.cc` zeros BSS partial pages after file-backed mmaps, but other memset call sites are unprotected and may silently corrupt memory.

3. **JIT regions average only ~5 instructions.** Every conditional branch ends the current region due to a correctness bug: region extension (translating across conditional branches) caused infinite loops when backward branches re-entered the same region. Performance would improve significantly with larger regions, but this requires a scheme to handle backward branches safely (e.g., detecting back-edges and inserting dispatch checks).

## Claude Code Integration

This repo includes a `/dispatch` slash command for Claude Code that runs one cycle of the handoff-driven development loop.

### Usage

Inside Claude Code, start a new effort from an idea:

```
/dispatch Implement FRECVTS instruction for the JIT translator
```

Or continue from where the last handoff left off:

```
/dispatch
```

Each invocation reads the latest `digitalis-handoff-N.md` (or bootstraps from your idea if none exists), does real work, and writes the next handoff.

To run it non-interactively (e.g., in an automated loop):

```bash
claude -p /dispatch --dangerously-skip-permissions --model opus --max-budget-usd 20
```
