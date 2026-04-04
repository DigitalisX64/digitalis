# Digitalis

ARM64-to-x86_64 binary translation for Android, built on AOSP's Berberis NativeBridge framework. Digitalis enables ARM64-only Android apps (specifically Vulkan apps) to run on x86_64 Android emulators by translating ARM64 instructions to native x86_64 machine code at runtime.

## What This Is

This is an AOSP (Android Open Source Project) source tree with modifications to the Berberis binary translator to support ARM64-to-x86_64 translation. Berberis originally supported only RISC-V-to-x86_64; Digitalis adds the ARM64 backend.

The proof-of-concept app `hello-digitalis` renders a Vulkan triangle — an ARM64-only APK running on an x86_64 emulator via NativeBridge translation.

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
| `sample/hellodigitalis/` | ARM64-only Vulkan triangle app (Gradle/NDK project) |

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

Install and run the sample app:
```bash
# Build hello-digitalis APK separately (Gradle project in sample/hellodigitalis/)
adb install sample/hellodigitalis/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.example.hellodigitalis/android.app.NativeActivity
```

Run host unit tests:
```bash
out/host/linux-x86/nativetest64/berberis_host_tests/berberis_host_tests
```

## Key Files for Development

These are the most-modified files and the ones you'll touch most often:

- **`lite_translator/arm64_to_x86_64/lite_translator.h`** — JIT compiler implementation (~1100+ lines of ARM64->x86_64 translation). All integer, branch, load/store, system, and basic SIMD JIT ops.
- **`lite_translator/arm64_to_x86_64/lite_translator.cc`** — Branch condition evaluation, NZCV flag emission (LAHF+SETO+AND+MOVW).
- **`lite_translator/arm64_to_x86_64/lite_translate_region.cc`** — JIT region management, early termination on register pressure.
- **`lite_translator/arm64_to_x86_64/allocator.h`** — x86_64 register pool (13 GP registers: RBX, RSI, RDI, R8-R15, RDX, RCX). RDX needs save/restore around DIV/MUL, RCX around variable shifts. RAX reserved for guest PC. RBP holds ThreadState pointer.
- **`decoder/include/berberis/decoder/arm64/decoder.h`** — ARM64 instruction bit decoding. Many bugs have been opcode dispatch ordering issues here.
- **`decoder/include/berberis/decoder/arm64/semantics_player.h`** — Bridges decoder to translator/interpreter.
- **`interpreter/arm64/interpreter.h`** — All interpreter-only SIMD instructions (pairwise, widening, permute, compare, across-lanes, CRC32, scalar conversions).
- **`kernel_api/arm64/syscall_emulation.cc`** — Syscall forwarding, futex workarounds, call_once/pthread_once deadlock fixups.
- **`kernel_api/sys_mman_emulation.cc`** — BSS partial-page zeroing after file-backed mmaps.
- **`lite_translator/arm64_to_x86_64/lite_translate_region_exec_tests.cc`** — JIT unit tests (31 tests).

## Critical Conventions

- **Decoder dispatch order matters.** Multiple instruction groups share encoding prefixes. Always check distinguishing bits (bit29 for LD/ST, bit24 for single/multi struct, bits[11:10] for three-diff/three-same). Missing a bit routes instructions to the wrong handler silently.
- **Verify opcode mappings against the ARM Architecture Reference Manual.** Silent mis-routing (e.g., CMGT vs SMAX, SWP vs LDADD) produces wrong results without crashes until a memory boundary is hit.
- **Never set guest PC to a JIT-cached address for interpreter-fallback instructions.** Use `success_ = false` to install `kInterpreted` at that PC, avoiding infinite re-entry loops.
- **Register spill-to-temp**: When all permanent register slots are full, allocate a temp register and load/store from ThreadState memory. Don't terminate the region — spill instead.
- **PUSH/POP don't affect x86 FLAGS, but SUB/ADD do.** When saving registers before LAHF, use PUSH/POP or LEA, not SUB RSP.
- **Use FaultyLoad/FaultyStore for all interpreter memory accesses.** Raw memcpy causes host SIGSEGV that bypasses guest signal handlers.
- **Digitalis-specific code is marked with `// region digitalis` / `// endregion` comments** (or `# region digitalis` in makefiles). This distinguishes Digitalis additions from upstream Berberis code.

## Known Issues (Non-Blocking)

1. **STLR atomic store** to `once_flag` silently fails under translation. Masked by futex workaround in `syscall_emulation.cc`, not root-caused.
2. **ARM64 optimized memset** (`dup v0.16b + stp q0, q0` loops) does not work correctly under translation. BSS zeroing workaround in `sys_mman_emulation.cc` handles the critical case.
3. **JIT region size** averages ~5 instructions (every conditional branch ends the region). Region extension causes correctness bugs with backward branches.
