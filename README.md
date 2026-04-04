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

- **ARM64 optimized memset partially broken under translation.** The core SIMD pattern (`dup v0.16b` + `stp q0, q0`) works correctly in both JIT and interpreter (verified by host tests). The real failure is in a specific code path within bionic's `__memset_aarch64` that hasn't been isolated yet. The BSS zeroing workaround in `sys_mman_emulation.cc` covers the critical case.

## Claude Code Integration

This repo includes a `/dispatch` slash command and an automated dispatch script for Claude Code.

### Usage

Inside Claude Code, run the automated multi-cycle dispatch loop:

```
/dispatch Fix STLR root cause
```

Or continue from where the last handoff left off:

```
/dispatch
```

This runs `.claude/digitalis-dispatch.sh`, which spawns subagents in a loop — each reads the latest handoff, does real work, writes the next handoff, and exits. The loop continues until `STATUS: COMPLETE`.

To run directly from the terminal:

```bash
.claude/digitalis-dispatch.sh "Implement FRECVTS instruction"
```
