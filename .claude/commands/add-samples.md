---
description: "Grow the hellodigitalis suite. Given a number N, recommend N commonly-used Android libraries that ship native (.so) code and aren't covered yet; on approval, fan out an agent team (max 20 parallel) to write the samples, then the main session integrates, builds, verifies on the emulator, fixes any translator root-cause bug, and commits them one by one. Invoke with /add-samples <N>."
argument-hint: "<number of new samples>"
---

Grow the `sample/hellodigitalis` suite with new third-party native-library samples. `$ARGUMENTS` is the count **N** of samples to recommend.

This runs in three phases. **Do Phase 1, then STOP and wait for the user to approve / edit the list. Only start Phase 2 after explicit approval.**

---

## Phase 1 — Recommend N libraries (no writing yet)

1. **List what already exists** so you never recommend a duplicate:
   ```bash
   ls -d sample/hellodigitalis/hello-* | xargs -n1 basename | sort
   ```
   Also skim `sample/hellodigitalis/README.md` for the covered-library table.

2. **Pick N commonly-used libraries that (a) ship an ARM64 native `.so`, (b) are popular in real Android apps, and (c) are not already covered.** Good hunting grounds, by category: media/codecs, image processing & graphics, vision/ML, crypto/DB/storage, compression, serialization, networking, audio/DSP, JS/runtime engines, game/physics. Prefer libraries distributed as a Maven `@aar` that bundles `jni/arm64-v8a/lib*.so` (a bionic-linked Android native that loads under translation) — the plain `.jar` usually ships only glibc/mac/win natives and won't work.

3. **For each candidate, verify it actually ships an arm64-v8a native** before recommending it (don't guess). A quick way:
   ```bash
   # Resolve the AAR and confirm it contains jni/arm64-v8a/*.so
   # (use the exact Maven coordinate you intend to put in build.gradle.kts)
   ```
   If you can't confirm an arm64-v8a `.so`, drop it and pick another.

4. **Present the recommendation as a numbered table** and then stop:

   | # | Sample module | Library | Native `.so` it exercises | Maven coordinate | What the sample stresses (ABI / instructions) |
   |---|---|---|---|---|---|

   Add one line on *why each is a good translator test* (e.g. heavy NEON/SIMD, FP, crypto rounds, atomics, JNI-heavy, large memory ops). Then ask the user to **approve, drop, or swap** entries. Use `AskUserQuestion` only if a genuine either/or decision blocks you; otherwise just print the table and wait.

> Recommend exactly N unless you can't find N that meet the bar — in that case say how many you found and why, and list them.

---

## Phase 2 — Agent team writes the samples (after approval, max 20 parallel)

Fan out **one agent per approved library**, capped at **20 concurrent**. If the approved count exceeds 20, run in waves of ≤20 and integrate each wave before starting the next.

**Each agent's job: create one complete sample module directory and nothing else.** Module dirs are disjoint, so parallel writes don't collide — but the two shared registration files are **off-limits to agents** (the main session owns them, see Phase 3). Tell every agent explicitly:

- Create `sample/hellodigitalis/hello-<lib>/` by **copying an existing third-party-native-lib sample as the structural template** (e.g. `hello-zstd`) and adapting it. The module must contain:
  - `build.gradle.kts` — `alias(libs.plugins.android.application)`; `namespace`/`applicationId` = `com.example.hellodigitalis.hello<lib>`; `ndk { abiFilters += "arm64-v8a" }`; `testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"`; the library dependency (the verified `@aar`); and `androidTestImplementation(project(":status-test-lib"))` (use `:screenshot-test-lib` instead only if the sample renders pixels).
  - `src/main/AndroidManifest.xml` and `res/` (copy from the template; rename the launcher label).
  - `src/main/java/com/example/hello<lib>/MainActivity.kt` — **actually drive the library's native code path** (compress/decompress, encode/decode, hash, run inference, parse, etc.), verify the result is correct, and write an unambiguous success or failure marker to logcat that the `StatusTest` checks. Exercise the real API surface fully; **do not avoid intrinsics/instructions the translator might not support yet** — the sample is the spec, the translator catches up to it.
  - `src/androidTest/java/com/example/hellodigitalis/hello<lib>/StatusTest.kt` — a `StatusTestRule(<component>, <timeoutMs>)` + `assertRunsCleanly()`, mirroring `hello-zstd/.../StatusTest.kt`. The component string is `com.example.hellodigitalis.hello<lib>/com.example.hello<lib>.MainActivity`.
- The agent must **NOT** edit `settings.gradle.kts`, `test-samples.sh`, the README, or anything outside its own module dir.
- The agent returns a short deliverable: the module path, the Maven coordinate, the exact `am start` component string, and what success looks like in logcat.

Follow the file-header conventions for any new source the agent authors (Apache-2.0, `Copyright (C) 2026 utzcoz`; no `// region digitalis` markers — `sample/hellodigitalis/` is Digitalis-only by construction).

---

## Phase 3 — Main session integrates, verifies, fixes, commits one by one

Do this **serially, one sample at a time** (the build/deploy/test gate is the slow part; one bad sample shouldn't block the rest — integrate the good ones, isolate the broken one). For each new module:

1. **Register it in the two shared files** (only the main session touches these):
   - `sample/hellodigitalis/settings.gradle.kts`: add `include(":hello-<lib>")`.
   - `digitalis/.claude/scripts/test-samples.sh`: add a `MODULES["hello-<lib>"]="com.example.hellodigitalis.hello<lib>/com.example.hello<lib>.MainActivity"` entry and append `hello-<lib>` to `MODULE_ORDER` (and to `SCREENSHOT_MODULES` only if it renders). `TEST_CLASSES` is derived automatically — no extra entry needed.

2. **Build it:**
   ```bash
   cd sample/hellodigitalis && ./gradlew :hello-<lib>:assembleDebug
   ```
   Gradle/extract caches can serve a stale `.so` — if rebuilding a changed sample, use `--rerun-tasks` and `pm clear` the app before re-testing.

3. **Verify on the emulator** (boot it if needed — see `/test-samples`). Run the gate for just this module:
   ```bash
   .claude/scripts/test-samples.sh --status hello-<lib>      # or --screenshots for renderers
   ```
   PASS = the app ran clean and `StatusTest` saw the success marker.

4. **If the sample surfaces a translator bug** (`Undefined arm64 instruction`, SIG11/SIG4/SIG6, a proxy `Bad '<sym>' call`, a wrong-output `CHECK` failure): **fix the root cause in `frameworks/libs/binary_translation/`, never in the sample.** This is binding:
   - Missing instruction → add it to the decoder + interpreter (+ lite JIT, + heavy optimizer where reachable). For a *common* instruction, cover **all three tiers** and add a per-tier test.
   - Proxy gap (`DoBadTrampoline`) → cover it in-surface under `android_api/digitalis_extra_proxy/` (see the §13 coverage inventory in `how-it-works.md`), never edit `native_bridge_support/`.
   - Syscall/struct/signal issue → `kernel_api/` or `guest_os_primitives/`.
   - Prefer a trace (`berberis.tracing`) over a static audit to localize the offending guest PC. Strip any temporary debug logging before committing.

5. **Guard against regressions before committing each sample** (the three-gate readiness check):
   1. Builds clean — relevant host tests + `m libberberis_arm64` if you touched the translator (and `m libberberis_riscv64` if you touched a shared file; guard arm64-only changes with `#if defined(NATIVE_BRIDGE_GUEST_ARCH_ARM64)`).
   2. This sample's `StatusTest`/`ScreenshotTest` passes.
   3. The existing sample suite PASS count hasn't dropped (`.claude/scripts/test-samples.sh`).

6. **Commit, one logical change at a time:**
   - One commit per sample: `sample/hellodigitalis: add hello-<lib> (<library> native smoke test)` — include the module + its `settings.gradle.kts` + `test-samples.sh` registration.
   - If a translator fix was needed, commit that **separately and first** (in `frameworks/libs/binary_translation/`), described on its own terms (the instruction encoding / ARM ARM section / proxy symbol — never plan/handoff/commit-hash references), then commit the sample.
   - Conventions: **no `Co-Authored-By` trailers; never `git push`** (commit locally; the user reviews and pushes). Run `git status -s` in each sub-repo and commit verified-clean work even if some samples in the batch are still failing.

7. **After all samples in the batch:** update `sample/hellodigitalis/README.md`'s covered-library table and module count, and report a final PASS/FAIL summary per sample plus any translator fixes landed.

> If a sample can't be made to pass because the underlying library genuinely can't run under translation yet (e.g. a missing host backend, not a translator bug), say so explicitly, leave it uncommitted or document it as a known gap, and move on — don't fake a pass and don't water down the sample to dodge the bug.
