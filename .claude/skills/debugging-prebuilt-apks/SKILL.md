---
name: debugging-prebuilt-apks
description: Diagnose a prebuilt third-party ARM64 APK failing on the Digitalis emulator — crashes (SIGSEGV/SIGILL/abort), hangs and ANRs, or wrong output deep inside a guest library (checksum mismatches, internal throws, garbled rendering). Covers berberis.tracing setup, reading the trace, the traps that waste diagnostic cycles (stale linker base, stale insn_addr, stale inode after adb push, simpleperf/interpreter blind spot), scatter-tracing, and the full-path JIT-vs-interpreter differential. Use before starting any prebuilt-APK investigation.
---

# Debugging prebuilt APKs

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

### Test-first, then on-device tracing (the hello-qt IC IVAU bug)

- **Host test first; go on-device when host tests pass but the device keeps failing.** A host gtest is the fastest loop, but differential fuzzers are blind to bugs needing real region structure / inputs / self-modifying-code timing. After ~2 host repros pass while the device still crashes, stop writing fuzzers — that hypothesis is excluded, the bug isn't.
- **On-device: scatter many traces in ONE build to cut round-trips, then strip them when fixed.** Each build/push/reboot is slow, so instrument every candidate at once (syscall handlers, dispatch, the crash signal handler). At a crash, walk the guest x29 frame chain via `/proc/self/mem` to pin the real call path — `insn_addr` is stale. `git checkout` all diagnostics once the root cause lands.
- **`force-interpret X fixes it` does NOT prove X is buggy** — it changes region chaining, not just X's codegen. Confirm a suspect region's codegen against the interpreter (host test or an on-device JIT-vs-interpreter self-check) before trusting the localization.
- **Reusable gotcha:** ARM64 has no `flush_icache` syscall — user-space JITs (PCRE2/sljit, ART, V8) signal self-modified code with **`IC IVAU`**. A translator must treat `IC IVAU, Xt` as a translation-cache invalidation of the line at `Xt`, not a NOP; otherwise it runs stale translations of regenerated code. `DC CVAU` stays a NOP (shared in-process memory).

### Full-path differential (use it for wrong-output / internal-throw bugs, not just crashes)

When a guest app **throws or returns wrong output deep inside a library** (no SIGILL/SIGSEGV — e.g. `wstring_convert: from_bytes error`, a checksum mismatch, "Bad context map") and host tests pass while the device keeps failing, **trace the DATA through the full call path on-device and diff JIT-vs-interp at each step** until you find where a value first diverges. This converts an unbounded "which instruction is wrong" search into a localized one. Recipe (all crash-free, all proven on the hello-maplibre bug):

1. **Crash-free library base:** read it from the link map in `instrument/instrument.cc`'s `OnConsistentLinkMap` (`link->l_addr` for the target `lib*.so`) into a global the translator reads. NEVER `fopen("/proc/self/maps")` per-call — that ANRs the app (10s attach timeout) and the per-translation fopen storm corrupts diagnostics.
2. **Capture at region-START PCs only.** A hook in `berberis_HandleNotTranslated` / `berberis_HandleInterpret` (keyed on `GetInsnAddr(state->cpu) == base + <off>`) sees the live register/stack state when a region is (re)entered. Most interesting values (a function's args, a `do_in` result, a status byte) live at the instruction **right after a `bl`** — disassemble to find that PC; it is a region start. Mid-region PCs can't be hooked this way.
3. **Per-call capture needs force-interpret.** `HandleNotTranslated` fires once per region (first translation only). To see EVERY call's data, force-interpret a tiny window `[off, off+4)` containing that region (a writable `berberis.filo`/`berberis.fihi`-style knob gating a `kInterpreted` install) so each entry routes through `HandleInterpret`. Force-interpreting a callee's PLT (e.g. `operator delete`) captures every call to it.
4. **Walk the data backward to the source.** Capture the bad value, then its producer's output, then *its* input, … until you reach the first point where JIT and interp disagree. Decode std::string descriptors (`mk=byte[obj]`, `size=[obj+8]`, `data=[obj+0x10]`; bit0 of mk = is-long) and dereference the data buffer — a `size=N, data=<heap ptr>, data-bytes=0` string is an **allocated-but-unfilled / zeroed buffer**, distinct from input corruption or a facet-null.
5. **Bisect with force-interpret windows to pin the region.** Once you know the failing function, force-interpret sub-windows of it; the window that flips FAIL→PASS contains the trigger. **Re-run the flip 3-4× to prove it's deterministic (a real region bug) vs probabilistic (a race/heap-timing artifact).** Then confirm against a control: nearby regions whose interp does NOT flip it.
6. **Dump the suspect region's codegen** with `MachineCode::AsString(&s, InstructionSize::OneByte)` and TRACE it. If the executed path's codegen is provably correct (e.g. the live branch skips the only store/free), the bug is **region-structural** (chaining / code-pool install / never-cleared `recovery_map_`), NOT a per-instruction miscompile. Host single-region replays are blind to these; instrument the code-pool/dispatch/recovery infrastructure instead.

Strip every temp `TRACE`/global/knob before commit (the "no temp debug log in commits" rule); the link-map base + region-start hooks + force-interpret bisection are diagnosis scaffolding only.

