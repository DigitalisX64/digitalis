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

Or use the lunch shortcut (it sources `build/envsetup.sh` for you if needed), then `m`:

```
source digitalis/scripts/lunch-digitalis.sh
m
```

## Run

```
emulator
# And then build and install sample/hellodigitalis with Gradle to test
```

## Binary-only distribution (Docker)

Build the translator as a **binary-only** bundle that other AOSP x86_64 products can
drop in without compiling Berberis from source. The build runs in a reproducible
Docker container whose build identity defaults to `digitalis-build`, and it reuses
the host's existing `out/` so a normal developer never has to rebuild the tree.

```bash
# Build + package the prebuilt bundle (incremental; reuses out/).
digitalis/docker/build-digitalis.sh

# Verify the produced bundle (presence, ELF arch, native-bridge export, checksums).
digitalis/scripts/verify-digitalis-prebuilts.sh
```

The output `digitalis/dist/digitalis-prebuilts/` holds the translator, proxy libs,
ARM64 guest libs, and configs, plus a `digitalis-prebuilts.mk` a consumer product
inherits to enable native bridge. See [`docker/README.md`](docker/README.md) for the
build identity/uid parameters, host-path reuse details, and integration steps.

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

This runs `.claude/scripts/digitalis-dispatch.sh`, which spawns subagents in a loop — each reads the latest handoff, does real work, writes the next handoff, and exits. The loop continues until `STATUS: COMPLETE`.

To run directly from the terminal:

```bash
.claude/scripts/digitalis-dispatch.sh "Implement FRECVTS instruction"
```
