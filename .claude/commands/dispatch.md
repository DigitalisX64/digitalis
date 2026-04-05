---
description: "Run the Digitalis dispatch loop — automated handoff-driven development for ARM64-to-x86_64 binary translation. Spawns subagents that read the latest handoff, do real work (edit, build, test, deploy), and write the next handoff. Loops until STATUS: COMPLETE. Invoke with /dispatch or /dispatch <task description>."
---

Run the Digitalis automated dispatch loop via `.claude/digitalis-dispatch.sh`. This script spawns subagents in a loop — each reads the latest handoff, does real work, writes the next handoff, and exits. The loop continues until `STATUS: COMPLETE` is verified.

Run it now with the user's arguments (if any) passed through:

```bash
.claude/digitalis-dispatch.sh $ARGUMENTS
```

If the script fails or the user wants to do a single manual cycle instead, fall back to reading the latest `digitalis-handoff-*.md` (or CLAUDE.md for fresh starts) and doing the work directly in this session. Write the next handoff before finishing.

After making translator changes, verify with both host tests and the sample module test suite:
- Host tests: `m berberis_arm64_host_tests && out/host/linux-x86/nativetest64/berberis_arm64_host_tests/berberis_arm64_host_tests --gtest_filter='Arm64*'`
- Sample modules: `.claude/test-samples.sh` (tests all 22 ARM64 sample apps on the emulator, see `/test-samples`)
