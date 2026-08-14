# Digitalis

ARM64-to-x86_64 binary translation for Android, built on AOSP's Berberis NativeBridge framework. Digitalis enables ARM64-only Android apps (specifically Vulkan apps) to run on x86_64 Android emulators by translating ARM64 instructions to native x86_64 machine code at runtime.

## What This Is

This is an **AOSP 16** (Android Open Source Project, API 36) source tree with modifications to the Berberis binary translator to support ARM64-to-x86_64 translation. Berberis originally supported only RISC-V-to-x86_64; Digitalis adds the ARM64 backend.

`sample/hellodigitalis/` holds 149 ARM64-only sample app modules — the integration test suite. They span ndk-samples ports, proxy-lib smoke tests (including NDK proxy-surface probes: AHardwareBuffer, AImageDecoder, AMediaDataSource/Muxer, ADPF, ASharedMemory, system fonts, OpenMAX AL), ARM-extension probes, UI engines (Qt 6, React Native, Lynx), and third-party native libraries; `ls` the directory for the current set. All 149 are exercised by `test-samples.sh` (`hello-realm` is a standalone pinned-toolchain Gradle project; the suite auto-builds it via its `build-apk.sh` and verifies it by launch).

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

Three execution tiers, all reachable for the same guest code:
- **Lite translator** (first gear, the default entry point): single-pass JIT, ARM64 region -> x86_64, ~98% of instructions, cached.
- **Heavy optimizer** (second gear): re-translates hot regions with SSA MachineIR, global register allocation and loop optimization. Bailing here is correct-but-slow, never a crash.
- **Interpreter**: per-instruction fallback for syscalls, complex SIMD, and anything the JITs don't cover.

## Key Directories

All paths relative to repo root.

| Directory | What It Contains |
|-----------|-----------------|
| `frameworks/libs/binary_translation/` | Berberis core — the binary translator |
| `frameworks/libs/binary_translation/lite_translator/arm64_to_x86_64/` | JIT compiler (ARM64 -> x86_64 native code) |
| `frameworks/libs/binary_translation/heavy_optimizer/arm64/` | Second-gear optimizing JIT (SSA MachineIR frontend) |
| `frameworks/libs/binary_translation/backend/x86_64/` | Shared MachineIR backend — register allocation, guest-context and loop optimizers |
| `frameworks/libs/binary_translation/interpreter/arm64/` | Instruction-by-instruction interpreter fallback |
| `frameworks/libs/binary_translation/decoder/include/berberis/decoder/arm64/` | ARM64 instruction decoder (`decoder.h`, `semantics_player.h`) |
| `frameworks/libs/binary_translation/runtime/arm64/` | Translation cache, dispatch, region management |
| `frameworks/libs/binary_translation/kernel_api/` | Linux syscall emulation (including `arm64/syscall_emulation.cc`) |
| `frameworks/libs/binary_translation/guest_loader/` | ELF loading, NativeBridge init |
| `frameworks/libs/binary_translation/android_api/` | Proxy libraries (libc, libm, libvulkan — forward API calls from guest to host) |
| `frameworks/libs/binary_translation/prebuilt/` | Prebuilt configs including `ld.config.arm64.txt` |
| `device/generic/goldfish/` | Emulator (goldfish) product definitions |
| `device/generic/goldfish/64bitonly/product/sdk_phone64_x86_64_digitalis.mk` | Digitalis product config |
| `sample/hellodigitalis/` | The 149 sample app modules |

## Build

```bash
source build/envsetup.sh
lunch sdk_phone64_x86_64_digitalis-trunk_staging-userdebug
m
```

Or `source digitalis/scripts/lunch-digitalis.sh`. Emulator: `emulator -memory 4096 -writable-system -qemu -cpu host &` (never `-no-window` when debugging an APK).

```bash
# Host unit tests
out/host/linux-x86/nativetest64/berberis_arm64_host_tests/berberis_arm64_host_tests --gtest_filter='Arm64*'
# Samples on the emulator — also --screenshots and --update-references; pass a module name to narrow
.claude/scripts/test-samples.sh
# Sample APKs
cd sample/hellodigitalis && ./gradlew assembleDebug
# Performance: sweep the tiers, then compare against docs/benchmark-results.md
digitalis/scripts/run-benchmarks.sh --repeats 2
digitalis/scripts/summarize-benchmarks.py digitalis/out/bench/<stamp>.ndjson \
    --markdown digitalis/docs/benchmark-results.md
```

Methodology, traps, and how to read a noisy row: `digitalis/docs/benchmarking.md`.

**Upstream ARM64 regression check, before committing.** Berberis lives in shared paths, so translator, makefile and proxy-library edits can leak into the native ARM64 image. Verify `lunch sdk_phone64_arm64_minigbm-trunk_staging-userdebug && m` still builds clean, then `lunch` back to the Digitalis target before resuming x86_64 work. Note `m` on the arm64 product builds no berberis at all — check `m libberberis_riscv64` too.

## Prebuilt-APK regression (sample/prebuilts/)

Any `*.apk` in the `sample/prebuilts/` **root** is an extra regression target, run in addition to (never instead of) `test-samples.sh`. `.claude/scripts/test-prebuilts.sh` installs, launches, watches for `Fatal signal` / `Undefined arm64 instruction` / `FATAL EXCEPTION` / the process vanishing, and exits non-zero on any of those. The directory is a drop-in spot; the APKs are not committed to manifest repos.

- **Mandatory per-cycle gate.** The dispatch loop runs the script at the **end of every cycle**, after `test-samples.sh` and before the handoff, and the handoff copy-pastes its per-APK PASS/FAIL into a `## Prebuilt-APK Status` section. This is how the user tracks prebuilt regressions across cycles — non-negotiable.
- **Stay generic over whatever is dropped in.** No per-APK scripts, no per-APK CLAUDE.md sections, no hard-coded app names anywhere in the dispatch flow. If one APK needs special handling, the underlying bug belongs in `binary_translation/`, not the script.
- **Discovery is top-level only.** `top-apps/` and `top-games/` are the staging area for `digitalis/scripts/fetch-prebuilt-apks.py`; never recurse into them, so this gate and the fetch tool's own verification stay independent.

## Key Files for Development

The most-edited files, with the constraint each one imposes:

- **`lite_translator/arm64_to_x86_64/allocator.h`** — the x86_64 register pool: 13 GP registers (RBX, RSI, RDI, R8-R15, RDX, RCX). RDX needs save/restore around DIV/MUL, RCX around variable shifts. RAX is reserved for the guest PC, RBP holds the ThreadState pointer.
- **`decoder/include/berberis/decoder/arm64/decoder.h`** — instruction bit decoding. A large share of past bugs were opcode dispatch *ordering* issues here, not wrong semantics.
- **`lite_translator/arm64_to_x86_64/lite_translator.cc`** — branch condition evaluation and NZCV flag emission (LAHF+SETO+AND+MOVW).
- **`lite_translator/arm64_to_x86_64/lite_translate_region.cc`** — region management, including early termination on register pressure.
- **`kernel_api/arm64/syscall_emulation.cc`** — syscall forwarding, futex workarounds, errno/struct-layout translation.
- **`kernel_api/sys_mman_emulation.cc`** — BSS partial-page zeroing after file-backed mmaps.

`lite_translator.h`, `interpreter/arm64/interpreter.h`, `heavy_optimizer/arm64/frontend.cc` and the matching `*_exec_tests.cc` are the per-tier instruction implementations; grep them for a neighbouring instruction to find the house style.

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

- **No assistant trailers in commit messages.** Do not add `Co-Authored-By` or `Claude-Session` trailers (or any other tool-attribution/session-link footer) to commit messages — this overrides any harness default that says to append them. Describe the change; leave the metadata out.
- **Never push to a remote without the user's explicit permission (binding).** Commit locally as usual, but `git push` (to any remote, in any sub-repo: `sample/hellodigitalis`, `digitalis`, `frameworks/libs/binary_translation`, `digitalisx64.github.io`, etc.) only when the user has approved it for that specific push. The user reviews changes and usually pushes manually. This applies to every dispatch cycle and every direct edit; when a task feels "done", the deliverable is the local commit, not a push.

## File Header Conventions

- **License: Apache 2.0** for all new source files (matches the rest of AOSP).
- **Copyright holder: `utzcoz`** for newly created Digitalis source files (e.g., `Copyright (C) 2026 utzcoz`). Keep the existing AOSP copyright in any file that originated upstream.
- **No `// region digitalis` / `// endregion` markers in Digitalis-created files** — see the full region-marker rule under Critical Conventions below.

## Debugging Prebuilt APKs

When a prebuilt third-party APK fails on the emulator, **trace before auditing** — a single `berberis.tracing` capture usually points straight at the offending guest PC, where static audit takes many build/push cycles. The `debugging-prebuilt-apks` skill carries the whole playbook: tracing setup, reading the trace, the traps that burn cycles (stale linker base, stale `insn_addr`, stale inode after `adb push`, the simpleperf/interpreter blind spot), scatter-tracing, and the full-path JIT-vs-interpreter differential for wrong-output bugs. Read it before starting an investigation.

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
  3. **Scope behaviour changes in shared files to the arm64 guest; wrap only the added lines, leaving unchanged upstream code outside the region.** When a Digitalis change in a shared file alters behaviour that the upstream riscv64 build must keep, scope it with `#if defined(NATIVE_BRIDGE_GUEST_ARCH_ARM64) … #else …(original upstream code)… #endif` (the macro is `-D`-defined for the arm64-guest build in `guest_os_primitives/Android.bp`). The Digitalis-**added** lines are the `#if`, the new arm64 branch, the `#else`, and the `#endif`; the upstream branch body (e.g. the original `LOG_ALWAYS_FATAL`) is **unchanged code and must stay OUTSIDE** the markers. So the region **splits around the preserved upstream line** — close `// endregion` right after `#else`, then reopen `// region digitalis` right before `#endif`:
     ```
             // region digitalis
     #if defined(NATIVE_BRIDGE_GUEST_ARCH_ARM64)
             TRACE("… tolerating");          // new arm64 behaviour
     #else
             // endregion digitalis
             LOG_ALWAYS_FATAL("…");           // ORIGINAL upstream line — unmarked
             // region digitalis
     #endif
             // endregion digitalis
     ```
     A guarded `#include` (or any guard with no upstream line preserved inside) has nothing unchanged to exclude, so a single block around the whole `#if/#include/#endif` is correct. The principle is invariant: **region markers enclose exactly the lines Digitalis added or changed, never lines copied verbatim from upstream.** This keeps the upstream riscv64 build byte-for-byte unchanged and the Digitalis delta auditable.
- **Proxy symbol coverage is in-surface and demand-driven.** A guest `lib*.so` symbol the upstream proxy can't auto-marshal is marked `DoBadTrampoline` in `native_bridge_support/.../trampolines_arm64_to_x86_64-inl.h` (generated, read-only) and aborts with `LOG_ALWAYS_FATAL("Bad '<sym>' call")` if called. Cover such symbols **entirely in `binary_translation/`** — never edit `native_bridge_support/`: add a `KnownTrampoline[]` + `__attribute__((constructor(101)))` calling `ProxyLibraryBuilder::RegisterExtraTrampolines("<lib>.so", …)` in `binary_translation/android_api/digitalis_extra_proxy/digitalis_extra_<lib>_trampolines.cc` (the static lib is `whole_static_lib`'d into `libberberis_arm64.so`; the arm64-guarded `InterceptSymbol` override in `proxy_library_builder.cc` lets these beat the primary `DoBadTrampoline`). Most pointer/int signatures need only `GetTrampolineFunc<…>` with `void*` for pointers (valid under LP64 when the pointee layout matches). **Do this on observed need, not preemptively:** most `DoBadTrampoline` symbols are internal C++ (`_ZN7android…`, not NDK-stable), `static inline` JNI helpers that apps inline rather than call, or rare callback/varargs extensions — see the coverage inventory in `digitalis/docs/how-it-works.md` §13. Add a custom trampoline when a real app actually hits one. JNIEnv*/JavaVM*-taking symbols need `ToHostJNIEnv`/`ToHostJavaVM` translation (a plain `void*` pass-through is WRONG — the guest env holds guest-callable function pointers), reached via the dlsym'd `callee` so no extra link dependency is added (see `digitalis_extra_libnativehelper_trampolines.cc`). **Fixed-signature callbacks ARE coverable in-surface** with `WrapGuestFunction<Ret, Args…>(guest_fn, name)` (`guest_abi/guest_function_wrapper.h`): it builds a host-callable thunk that routes back through `RunGuestCall`, whose `GetCurrentGuestThread`→`AttachCurrentThread` auto-attaches a guest thread to any host-spawned callback thread (binder/looper/etc.), so async delivery is safe (see `digitalis_extra_libbinder_ndk_trampolines.cc`). Genuinely uncoverable — document in the §13 coverage inventory (`digitalis/docs/how-it-works.md`) and the allowlist, then skip, never guess: variadic callbacks/varargs (`va_list`), fn-ptr *returns* of unknown signature, struct-of-many-callbacks that can't be layout/signature-verified, and C++-mangled / by-value-`sp<>` symbols (not the C ABI, not NDK-stable).
- **Never reference `digitalis/` paths from `binary_translation/` (binding).** `frameworks/libs/binary_translation/` is an independent repo; comments, code, and build files in it must not point at `digitalis/docs/…`, `digitalis/scripts/…`, or any other `digitalis/`-repo path — those paths are meaningless to that repo standalone and rot silently. Keep `binary_translation/` comments self-contained (state the fact inline); documentation links go the other direction only — `digitalis/` docs may reference `binary_translation/` files, never the reverse.
- **Fix root causes in the translator, not workarounds in samples.** When a sample app fails, the bug is in the binary translator (decoder, interpreter, lite translator, proxy libraries, syscall emulation), not the app. Do not modify code under `sample/hellodigitalis/` to work around translator bugs unless explicitly asked to.
- **Write sample logic without considering implementation status.** Samples should exercise their target API surface fully, including intrinsics, instructions, or APIs the translator does not yet implement. If a sample crashes on `Undefined arm64 instruction`, the fix is to add that opcode to `frameworks/libs/binary_translation/` (decoder + interpreter, plus JIT when applicable) — *never* to delete the offending code from the sample. The sample is the spec; the translator catches up to it.
- **Cover all THREE translation tiers for a common fix (binding).** ARM64 guest code runs through three paths: the **interpreter** (`interpreter/arm64/interpreter.h`, per-instruction fallback), the **lite translator** (`lite_translator/arm64_to_x86_64/`, single-pass JIT — the default first gear), and the **heavy optimizer** (`heavy_optimizer/arm64/`, the two-gear second gear). When you implement or fix something *common* — an instruction or behavior that can appear in arbitrary guest code, not a niche/one-off path — you must cover **every tier where it is reachable**, not just the one in front of you. A gap in one tier silently degrades that tier rather than crashing: a missing interpreter/JIT case raises `Undefined arm64 instruction`, but a **heavy-optimizer bail just falls back to lite — correct but slow**, and for a *common* instruction that is a real regression, not a free pass. Concretely, the heavy frontend silently bailing on `ADRP` / `MRS TPIDR_EL0` / `SBFX` (all long-since handled by the interpreter and lite tier) made it bail out of nearly every real-app region, so two-gear never engaged on real apps and a security-SDK CRC loop ran at lite speed and tripped the app's watchdog. So when adding/fixing a common instruction or behavior, explicitly check each tier — *does the interpreter handle it? the lite translator? the heavy optimizer?* — implement it wherever reachable, add a **per-tier test** (interpreter via `InterpretInsn`, lite/heavy via their exec-test harnesses), and state in the commit which tiers were covered and why any was intentionally skipped (e.g. a genuinely heavy-only optimization, or a niche path that legitimately bails). Tier-specific bugfixes (a miscompile in one backend) need only that tier; *new common coverage* needs all of them.
- **Benchmark any change to a translation path before committing (binding).** Correctness gates catch wrong answers; they say nothing about speed, and this project's whole argument is that translated code is fast enough to be useful. Any edit under `interpreter/`, `lite_translator/`, `heavy_optimizer/`, `backend/`, `runtime/` or the proxy libraries — anything on a path guest code executes — needs `digitalis/scripts/run-benchmarks.sh --repeats 2` and a comparison against the committed `digitalis/docs/benchmark-results.md`. Regenerate that file with `--markdown` when the numbers legitimately move, so the change shows up in `git diff` and reviewers see it. Rules for reading the result: a row is only a regression if it moves **beyond the noise** — the summariser flags any case above a 10% relative IQR, and a flagged row proves nothing in either direction, so re-run or resize it rather than quoting it. Judge the tier you touched: an interpreter change that slows the interpreter 3% while leaving the JIT tiers flat is a real (if often acceptable) cost, and one that slows the JIT tiers is a bug in the change. State the numbers in the commit message when they moved. Doc-only, sample-only, and script-only changes are exempt — as is a fix whose whole point is to make something run that previously crashed, where the honest baseline is "did not run at all". *Why this is a gate at all:* the top-byte-ignore fix added a mask to all 22 interpreter address conversions — a correctness fix that lands directly in the hottest loop of a tier, invisible to every existing gate.

- **Decompose into an agent team, then integrate + verify ONCE in the main session (try this pattern first).** When a task splits into independent, separable slices (several instruction categories, several proxy symbols, several files to research, several candidate fixes), fan out one agent per slice writing its slice as a *returned deliverable* rather than editing the tree, then integrate as one batch and run the expensive gate once. Integration is adversarial re-verification, not copy-paste. Full pattern: the `agent-team-decomposition` skill.
- **Don't bake plan or handoff references into code or commits.** `digitalis-full-support-plan*.md` and `digitalis-handoff-*.md` are dispatch scaffolding, not project history. No `// Plan §H1 …` in sources, no `Plan §C8: …` commit titles, no section letters in comments, and no handoff numbers (`// handoff-58 derivation`, `(handoff-14 stale-foreground flake)`). Describe changes on their own terms — the ARM ARM section, the instruction encoding, the upstream Berberis convention being followed. Those labels are fine *inside* the handoff and plan files themselves; they must not leak into shipped code or commit messages.
- **Strip temporary debug logging before committing.** Investigative `__android_log_print`, `printf`, `TRACE`, and similar one-off log lines added while diagnosing a bug must be removed before `git commit`. They pollute production logcat, bias future debugging, and inflate diffs with noise. Load-bearing diagnostics (e.g., the `berberis: trans#N pc=…` region trace, the `Undefined arm64 instruction …` line, sample-side CHECK macros that surface test failures) stay; investigative scaffolding goes. If a debug log proves broadly useful, promote it to a documented diagnostic with a clear comment explaining why it exists.
- **At the end of every dispatch cycle, commit the cycle's verified clean code — even when it only fixes part of a larger problem.** Before writing the handoff, run `git status -s` in each sub-repo (`frameworks/libs/binary_translation/`, `sample/hellodigitalis/`, `digitalis/`) and commit anything that passes all four gates, one commit per logical change: (1) **builds clean** — host tests + `m libberberis_arm64`; (2) **target test passes** — the sample/probe/gtest this cycle was meant to fix actually passes; (3) **no functional regression** — the sample suite PASS count hasn't dropped; (4) **no performance regression** — for any change to a translation path, the benchmark sweep is within noise of `digitalis/docs/benchmark-results.md` (see the rule below). "Partial fix" framing is fine (`interpreter: implement FCADD vector (FP32 only; FP16 follow-up)`); the rest is the next cycle's commit. Don't accumulate uncommitted work waiting for a "complete" fix — that is how stray `git stash` / `git reset` / scrub scripts have silently destroyed hours of work. The handoff is scaffolding; the commit is the durable artifact.
- **Don't break the upstream ARM64 build.** New commits must keep it green — see the regression check under Build.
- **Compile arm64-only changes into the arm64 target only (binding).** Many `.cc` files under `frameworks/libs/binary_translation/` are **shared** — a single source compiled into BOTH `libberberis_riscv64` and `libberberis_arm64` (e.g. `native_bridge/native_bridge.cc`, `guest_loader/*.cc`, `guest_os_primitives/*.cc`, `kernel_api/sys_mman_emulation.cc`, `proxy_loader/proxy_library_builder.cc`, `runtime_primitives/crash_reporter.cc`, `base/tracing.cc`). Any Digitalis change that only makes sense for the **arm64 guest** — Qt/RN/prebuilt-app features (in-APK lib extract, `QT_PLUGIN_PATH` injection), arm64-app-debugging diagnostics, arm64-specific CPUState/behavior — **leaks into the riscv64 build** when added to a shared file: as undefined-symbol link errors if it pulls a new dependency (this is exactly how `native_bridge.cc`'s `libziparchive` use silently broke `libberberis_riscv64` for ~390 commits), or, more quietly, as dead code that bloats and risks the riscv64 image. **Confine such code to arm64 as much as possible:**
  1. **Guard the code with `#if defined(NATIVE_BRIDGE_GUEST_ARCH_ARM64)`** — the include, the function definition, AND every call site (miss one and the symbol is re-introduced). The macro is `-D`-defined only for the arm64-guest flavor (`berberis_arm64_defaults` / each lib's arm64 `Android.bp`), never for riscv64. These guards live INSIDE the existing `// region digitalis` block (the feature is a Digitalis addition with no upstream line to preserve, so one guarded block per run, no `#else`).
  2. **Scope new build dependencies to the arm64 static lib only** (e.g. `libberberis_native_bridge_arm64`), NOT to the shared `cc_defaults` and NOT to the riscv64 target. The fix for a riscv64 link break caused by an arm64 feature is *"guard the code so riscv64 never references it,"* **never** *"add the missing dependency to riscv64 too"* (that papers over the leak and bloats upstream).
  3. **A genuinely shared improvement stays unguarded** — a general robustness fix or bugfix that correctly applies to both guests (e.g. `base/tracing.cc`'s empty-trace-filename guard) belongs to both arches; don't macro-guard it. Guard only what is arm64-specific. When unsure, ask: *would the riscv64 guest ever exercise this path?* If no, guard it.
  4. **Verify BOTH builds every time:** `m libberberis_riscv64` AND `m libberberis_arm64`. An arm64-only edit in a shared path is invisible if you only build the Digitalis target — the riscv64 break only surfaces when you actually compile it. Default posture: when a feature is conceptually guest-arch-specific, guard it **at introduction**, not retroactively.

