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

- Install every APK in the `sample/prebuilts/` **root** on the booted Digitalis emulator (`adb install -r`).
- Launch each one's main activity and watch for `Fatal signal`, `Undefined arm64 instruction`, `FATAL EXCEPTION`, or the process disappearing inside a short watch window. Any of those is a regression.
- Run this in addition to (not instead of) `test-samples.sh`. Do not add per-APK helper scripts or per-APK CLAUDE.md sections — keep the workflow generic over whatever is dropped into `sample/prebuilts/`.
- The APKs themselves are not committed in repos that are part of the manifest; the directory is intentionally a drop-in spot.
- **Excluded subdirectories:** `sample/prebuilts/top-apps/` and `sample/prebuilts/top-games/` are the staging area for `digitalis/scripts/fetch-prebuilt-apks.py` (apkmirror downloads). They are **not** part of this gate — discovery is top-level only (non-recursive), so this regression and the fetch tool's own verification stay independent and don't break each other. Never recurse into them here.

**Mandatory per-cycle gate:** `.claude/scripts/test-prebuilts.sh` automates the install+launch+watch loop, scans every `*.apk` in the `sample/prebuilts/` root (non-recursive — `top-apps/` and `top-games/` are excluded), and exits non-zero if any APK crashes. The dispatch loop runs it at the **end of every cycle**, after `test-samples.sh` and before writing the handoff. The cycle's handoff must include a `## Prebuilt-APK Status` section that copy-pastes the script's per-APK PASS/FAIL summary — whatever APKs are present in the directory, that's what gets tested and reported. This is non-negotiable — it's how the user tracks prebuilt-APK regressions across cycles. The script is generic and discovers APKs at runtime; do NOT add per-app branches and do NOT hard-code app names anywhere in the dispatch flow. If a specific APK needs special handling, fix the underlying translator bug inside `binary_translation/`, not the script.

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

## File Header Conventions

- **License: Apache 2.0** for all new source files (matches the rest of AOSP).
- **Copyright holder: `utzcoz`** for newly created Digitalis source files (e.g., `Copyright (C) 2026 utzcoz`). Keep the existing AOSP copyright in any file that originated upstream.
- **No `// region digitalis` / `// endregion` markers in Digitalis-created files.** See the comprehensive rule under Critical Conventions ("region-marker placement"). In short: a file with **no upstream Berberis counterpart** — the entire ARM64 backend (`*/arm64/`, `*arm64_to_x86_64/`, `*arm64_to_all/`, `*_arm64.*`, e.g. `decoder/arm64/decoder.h`, `interpreter/arm64/interpreter.h`) and everything under `sample/hellodigitalis/` — is Digitalis-only by construction, so region markers there are pure noise and must be omitted. Markers belong **only** in shared/upstream-derived files (compiled for both riscv64 and arm64), and even there as **one block per contiguous run**.

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

### Speeding up root-cause diagnosis

Multi-cycle prebuilt-APK investigations tend to cycle through wrong hypotheses before localizing the real hot path. Each wrong direction is usually rooted in one of the traps below; bake these checks into every diagnostic cycle.

- **Trace first, simpleperf second.** Set `setprop berberis.tracing '<pkg>=digitalis-trace.log'` BEFORE any simpleperf work. simpleperf samples host PCs that map to JIT regions; **interpreter-hot paths (including `svc #0` syscalls) get misattributed to whichever JIT region's `movabs <guest_pc>` immediate was last seen**, looking like "hot in <random JIT region>" when the real CPU work is in `berberis_HandleInterpret`. Tracing's `berberis: interp #N pc=…` lines surface this directly.

- **Re-verify linker base every cycle.** `/system/bin/arm64/linker64`'s load address changes every emulator boot. Always read `/proc/<pid>/maps | grep linker64` to anchor offset math. NEVER inherit a base address from a previous handoff — a 4-KB error (e.g. `0x...cbc000` vs `0x...cc0000`) silently maps function offsets to the *wrong* function (`AddToMap` vs `LogdSocket::GetSocket`) and propagates that wrong hypothesis across multiple subsequent cycles.

- **debuggerd's `pc` is `ThreadState.insn_addr`, which is stale.** It reflects the *last region exit*, not live execution. For loops that never exit dispatch back through the path that updates `insn_addr` (e.g. a backward branch with `b loop_top`), the pc stays at whatever value it held N region exits ago. Three back-to-back debuggerd snapshots showing the same pc is NOT confirmation of a wedge at that pc — cross-check by sampling the actual TID with simpleperf AND looking at the JIT memfd:exec region the samples cluster in.

- **Stale-inode trap on diagnostic builds.** `md5sum` on disk does NOT tell you what's loaded in already-running processes. After `adb push` of a diagnostic library: (a) force-stop every prebuilt-APK process AND (b) `adb shell stop && start` to restart zygote AND (c) check `/proc/<pid>/maps` for the `(deleted)` annotation on the library file. If any process still has the old inode mapped, your "diagnostic trace" will be capturing the wrong code path while reporting the right md5sum.

- **Cheap-falsify before expensive-pin.** Before writing a full dispatch-enabled host test for a hypothesis (≥30 LOC + region encoding + execution harness + watchdog), verify the hypothesis at the live guest level first: single-step the interpreter at the suspect PC, or use a 5-line `berberis.tracing` snippet that logs the specific values the hypothesis depends on. Reserve the host-test pin for hypotheses you've already confirmed at guest level. Otherwise cycles burn ~30 minutes building a beautiful pinning test for a hypothesis that the cheaper check would have falsified in 5 minutes.

- **Don't re-anchor on a disproved hypothesis.** If cycle N's host test PASSES under the suspected failure condition, that hypothesis is dead — do NOT re-anchor on it in cycle N+1 without genuinely new evidence. The natural urge to "double-check" wastes a cycle. Treat host-test-passes as a hard exclusion; move the search to a different code path.

- **Mind the simpleperf↔interpreter blind spot.** simpleperf's call-stack output for time spent in the interpreter shows up as samples in `berberis_HandleInterpret` and the dispatch table function, which don't trivially decode to guest PCs. If `>30%` of samples are in those host functions and not in `memfd:exec`, the wedge is in the interpreter path; switch to the per-instruction `interp #N` trace immediately.

- **Sanity-check the candidate code is still on the hot path.** A multi-cycle investigation that keeps narrowing to "the AddToMap loop" should periodically run a non-AddToMap quick-check: e.g., grep the live trace for the function names of OTHER candidate functions (CFIShadowWriter, mprotect, dlopen). If they appear with high `interp #N` density, the original localization was wrong even if the trace at the suspect site looks busy.

- **Scatter-trace then narrow.** Don't add one `TRACE()` at a time and rebuild for every hypothesis. Sprinkle 5–10 `TRACE()` calls across every plausible candidate spot in a single build — every suspect function entry, every backward-branch target, every potential infinite-loop top, every syscall handler, every error-return path. Run one trace capture. The output tells you which spots actually fire and with what frequency / argument values — usually one or two of the scattered points reveal a 1000× anomaly that the others don't, and the narrowing happens in one round-trip instead of N. Cost is one extra build/push; payoff is replacing N cycles of "one-shot diagnostic, capture, revert, next" with one cycle of "broad scatter, narrow, fix." **Strip every temp `TRACE()` before commit** per the existing "no temp debug log in commits" rule — the broad scatter is for diagnosis only, not for shipping.

## Critical Conventions

- **Decoder dispatch order matters.** Multiple instruction groups share encoding prefixes. Always check distinguishing bits (bit29 for LD/ST, bit24 for single/multi struct, bits[11:10] for three-diff/three-same). Missing a bit routes instructions to the wrong handler silently.
- **Verify opcode mappings against the ARM Architecture Reference Manual.** Silent mis-routing (e.g., CMGT vs SMAX, SWP vs LDADD) produces wrong results without crashes until a memory boundary is hit.
- **Never set guest PC to a JIT-cached address for interpreter-fallback instructions.** Use `success_ = false` to install `kInterpreted` at that PC, avoiding infinite re-entry loops.
- **Register spill-to-temp**: When all permanent register slots are full, allocate a temp register and load/store from ThreadState memory. Don't terminate the region — spill instead.
- **PUSH/POP don't affect x86 FLAGS, but SUB/ADD do.** When saving registers before LAHF, use PUSH/POP or LEA, not SUB RSP.
- **Use FaultyLoad/FaultyStore for all interpreter memory accesses.** Raw memcpy causes host SIGSEGV that bypasses guest signal handlers.
- **`// region digitalis` marker placement (binding).** These markers distinguish Digitalis additions from upstream Berberis code, so they belong **only in upstream-derived / shared files** — files that have an upstream counterpart and are compiled for both riscv64 and arm64 (e.g. `guest_os_primitives/guest_signal_handling.cc`, `kernel_api/sys_mman_emulation.cc`, `proxy_loader/proxy_library_builder.cc`, the shared `Android.bp` / `berberis_config.mk`). Two sub-rules:
  1. **Digitalis-created files carry NO markers.** Any file with no upstream equivalent is Digitalis-only by construction — the entire ARM64 backend (`*/arm64/`, `*arm64_to_x86_64/`, `*arm64_to_all/`, `*_arm64.*` paths, e.g. `decoder/arm64/decoder.h`, `interpreter/arm64/interpreter.h`, `lite_translator/arm64_to_x86_64/`, `runtime/arm64/`, `kernel_api/arm64/`) and everything under `sample/hellodigitalis/`. Markers there are pure noise; omit them entirely. Keep the explanatory comment text — a marker that carried a note (`// region digitalis - foo`) becomes a plain comment (`// foo`).
  2. **In a shared file, one `// region digitalis … // endregion` block per *contiguous* run of Digitalis-added lines** (`# region digitalis` in makefiles). Do **not** emit multiple adjacent blocks; if added lines are contiguous (only blank lines between), wrap them in a single block. Merge any run of back-to-back markers into one.
- **Proxy symbol coverage is in-surface and demand-driven.** A guest `lib*.so` symbol the upstream proxy can't auto-marshal is marked `DoBadTrampoline` in `native_bridge_support/.../trampolines_arm64_to_x86_64-inl.h` (generated, read-only) and aborts with `LOG_ALWAYS_FATAL("Bad '<sym>' call")` if called. Cover such symbols **entirely in `binary_translation/`** — never edit `native_bridge_support/`: add a `KnownTrampoline[]` + `__attribute__((constructor(101)))` calling `ProxyLibraryBuilder::RegisterExtraTrampolines("<lib>.so", …)` in `binary_translation/android_api/digitalis_extra_proxy/digitalis_extra_<lib>_trampolines.cc` (the static lib is `whole_static_lib`'d into `libberberis_arm64.so`; the arm64-guarded `InterceptSymbol` override in `proxy_library_builder.cc` lets these beat the primary `DoBadTrampoline`). Most pointer/int signatures need only `GetTrampolineFunc<…>` with `void*` for pointers (valid under LP64 when the pointee layout matches). **Do this on observed need, not preemptively:** most `DoBadTrampoline` symbols are internal C++ (`_ZN7android…`, not NDK-stable), `static inline` JNI helpers that apps inline rather than call, or rare callback/varargs extensions — see `digitalis/docs/proxy-coverage-gaps.md`. Add a custom trampoline when a real app actually hits one. JNIEnv*/JavaVM*-taking symbols need `ToHostJNIEnv`/`ToHostJavaVM` translation (a plain `void*` pass-through is WRONG — the guest env holds guest-callable function pointers), reached via the dlsym'd `callee` so no extra link dependency is added (see `digitalis_extra_libnativehelper_trampolines.cc`). **Fixed-signature callbacks ARE coverable in-surface** with `WrapGuestFunction<Ret, Args…>(guest_fn, name)` (`guest_abi/guest_function_wrapper.h`): it builds a host-callable thunk that routes back through `RunGuestCall`, whose `GetCurrentGuestThread`→`AttachCurrentThread` auto-attaches a guest thread to any host-spawned callback thread (binder/looper/etc.), so async delivery is safe (see `digitalis_extra_libbinder_ndk_trampolines.cc`). Genuinely uncoverable — document in `proxy-coverage-gaps.md` and skip, never guess: variadic callbacks/varargs (`va_list`), fn-ptr *returns* of unknown signature, struct-of-many-callbacks that can't be layout/signature-verified, and C++-mangled / by-value-`sp<>` symbols (not the C ABI, not NDK-stable).
- **Fix root causes in the translator, not workarounds in samples.** When a sample app fails, the bug is in the binary translator (decoder, interpreter, lite translator, proxy libraries, syscall emulation), not the app. Do not modify code under `sample/hellodigitalis/` to work around translator bugs unless explicitly asked to.
- **Write sample logic without considering implementation status.** Samples should exercise their target API surface fully, including intrinsics, instructions, or APIs the translator does not yet implement. If a sample crashes on `Undefined arm64 instruction`, the fix is to add that opcode to `frameworks/libs/binary_translation/` (decoder + interpreter, plus JIT when applicable) — *never* to delete the offending code from the sample. The sample is the spec; the translator catches up to it.
- **Don't bake plan or handoff references into code or commits.** `digitalis-full-support-plan.md` and `digitalis-handoff-*.md` are scaffolding for the dispatch loop, not load-bearing project history. Don't write `// Plan §H1 …` in sources, don't title commits `Plan §C8: …`, don't refer to section letters in inline comments, and **don't reference handoff numbers** (e.g. `// handoff-58 derivation`, `// handoff-253 audit`, `(handoff-14 stale-foreground flake)`). Describe changes on their own terms — reference the ARM ARM section, the instruction encoding, or the upstream Berberis convention being followed. Plan-section labels and handoff-N references are fine inside `digitalis-handoff-*.md` and `digitalis-full-support-plan.md` (those files are themselves dispatch scaffolding); they must not leak from handoffs into shipped code or commit messages.
- **Strip temporary debug logging before committing.** Investigative `__android_log_print`, `printf`, `TRACE`, and similar one-off log lines added while diagnosing a bug must be removed before `git commit`. They pollute production logcat, bias future debugging, and inflate diffs with noise. Load-bearing diagnostics (e.g., the `berberis: trans#N pc=…` region trace, the `Undefined arm64 instruction …` line, sample-side CHECK macros that surface test failures) stay; investigative scaffolding goes. If a debug log proves broadly useful, promote it to a documented diagnostic with a clear comment explaining why it exists.
- **At the end of every dispatch cycle, commit the cycle's verified clean code — even when it only fixes part of a larger problem.** Before writing the handoff, the subagent must run `git status -s` in each sub-repo (`frameworks/libs/binary_translation/`, `sample/hellodigitalis/`, `digitalis/`); if any has changes that satisfy the three-gate commit-readiness check below, commit them as one commit per logical change. Don't accumulate uncommitted work across cycles waiting for a "complete" fix — that's how stray `git stash` / `git reset` / scrub scripts have silently destroyed hours of code in past cycles. Commit-readiness gate (ALL three): (1) **builds clean** — host tests + `m libberberis_arm64`; (2) **target test passes** — the sample/probe/host gtest this cycle was meant to make pass actually passes; (3) **no regression** — the sample suite PASS count hasn't dropped. If all three are true, commit. "Partial fix" framing is fine: `interpreter: implement FCADD vector (FP32 only; FP16 follow-up)` is a perfectly good commit; the FP16 case is the next cycle's commit. The handoff documents scaffolding; the commit is the durable artifact — keep them separate.
- **Don't break the upstream ARM64 build.** Before committing, verify `lunch sdk_phone64_arm64_minigbm-trunk_staging-userdebug && m` still builds clean. Berberis lives in shared paths (`frameworks/libs/binary_translation/`), so translator edits, makefile changes, and proxy-library changes can leak into the native ARM64 image. New commits must keep the existing ARM64 build green. After verifying, switch back to the Digitalis target before resuming x86_64 work.

