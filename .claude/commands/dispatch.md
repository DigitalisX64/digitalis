---
description: "Run the Digitalis dispatch loop — automated handoff-driven development for ARM64-to-x86_64 binary translation. Spawns subagents that read the latest handoff, do real work (edit, build, test, deploy), and write the next handoff. Loops until STATUS: COMPLETE. Invoke with /dispatch or /dispatch <task description>."
---

Run the Digitalis automated dispatch loop via `.claude/scripts/digitalis-dispatch.sh`. This script spawns subagents in a loop — each reads the latest handoff, does real work, writes the next handoff, and exits. The loop continues until `STATUS: COMPLETE` is verified.

Run it now with the user's arguments (if any) passed through:

```bash
.claude/scripts/digitalis-dispatch.sh $ARGUMENTS
```

If the script fails or the user wants to do a single manual cycle instead, fall back to reading the latest `digitalis-handoff-*.md` (or CLAUDE.md for fresh starts) and doing the work directly in this session. Write the next handoff before finishing.

After making translator changes, verify with host tests, the sample module test suite, and an upstream ARM64 build regression check:
- Host tests: `m berberis_arm64_host_tests && out/host/linux-x86/nativetest64/berberis_arm64_host_tests/berberis_arm64_host_tests --gtest_filter='Arm64*'`
- Sample modules: `.claude/scripts/test-samples.sh` (tests all 22 ARM64 sample apps on the emulator, see `/test-samples`)
- Upstream ARM64 build (mandatory before STATUS: COMPLETE): `lunch sdk_phone64_arm64_minigbm-trunk_staging-userdebug && m`. Berberis sources are shared with the native ARM64 image, so translator/makefile/proxy-library edits can break this build silently. New commits must not break it. After the check passes, run `lunch sdk_phone64_x86_64_digitalis-trunk_staging-userdebug` to restore the Digitalis target before continuing.
