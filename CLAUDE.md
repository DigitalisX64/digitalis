# Digitalis

ARM64-to-x86_64 binary translation for Android, built on AOSP's Berberis NativeBridge framework. Digitalis enables ARM64-only Android apps (specifically Vulkan apps) to run on x86_64 Android emulators by translating ARM64 instructions to native x86_64 machine code at runtime.

## What This Is

This is an AOSP (Android Open Source Project) source tree with modifications to the Berberis binary translator to support ARM64-to-x86_64 translation. Berberis originally supported only RISC-V-to-x86_64; Digitalis adds the ARM64 backend.

The `sample/hellodigitalis/` project contains 26 ARM64-only sample app modules (ported from [android/ndk-samples](https://github.com/android/ndk-samples), plus Digitalis-specific proxy-lib smoke tests) that serve as the integration test suite. These cover Vulkan, OpenGL ES (1.x & 2/3), JNI, audio (OpenSLES & AAudio), camera, MIDI, sensors, SIMD, NDK binder, and NNAPI — all running on an x86_64 emulator via NativeBridge translation.

## Architecture

```
ARM64 APK (arm64-v8a only)
  -> Android Framework (x86_64 host)
  -> NativeBridge (libberberis_arm64.so)
  -> Guest Loader (TinyLoader) -> ARM64 linker64 + libraries
  -> ARM64 App Code
  -> Proxy Libraries (libvulkan, libc, libm, etc.) -> host APIs
  -> Host GPU (GFXStream VkDecoder for Vulkan)
```

Dual execution path:
- **JIT (Lite Translator)**: Translates ARM64 regions to x86_64 machine code. Handles ~98% of instructions. Cached for reuse.
- **Interpreter**: Per-instruction fallback for syscalls, complex SIMD, and anything the JIT can't handle.

## Key Directories

All paths relative to repo root.

| Directory | What It Contains |
|-----------|-----------------|
| `frameworks/libs/binary_translation/` | Berberis core — the binary translator |
| `frameworks/libs/binary_translation/lite_translator/arm64_to_x86_64/` | JIT compiler (ARM64 -> x86_64 native code) |
| `frameworks/libs/binary_translation/interpreter/arm64/` | Instruction-by-instruction interpreter fallback |
| `frameworks/libs/binary_translation/decoder/include/berberis/decoder/arm64/` | ARM64 instruction decoder (`decoder.h`, `semantics_player.h`) |
| `frameworks/libs/binary_translation/runtime/arm64/` | Translation cache, dispatch, region management |
| `frameworks/libs/binary_translation/kernel_api/` | Linux syscall emulation (including `arm64/syscall_emulation.cc`) |
| `frameworks/libs/binary_translation/guest_loader/` | ELF loading, NativeBridge init |
| `frameworks/libs/binary_translation/android_api/` | Proxy libraries (libc, libm, libvulkan — forward API calls from guest to host) |
| `frameworks/libs/binary_translation/prebuilt/` | Prebuilt configs including `ld.config.arm64.txt` |
| `device/generic/goldfish/` | Emulator (goldfish) product definitions |
| `device/generic/goldfish/64bitonly/product/sdk_phone64_x86_64_digitalis.mk` | Digitalis product config |
| `sample/hellodigitalis/` | 26 ARM64-only sample app modules (Vulkan, GLES 1/2/3, JNI, OpenSLES + AAudio, camera, MIDI, SIMD, NDK binder, NNAPI, etc.) |

## Build

```bash
source build/envsetup.sh
lunch sdk_phone64_x86_64_digitalis-trunk_staging-userdebug
m
```

Or use the shortcut: `source lunch-digitalis.sh` after `source build/envsetup.sh`.

Run the emulator:
```bash
emulator -memory 4096 -writable-system -partition-size 65536 -qemu -cpu host &
```

Install and run sample apps:
```bash
# Build all 26 sample modules (ARM64-only APKs)
cd sample/hellodigitalis && ./gradlew assembleDebug
# Install and run the Vulkan triangle
adb install hello-vulkan/build/outputs/apk/debug/hello-vulkan-debug.apk
adb shell am start -n com.example.hellodigitalis/android.app.NativeActivity
```

Run host unit tests:
```bash
out/host/linux-x86/nativetest64/berberis_arm64_host_tests/berberis_arm64_host_tests --gtest_filter='Arm64*'
```

Verify the upstream ARM64 build still works (regression check before committing):
```bash
source build/envsetup.sh
lunch sdk_phone64_arm64_minigbm-trunk_staging-userdebug
m
```
After this finishes, switch back to the Digitalis target with `lunch sdk_phone64_x86_64_digitalis-trunk_staging-userdebug` before resuming x86_64 work.

Test all sample modules on the emulator:
```bash
.claude/scripts/test-samples.sh                # test all 26 modules
.claude/scripts/test-samples.sh hello-vulkan   # test a single module
```

Run screenshot tests (validates visual output against reference images):
```bash
.claude/scripts/test-samples.sh --screenshots              # test all 26 modules
.claude/scripts/test-samples.sh --screenshots hello-vulkan  # test a single module
```

Update reference images (after intentional rendering changes):
```bash
.claude/scripts/test-samples.sh --update-references              # all modules
.claude/scripts/test-samples.sh --update-references hello-vulkan  # single module
```

## Prebuilt-APK regression (sample/prebuilts/)

If `sample/prebuilts/` exists and contains one or more `*.apk` files, treat them as **extra regression targets** for normal verification (alongside `test-samples.sh`). The expectation:

- Install every APK under `sample/prebuilts/` on the booted Digitalis emulator (`adb install -r`).
- Launch each one's main activity and watch for `Fatal signal`, `Undefined arm64 instruction`, `FATAL EXCEPTION`, or the process disappearing inside a short watch window. Any of those is a regression.
- Run this in addition to (not instead of) `test-samples.sh`. Do not add per-APK helper scripts or per-APK CLAUDE.md sections — keep the workflow generic over whatever is dropped into `sample/prebuilts/`.
- The APKs themselves are not committed in repos that are part of the manifest; the directory is intentionally a drop-in spot.

## Key Files for Development

These are the most-modified files and the ones you'll touch most often:

- **`lite_translator/arm64_to_x86_64/lite_translator.h`** — JIT compiler implementation (~1100+ lines of ARM64->x86_64 translation). All integer, branch, load/store, system, and basic SIMD JIT ops.
- **`lite_translator/arm64_to_x86_64/lite_translator.cc`** — Branch condition evaluation, NZCV flag emission (LAHF+SETO+AND+MOVW).
- **`lite_translator/arm64_to_x86_64/lite_translate_region.cc`** — JIT region management, early termination on register pressure.
- **`lite_translator/arm64_to_x86_64/allocator.h`** — x86_64 register pool (13 GP registers: RBX, RSI, RDI, R8-R15, RDX, RCX). RDX needs save/restore around DIV/MUL, RCX around variable shifts. RAX reserved for guest PC. RBP holds ThreadState pointer.
- **`decoder/include/berberis/decoder/arm64/decoder.h`** — ARM64 instruction bit decoding. Many bugs have been opcode dispatch ordering issues here.
- **`decoder/include/berberis/decoder/arm64/semantics_player.h`** — Bridges decoder to translator/interpreter.
- **`interpreter/arm64/interpreter.h`** — All interpreter-only SIMD instructions (pairwise, widening, permute, compare, across-lanes, CRC32, scalar conversions).
- **`kernel_api/arm64/syscall_emulation.cc`** — Syscall forwarding, futex workarounds, errno/struct-layout translation.
- **`kernel_api/sys_mman_emulation.cc`** — BSS partial-page zeroing after file-backed mmaps.
- **`lite_translator/arm64_to_x86_64/lite_translate_region_exec_tests.cc`** — JIT unit tests (45 tests).
- **`sample/hellodigitalis/`** — 26 ARM64-only sample app modules (22 ported from android/ndk-samples + 4 Digitalis proxy-lib smoke tests: hello-gles1, hello-aaudio, hello-binder-ndk, hello-nnapi). Use `/test-samples` to test on the emulator.

## Modification Surface (binding)

Only these top-level paths may be modified when working on Digitalis:

- `frameworks/libs/binary_translation/` — Berberis translator, kernel_api,
  guest_loader, native_bridge, lite_translator, interpreter, decoder,
  runtime, tiny_loader, base, proxy libraries, etc.
- `device/generic/goldfish/` — emulator product/config.
- `sample/` — sample apps, gradle scripts, prebuilt-APK drop-in.
- `digitalis/` — Digitalis project docs/scripts (this file lives there).

Do **not** modify any other AOSP source directory — in particular:

- `bionic/` — upstream Android libc/linker. NOT a Digitalis surface.
  If a fix appears to require a bionic edit, route it through Berberis
  instead: patch guest libraries post-load (see
  `frameworks/libs/binary_translation/guest_loader/guest_loader.cc`'s
  `PatchLinkerProgname` for an example), extend the proxy libraries,
  add syscall emulation, or hook in the guest_loader.

This rule applies to every cycle of the dispatch loop and every direct
edit. If you find yourself reaching for `bionic/<path>`, stop and
re-route through `frameworks/libs/binary_translation/`.

## Git Conventions

- **No Co-Authored-By lines.** Do not add `Co-Authored-By` trailers to commit messages.

## Debugging Prebuilt APKs

When a prebuilt third-party APK (Facebook, WhatsApp, etc.) fails on the emulator, **prefer tracing-based diagnostic** over static code audit. Static audit alone routinely takes many build/push cycles to converge; a single trace usually points straight at the offending guest PC.

**Setup** (per emulator boot):

```bash
adb root
adb shell setenforce 0                                       # SELinux Permissive — needed to setprop berberis.tracing
adb shell setprop berberis.tracing '<pkg>=digitalis-trace.log'   # e.g. com.facebook.katana=digitalis-trace.log
adb shell am force-stop <pkg>
adb shell am start -n <pkg>/<launch-activity>
sleep 18
adb shell 'chmod 644 /data/user/0/<pkg>/digitalis-trace.log'
adb pull /data/user/0/<pkg>/digitalis-trace.log /tmp/trace.log
```

Relative trace filenames land in the app's private dir (`/data/user/0/<pkg>/`). Absolute paths are rejected by `TraceToFile` unless the dir is owned by the app uid. The `BERBERIS_TRACING` env var also works but is read once at zygote fork time; `setprop` is the only reliable way to set it per-app.

**Why `setenforce 0` is fine for debugging:**
- It's emulator-local and reverts on the next reboot.
- The property service rejects `setprop berberis.tracing` under Enforcing because no `property_contexts` rule exists for it. Adding such a rule means editing SELinux policy and rebuilding; flipping to Permissive is the temporary equivalent.
- **Always restore Enforcing (`adb shell setenforce 1`) when done debugging**, and never commit Permissive into product config.

**Reading the trace:**
- `berberis: dispatch#N pc=… x0=… x29=… x30=… sp=…` — the field labeled `sp=` is actually **x1** (see `runtime/arm64/translator_x86_64.cc:196`).
- `berberis: trans#N pc=… size=… JIT|INTERP …` — a new translation cache entry. Cross-reference `pc` against `link_map[i]: <base> <lib>` lines (also logged) to compute `lib_offset = pc - base`, then disasm at that offset with `prebuilts/clang/host/linux-x86/llvm-binutils-stable/llvm-objdump -d <pulled-lib>` to see the guest instruction.
- `berberis: interp #N pc=…` — emitted every 5 million interpreter instructions; if you see it during a small region, that region is interp-bailout-hot and worth JIT-implementing.
- Wrong-output bugs (Brotli/zstd checksum mismatches, "Bad context map", etc.) point at decoder mis-dispatch — verify the JIT-bailed-out instruction's encoding against the ARM ARM and confirm it routes to the right handler.

**Don't bisect via SIGILL substitution as the first move.** Replacing a handler with `Undefined()` and watching for SIGILL only proves whether that handler is hit; tracing both narrows the hit set and shows the operand values, which is far more useful per build/push cycle.

## Critical Conventions

- **Decoder dispatch order matters.** Multiple instruction groups share encoding prefixes. Always check distinguishing bits (bit29 for LD/ST, bit24 for single/multi struct, bits[11:10] for three-diff/three-same). Missing a bit routes instructions to the wrong handler silently.
- **Verify opcode mappings against the ARM Architecture Reference Manual.** Silent mis-routing (e.g., CMGT vs SMAX, SWP vs LDADD) produces wrong results without crashes until a memory boundary is hit.
- **Never set guest PC to a JIT-cached address for interpreter-fallback instructions.** Use `success_ = false` to install `kInterpreted` at that PC, avoiding infinite re-entry loops.
- **Register spill-to-temp**: When all permanent register slots are full, allocate a temp register and load/store from ThreadState memory. Don't terminate the region — spill instead.
- **PUSH/POP don't affect x86 FLAGS, but SUB/ADD do.** When saving registers before LAHF, use PUSH/POP or LEA, not SUB RSP.
- **Use FaultyLoad/FaultyStore for all interpreter memory accesses.** Raw memcpy causes host SIGSEGV that bypasses guest signal handlers.
- **Digitalis-specific code is marked with `// region digitalis` / `// endregion` comments** (or `# region digitalis` in makefiles). This distinguishes Digitalis additions from upstream Berberis code.
- **Fix root causes in the translator, not workarounds in samples.** When a sample app fails, the bug is in the binary translator (decoder, interpreter, lite translator, proxy libraries, syscall emulation), not the app. Do not modify code under `sample/hellodigitalis/` to work around translator bugs unless explicitly asked to.
- **Write sample logic without considering implementation status.** Samples should exercise their target API surface fully, including intrinsics, instructions, or APIs the translator does not yet implement. If a sample crashes on `Undefined arm64 instruction`, the fix is to add that opcode to `frameworks/libs/binary_translation/` (decoder + interpreter, plus JIT when applicable) — *never* to delete the offending code from the sample. The sample is the spec; the translator catches up to it.
- **Don't bake plan references into code or commits.** `digitalis-full-support-plan.md` is scaffolding for the dispatch loop, not load-bearing project history. Don't write `// Plan §H1 …` in sources, don't title commits `Plan §C8: …`, and don't refer to section letters in inline comments. Describe changes on their own terms — reference the ARM ARM section, the instruction encoding, or the upstream Berberis convention being followed. Plan-section labels are fine inside `digitalis-handoff-*.md` (the handoffs are themselves dispatch scaffolding); they must not leak from handoffs into shipped code or commit messages.
- **Don't use `// region digitalis` markers inside `sample/hellodigitalis/`.** Those markers belong only in `frameworks/libs/binary_translation/` source, where they distinguish Digitalis additions from upstream Berberis code. Everything inside `sample/hellodigitalis/` is Digitalis-only by construction — there is no upstream equivalent to mark against, so the markers are noise there.
- **Strip temporary debug logging before committing.** Investigative `__android_log_print`, `printf`, `TRACE`, and similar one-off log lines added while diagnosing a bug must be removed before `git commit`. They pollute production logcat, bias future debugging, and inflate diffs with noise. Load-bearing diagnostics (e.g., the `berberis: trans#N pc=…` region trace, the `Undefined arm64 instruction …` line, sample-side CHECK macros that surface test failures) stay; investigative scaffolding goes. If a debug log proves broadly useful, promote it to a documented diagnostic with a clear comment explaining why it exists.
- **Don't break the upstream ARM64 build.** Before committing, verify `lunch sdk_phone64_arm64_minigbm-trunk_staging-userdebug && m` still builds clean. Berberis lives in shared paths (`frameworks/libs/binary_translation/`), so translator edits, makefile changes, and proxy-library changes can leak into the native ARM64 image. New commits must keep the existing ARM64 build green. After verifying, switch back to the Digitalis target before resuming x86_64 work.

