# Prebuilt-APK Stability Campaign — Dispatch Prompt

A ready-to-use, reusable dispatch prompt for the iterative prebuilt-APK
stability campaign. Paste the **Dispatch Prompt** section below to drive a
campaign cycle (inline or via `/dispatch`). It encodes the recursive scope, the
runtime-stability acceptance criteria, the Facebook exception, and the
root-cause / fix-and-loop discipline the project requires.

This is **intentionally broader** than the standing top-level-only
`.claude/scripts/test-prebuilts.sh` gate: the campaign tests `sample/prebuilts/`
**recursively** (root drop-ins + `top-apps/` + `top-games/`). Do **not** make
`test-prebuilts.sh` recurse and do **not** add per-app branches or hard-coded
app names anywhere.

---

## Dispatch Prompt

**Objective:** Make EVERY prebuilt ARM64 APK under `sample/prebuilts/` —
recursively, including `top-apps/` and `top-games/` — install, launch, and run
STABLY on the Digitalis emulator. When an APK crashes or misbehaves, fix the
ROOT CAUSE in the binary translator and loop until every prebuilt APK meets the
criteria below.

### Scope
- Test all `*.apk` under `sample/prebuilts/` recursively: the root drop-ins plus
  `top-apps/` and `top-games/`.
- This campaign is intentionally broader than the standing top-level-only
  `test-prebuilts.sh` gate. Do NOT make `test-prebuilts.sh` recurse and do NOT
  add per-app branches or hard-coded app names anywhere.

### Environment
- The Digitalis product bakes an 80G data partition (`config.ini.digitalis`;
  raised from 25G so asset-heavy titles like Genshin Impact have room), so
  launch in visible mode with host GPU and NO `-partition-size` flag:
  `emulator -memory 4096 -writable-system -qemu -cpu host`.
  Use `-wipe-data` once if you need a fresh data partition (the emulator resizes
  the userdata ext4 to the 80G cap on first boot — verify with `df -h /data`).
- After a fresh `-wipe-data` boot, `/system` is read-only until `adb root &&
  adb remount && adb reboot` (overlayfs needs the reboot). `adb push` to /system
  silently no-ops otherwise — ALWAYS verify `adb shell md5sum` of the pushed
  lib equals the build-tree md5 before trusting a repro.
- Reboot the emulator at the start of a clean baseline run so leftover processes
  from prior tests don't contaminate triage (a stray process's crash can be
  misattributed to the app under test).
- Install with runtime permissions granted: `adb install -r -d -g <apk>`.
- Resolve the launch activity with
  `adb shell cmd package resolve-activity --brief <pkg>` and PREFER it over
  `aapt dump badging`'s first launchable-activity (which can be a decoy, e.g.
  LeakCanary's `DisplayLeakActivity`).

### Per-APK acceptance ("runs without crash and stable")
1. Installs successfully.
2. Its main launchable activity starts.
3. The process stays alive through a >=20s watch window with no `Fatal signal`,
   `Undefined arm64 instruction`, `FATAL EXCEPTION`, SIGxx native crash,
   crash-restart loop, or immediate process disappearance.
4. A second launch also comes up cleanly (stable across launches).

### Facebook exception
- `com.facebook.katana` can't satisfy the visual/screenshot scenario; skip any
  visual requirement for it. It PASSES if it installs, launches, and does NOT
  crash or regress (no `Fatal signal` / `Undefined arm64 instruction` /
  `FATAL EXCEPTION`, process stays alive). Don't spend cycles on its rendering.

### When a crash/issue is found
- Fix the ROOT CAUSE in `frameworks/libs/binary_translation/` (decoder,
  interpreter, lite_translator JIT, proxy libraries, syscall emulation,
  mmap/BSS handling) — never a workaround in the app or in the test scripts.
- Read the tombstone FIRST: guest crashes produce full debuggerd tombstones
  (`/data/tombstones/`) with the abort message and mixed host/guest backtrace.
  (If tombstones are missing for translated processes only, the
  `F_SETPIPE_SZ` fcntl passthrough in `kernel_api/fcntl_emulation.cc` has
  regressed — debuggerd needs it to stream the dump.)
- Then diagnose with tracing (see CLAUDE.md "Debugging Prebuilt APKs"):
  `adb root; adb shell setenforce 0;
  adb shell setprop berberis.tracing '<pkg>=digitalis-trace.log'`; reproduce;
  pull and read the trace to localize the offending guest PC / instruction.
  Restore `adb shell setenforce 1` when done. Scatter-trace then narrow.
- For a wrong-output bug (no crash, or a crash far from the cause), build a small
  isolated reproduction (e.g. the `hello-cronet` sample reproduced the TLS bug
  with a trivial HTTPS GET; a host gtest reproduced the ADC carry bug) before
  attempting a fix.
- Typical fixes: implement a missing/mis-dispatched ARM64 instruction (decoder +
  interpreter, + JIT when applicable); cover a `DoBadTrampoline` proxy symbol in
  `android_api/digitalis_extra_proxy/`; add/repair syscall emulation; provision
  a guest file the translator redirects to (e.g. `/system/etc/cpuinfo.arm64.txt`).
- Rebuild `libberberis_arm64`, push the `.so` to the on-image path(s) — on this
  image only `/system/lib64/` exists; `/system/lib64/arm64/` does not — verify
  md5, restart zygote (`adb shell stop && start`), confirm no `(deleted)` inode
  remains in `/proc/<pid>/maps`, then re-test the APK.

### Loop until done
- Iterate cycle by cycle until ALL prebuilt APKs (Facebook under its relaxed
  criterion) pass, OR until the remaining failures are proven NOT translator-
  fixable (GMS/auth-environment, anti-emulator integrity checks, or
  emulator/host-GPU limitations — these cannot pass via translator changes on a
  GMS-less AOSP image). Each cycle, produce a per-APK PASS/FAIL table over the
  recursive prebuilts, the root-cause diagnosis + fix you applied, and the commit
  hash(es). Record findings in `/tmp/campaign-issues.md` (or a handoff).

### Binding discipline (from CLAUDE.md)
- Modify only `binary_translation/`, `device/generic/goldfish/`, `sample/`,
  `digitalis/`. Never `bionic/` or `native_bridge_support/`.
- Strip temporary debug logging before commit; no plan/handoff refs in code or
  commits; no `Co-Authored-By` trailers.
- Commit each verified clean fix (3-gate: builds clean — host tests +
  `m libberberis_arm64`; target APK now passes; sample-suite PASS count not
  reduced). Partial fixes are fine — commit the verified part.
- Keep the upstream ARM64 build green (build `sdk_phone64_arm64_minigbm` /
  `libberberis_riscv64`) before committing translator/shared changes; scope any
  shared-file behaviour change to the arm64 guest with
  `#if defined(NATIVE_BRIDGE_GUEST_ARCH_ARM64)` and wrap only the added lines in
  `// region digitalis` markers (leave verbatim upstream lines outside).
- Run `test-samples.sh` and `test-prebuilts.sh` each cycle and record results.

---

## Known outcome categories (from the campaign so far)

When triaging a FAIL, classify it — not every failure is translator-fixable:

- **Clean translator gap (fix these):** `Undefined arm64 instruction` (missing/
  mis-dispatched opcode), a `CHECK`/abort inside `libberberis_arm64`, a guest
  file the translator redirects to but that is missing, or a wrong-output bug in
  an instruction (decoder mis-dispatch, ADC/SBC carry, etc.).
- **Deep per-app forensics:** a guest `brk`/`__builtin_trap` from a stripped,
  obfuscated commercial native lib (Chromium `CHECK` in Brave; a constructor
  exception swallowed by the app's own breakpad/crashlytics in Shazam). May or
  may not be translator-caused; needs symbolized debugging.
- **fd-ownership (fdsan) aborts:** an abort message like `fdsan: attempted to
  close file descriptor N, expected to be owned by …, actually unowned` means
  a file descriptor's ownership tag was violated across the guest/host
  boundary. Two shapes seen so far: Berberis closing an fd with a stale tag
  (fixed — `ScopedFd` now closes with the fd's current tag), and a host owner
  finding its tag already cleared, suggesting a guest-side `close()` on an fd
  the proxy layer handed over without `dup()` (open — Kuaishou's host-side
  `Fence::~Fence` abort in the buffer-release path). Translator-side
  candidates: proxy libs passing sync/fence fds (libnativewindow,
  AHardwareBuffer, Vulkan fence export).
- **Environment-limited (NOT translator-fixable on this image):** Java
  `FATAL EXCEPTION` from missing Google Play Services / auth (most Microsoft,
  shopping, and social apps), anti-emulator/integrity checks (Supercell, Signal),
  and emulator/host-GPU limitations (e.g. gfxstream lacking `VK_EXT_memory_budget`,
  which aborts the renderer for some Unity titles).

An all-PASS table is therefore not guaranteed by translator fixes alone for an
arbitrary batch: a real subset can be environment-gated. State that explicitly
rather than manufacturing low-confidence "fixes" by guessing at app internals.
