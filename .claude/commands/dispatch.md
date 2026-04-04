---
description: "Run the Digitalis dispatch loop — automated handoff-driven development for ARM64-to-x86_64 binary translation. Spawns subagents that read the latest handoff, do real work (edit, build, test, deploy), and write the next handoff. Loops until STATUS: COMPLETE. Invoke with /dispatch or /dispatch <task description>."
---

Run the Digitalis automated dispatch loop via `.claude/digitalis-dispatch.sh`. This script spawns subagents in a loop — each reads the latest handoff, does real work, writes the next handoff, and exits. The loop continues until `STATUS: COMPLETE` is verified.

Run it now with the user's arguments (if any) passed through:

```bash
.claude/digitalis-dispatch.sh $ARGUMENTS
```

If the script fails or the user wants to do a single manual cycle instead, fall back to reading the latest `digitalis-handoff-*.md` (or CLAUDE.md for fresh starts) and doing the work directly in this session. Write the next handoff before finishing.
