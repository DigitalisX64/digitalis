#!/bin/bash
#
# digitalis-dispatch.sh — Automated dispatch system for Digitalis development
#
# Runs a loop of Claude Code subagents. Each subagent:
#   1. Reads the latest handoff-N.md
#   2. Does real work (edit, build, test, deploy, check logs)
#   3. Writes handoff-(N+1).md with progress
#   4. Exits
#
# The loop continues until a subagent writes STATUS: COMPLETE and
# verification confirms hello-digitalis is actually running.
#
# Usage:
#   ./digitalis-dispatch.sh                              # Continue from latest handoff
#   ./digitalis-dispatch.sh "Fix STLR root cause"        # Fresh start with initial idea
#   DIGITALIS_MAX_BUDGET=30 ./digitalis-dispatch.sh      # Custom budget per cycle
#
# Environment variables:
#   DIGITALIS_MAX_RETRIES  - Retries per cycle on error (default: 3)
#   DIGITALIS_RETRY_WAIT   - Seconds to wait between retries (default: 300)
#   DIGITALIS_MAX_BUDGET   - Max USD per subagent run (default: 40)
#   DIGITALIS_MAX_CYCLES   - Max total cycles before giving up (default: 50)
#   DIGITALIS_MODEL        - Claude model to use (default: opus)

set -euo pipefail

# Derive WORK_DIR (AOSP root) by walking up from script location until we find build/envsetup.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}" && while [[ "$PWD" != "/" ]]; do
    if [[ -f "$PWD/build/envsetup.sh" ]]; then echo "$PWD"; exit 0; fi
    cd ..
done
echo "${SCRIPT_DIR}/../.." )"
HANDOFF_PREFIX="digitalis-handoff"
LOG_DIR="/tmp/digitalis-dispatch"

MAX_RETRIES=${DIGITALIS_MAX_RETRIES:-3}
RETRY_WAIT=${DIGITALIS_RETRY_WAIT:-300}
MAX_BUDGET=${DIGITALIS_MAX_BUDGET:-40}
MAX_CYCLES=${DIGITALIS_MAX_CYCLES:-200}
MODEL=${DIGITALIS_MODEL:-opus}
# Reboot the emulator every N cycles (0 disables). A very long run drifts into
# the emulator-exhaustion flake (SystemUI ANR, low MemAvailable, spurious
# SEGV_ACCERR on prebuilt apps) that a reboot clears; automating it keeps long
# runs from silently producing false crash/regression signals. Also reboots on
# a detected unhealthy emulator (no device, or MemAvailable below the floor).
REBOOT_EVERY_CYCLES=${DIGITALIS_REBOOT_EVERY:-25}
REBOOT_MEM_FLOOR_KB=${DIGITALIS_REBOOT_MEM_FLOOR_KB:-250000}

# Auto-relaunch a DEAD emulator process. `adb reboot` only restarts the guest OS
# inside a still-running qemu; if the qemu process itself exits (host OOM-kill,
# crash, manual pkill), every subsequent device gate silently fails and the loop
# stalls with no recovery path. When these paths are set and the qemu process is
# gone, the loop relaunches the emulator via the same recipe used to start it.
# Leave EMULATOR_BIN pointing at a non-existent path to disable (host-only runs).
EMULATOR_BIN=${DIGITALIS_EMULATOR_BIN:-${WORK_DIR}/prebuilts/android-emulator/linux-x86_64/emulator}
EMULATOR_PRODUCT_OUT=${DIGITALIS_PRODUCT_OUT:-${WORK_DIR}/out/target/product/emu64xa}
EMULATOR_LOG=${DIGITALIS_EMULATOR_LOG:-${HOME}/emu_digitalis.log}

mkdir -p "$LOG_DIR"

# ──────────────────────────────────────────────
# Find the highest-numbered handoff-N.md
# ──────────────────────────────────────────────
find_latest_handoff() {
    local latest=0
    for f in "${WORK_DIR}/${HANDOFF_PREFIX}"-*.md; do
        [[ -f "$f" ]] || continue
        local num
        num=$(basename "$f" .md | sed "s/${HANDOFF_PREFIX}-//")
        if [[ "$num" =~ ^[0-9]+$ ]] && (( num > latest )); then
            latest=$num
        fi
    done
    echo "$latest"
}

# ──────────────────────────────────────────────
# Build the prompt for a subagent
# ──────────────────────────────────────────────
build_prompt() {
    local current=$1
    local next=$2
    local input_file="${WORK_DIR}/${HANDOFF_PREFIX}-${current}.md"
    local output_file="${HANDOFF_PREFIX}-${next}.md"
    local user_idea="${3:-}"

    # PRIMARY-TASK precedence.
    # If the latest handoff exists AND its STATUS is IN_PROGRESS, the cycle's
    # PRIMARY task is to advance that handoff's "What Should Be Done Next"
    # list. The hardcoded sample-suite GOAL below is downgraded to "background
    # — don't regress this" when there's IN_PROGRESS handoff work to continue.
    # Without this gate, every cycle past #1 reads the hardcoded GOAL as if
    # it were the user's request, regardless of what the previous cycle was
    # actually working on.
    local handoff_status=""
    if [[ -f "$input_file" ]]; then
        handoff_status=$(grep -E '^## STATUS:' "$input_file" 2>/dev/null | tail -1 | head -c 80)
    fi
    if [[ "$handoff_status" == *IN_PROGRESS* ]]; then
        cat <<HANDOFF_PRIMARY
You are a subagent working on the Digitalis project — an ARM64-to-x86_64 binary translation system built on AOSP's Berberis framework.

PRIMARY TASK (override sample-suite GOAL below):

Picking the next target — MANDATORY ORDER (do not skip steps):

  STEP 1 — Read the "## CURRENT PRIORITY QUEUE" section near the top
    of digitalis-full-support-plan.md. It is the authoritative source
    for what to work on. Tier 1 items there are plan-listed and
    ledger-moving.

  STEP 2 — Read ${HANDOFF_PREFIX}-${current}.md. Look specifically
    for: (a) a "USER DIRECTIVE" block in the "## What Should Be Done
    Next" section (out-of-band guidance from the user — this overrides
    everything), and (b) Tier 1.5 single-cycle correctness wins
    flagged in that section.

  STEP 3 — Pick a target by this rule, in order:
    a. If a USER DIRECTIVE block names a specific next target, do that.
    b. Otherwise, if Tier 1 in the plan's priority queue has ANY
       open item, pick one. The handoff's "Recommendation for next
       cycle:" line is ADVISORY ONLY when Tier 1 has open items —
       prefer Tier 1 over the handoff's recommendation.
    c. Only if Tier 1 is fully exhausted may you pick from Tier 1.5
       (single-cycle correctness wins) or Tier 2 (carry-forward gap-
       fills, the handoff's "Recommendation" line).

  HARD RULE: The dispatch has drifted through 100+ cycles of single-
  cycle SIMD encoding-gap fills while Tier 1 plan items remained
  unchecked. The plan ledger has been stuck at 117/142 (82%) for many
  cycles for this exact reason. Stop the drift. If you find yourself
  about to start a Tier 2 item while Tier 1 is non-empty, STOP and
  reread STEP 3 above.

If you finish a Tier 1 item, OR if you find that the priority queue
is no longer correct given new evidence, write a NEW handoff explaining
what you found and either set STATUS: IN_PROGRESS with a fresh
"What Should Be Done Next" list (preserving any USER DIRECTIVE
block from the previous handoff verbatim), or STATUS: COMPLETE if the
user-level goal in the user_idea (if any) is met.

Your handoff's "What Should Be Done Next" section MUST:
  - Preserve any USER DIRECTIVE block verbatim from the prior handoff.
  - List Tier 1 items first (mirroring the plan's priority queue), so
    the next cycle picks one of them. The "Recommendation for next
    cycle:" line at the bottom MUST point at a Tier 1 item if any
    are open.

HANDOFF_PRIMARY
        if [[ -n "$user_idea" ]]; then
            cat <<USER_GOAL
USER GOAL (the question that started this dispatch chain — keep this
in mind at every decision; if the in-progress next-steps no longer serve
this goal, course-correct):
${user_idea}

USER_GOAL
        fi
        echo "BACKGROUND (do not regress, but do not re-investigate either):"
    fi

    cat <<'PROMPT_HEADER'
You are a subagent working on the Digitalis project — an ARM64-to-x86_64 binary translation system built on AOSP's Berberis framework.

GOAL: Make all 22 ARM64-only sample apps in sample/hellodigitalis:
1. Run without crashing (0 CRASH in test-samples.sh)
2. Pass screenshot tests (0 FAIL in test-samples.sh --screenshots)

Screenshot tests capture the screen after 5 seconds, crop system bars, and compare pixel-by-pixel
against a reference image (>=95% match required). Reference images are in each module's
src/androidTest/assets/reference/screenshot_default.png.

### What each screenshot test validates

Each module has a reference image at src/androidTest/assets/reference/screenshot_default.png.
Some references are currently BROKEN (blank/corrupt) — these must be fixed by fixing the
underlying translator bug, then running --update-references to capture correct images.

**3D rendering — must show rendered geometry, not a black/blank screen:**
| Module | Expected content | Reference status |
|--------|-----------------|-----------------|
| hello-vulkan | Colored triangle on dark background | OK (81K colors) |
| hello-gl2 | Green triangle on black background | OK |
| gles3jni | Instanced colored quads | BROKEN — corrupt 131-byte PNG |
| teapots-classic | 3D teapot on gray background | OK (1K colors) |
| teapots-more | Multiple 3D teapots on gray background | OK (114K colors) |
| teapots-textured | Textured 3D teapot on gray (glClearColor 0.5,0.5,0.5) | BROKEN — all black, should look like teapots-classic |
| endless-tunnel | 3D tunnel scene with obstacles | OK |
| sensor-graph | Graph lines on black background | OK (minimal data in emulator) |

**2D rendering:**
| Module | Expected content | Reference status |
|--------|-----------------|-----------------|
| bitmap-plasma | Plasma color pattern | OK (3.5K colors) |
| native-activity | Solid color (cycles RGB each second, green at 5s) | OK — solid green is correct |

**Text/UI — must show text, not blank screen:**
| Module | Expected content | Reference status |
|--------|-----------------|-----------------|
| hello-jni | "Hello from JNI" text | OK |
| hello-jniCallback | Timer HH:MM:SS | OK |
| exceptions | Exception handling demo text | BROKEN — all white, should have text like sanitizers |
| native-audio | Audio playback controls UI | OK |
| native-codec | Video codec UI with controls | OK |
| native-midi | MIDI controls UI | OK |
| sanitizers | Sanitizer demo text output | OK |
| unit-test | "1 + 2 = 3" text | OK |
| vectorization | Benchmark results table (Jetpack Compose) | BROKEN — all (250,250,250), should have text like unit-test |
| orderfile | "Hello, world!" text | OK |

**Camera — emulator has no real camera, blank preview expected:**
| Module | Expected content | Reference status |
|--------|-----------------|-----------------|
| camera-basic | Camera UI with controls (blank preview OK) | OK — (238,237,246) system gray |
| camera-texture-view | Camera TextureView (blank preview OK) | OK — same system gray |

### BROKEN references that need fixing (4 modules)
These pass screenshot tests only because the reference itself is blank/corrupt.
Fix the translator bug first, then update the reference:
1. **teapots-textured** — all black (ifstream/locale deadlock prevents rendering)
2. **vectorization** — all light gray (Compose UI never mounts, JNI benchmark stalls)
3. **gles3jni** — corrupt 131-byte PNG (ES3 renderer black screen)
4. **exceptions** — all white (exception text never displayed)

After fixing each, update its reference:
  .claude/scripts/test-samples.sh --update-references <module>

If a screenshot test fails, the likely causes are:
- **Black screen**: Rendering pipeline broken (GL/Vulkan proxy, buffer mapping, shader compilation)
- **Wrong content**: Instruction translation bug (wrong colors, corrupted geometry, missing text)
- **Crash before render**: App died before 5s screenshot capture (check liveness test first)
- **Test passes but blank**: Reference image itself is broken — fix the bug, update reference

You are part of an automated dispatch pipeline. You will:
1. Read context (previous handoff or CLAUDE.md for fresh starts)
2. Do real, concrete work (edit code, build, test, deploy, check logs)
3. Write a new handoff document recording your progress
4. Exit

PROMPT_HEADER

    if [[ -f "$input_file" ]]; then
        echo ""
        echo "## Input"
        echo "Read this file first: ${HANDOFF_PREFIX}-${current}.md"
        echo "It contains context from the previous cycle: what was done, current state, rules, and build commands."
        echo ""
        if [[ -n "$user_idea" ]]; then
            echo "## Priority Task (OVERRIDE)"
            echo "The user has specified this task. Work on it instead of the handoff's \"What Should Be Done Next\" list:"
            echo "$user_idea"
            echo ""
        fi
        echo "## Output"
        echo "Write your progress to: ${output_file}"
        echo ""
    else
        echo ""
        echo "## Fresh Start"
        echo "No previous handoff exists. Read CLAUDE.md first to understand the project context."
        echo ""
        if [[ -n "$user_idea" ]]; then
            echo "The initial idea / task:"
            echo "$user_idea"
            echo ""
        fi
        echo "Do real work — investigate, edit code, build, test. Do NOT just write a plan."
        echo "Write your progress to: ${output_file}"
        echo ""
    fi

    cat <<'PROMPT_RULES'
## Rules (MUST FOLLOW)

1. **Fail fast**: implement → build → test → deploy → check logs → iterate.
2. **Never touch timeout_multiplier**: Do NOT change `hw_timeout_multiplier`, `timeout_multiplier`, or any timeout scaling values. Do NOT add, increase, or reference these values in code or config. This is a hard rule with no exceptions.
3. **Small changes**: One fix at a time. Verify before moving to the next.
4. **Region markers**: Use `// region digitalis` / `// endregion` around all changes in existing files.
5. **Read before edit**: Always read a file before modifying it.
6. **No blind sleeps**: NEVER use `sleep` to wait for boot or device readiness. Always poll `sys.boot_completed` as shown in the build commands below. Max 60 iterations (60s) then give up.
7. **Reuse running emulator**: Before killing and rebuilding, check if an emulator is already booted (`adb shell getprop sys.boot_completed`). If so, and you only changed sample app code (not translator code), just rebuild APKs and reinstall — no emulator restart needed.
8. **Write handoff early**: Write your handoff document as soon as you have results, BEFORE doing extensive screenshot analysis or secondary investigations. You can always update it. Don't spend 20+ minutes analyzing screenshots before writing anything.
9. **Budget awareness**: You have a limited budget. Prioritize: (a) read handoff, (b) make code fixes, (c) build, (d) test, (e) write handoff. Don't spend budget on elaborate screenshot verification loops.
10. **Skip screenshot baseline maintenance unless the active fix touches rendering.** Do NOT run `--update-references` for "missing reference" modules as a side quest — this rebuilds androidTest APKs and pulls images for each module, easily burning 20-30 minutes per cycle on infrastructure that has nothing to do with the active goal. If the previous handoff identifies a rendering bug AND the current cycle is fixing it, then `--update-references <module>` is appropriate after the fix. Otherwise the per-cycle gate is `test-samples.sh` (basic, no flag) + `test-prebuilts.sh`; `--screenshots` is an opt-in regression check, not a required step.

## Build, Deploy & Test Commands

### If translator code changed (decoder.h, interpreter.h, lite_translator.h, etc.)
Full rebuild + emulator restart required:
```bash
source build/envsetup.sh && lunch sdk_phone64_x86_64_digitalis-trunk_staging-userdebug
pkill -9 -f qemu-system-x86_64 || true; sleep 2
m
nohup emulator -no-snapshot -writable-system > /tmp/emu.log 2>&1 &
n=0; while [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ] && [ $n -lt 60 ]; do sleep 1; n=$((n+1)); done
if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; then echo "ERROR: Boot did not complete"; exit 1; fi
adb root && sleep 2 && adb remount
```

### If only sample app code changed
Just rebuild APKs and reinstall (fast):
```bash
cd sample/hellodigitalis && ./gradlew assembleDebug && cd ../..
# Then use .claude/scripts/test-samples.sh to test
```

### Test all samples
```bash
.claude/scripts/test-samples.sh              # all 22 modules
.claude/scripts/test-samples.sh hello-vulkan  # single module
```

### Host-only tests (no emulator needed)
```bash
source build/envsetup.sh && lunch sdk_phone64_x86_64-trunk_staging-userdebug
m berberis_arm64_host_tests
out/host/linux-x86/nativetest64/berberis_arm64_host_tests/berberis_arm64_host_tests --gtest_filter='Arm64*'
```

### MANDATORY verification for any translator change (do NOT skip — these caught real ship-blockers)

1. **Never trust a stale test binary.** ALWAYS rebuild the test binary in the
   SAME `m` as the libs, then run it: `m libberberis_arm64 libberberis_riscv64
   berberis_arm64_host_tests` and only then run
   `berberis_arm64_host_tests`. Running the host tests WITHOUT rebuilding them
   reports a stale PASS — a broken commit (unused-function build error, or a
   miscompile) once landed this way with a fake "PASS". If the build fails
   (e.g. `-Werror,-Wunused-function` on a helper whose test you forgot), FIX
   it before committing; a green host run on a stale binary is not a pass.
2. **Deploy to BOTH /system paths with an md5 check.** `adb push` the fresh
   lib to `/system/lib64/libberberis_arm64.so` AND
   `/system/lib64/arm64/libberberis_arm64.so`, then `adb shell md5sum` both and
   confirm they equal the built file's md5. A running process keeps the old
   inode mapped, so a stale deploy silently tests old code (a fix looked
   "not working" this way).
3. **Heavy-optimizer changes MUST pass the renderer gate.** A
   `heavy_optimizer/` miscompile can pass every per-op host exec test and the
   main-process prebuilt gate yet DETERMINISTICALLY crash a Chromium *renderer*
   (an "Aw, Snap!" — the browser process stays alive so the old gate missed
   it). After deploying, run `digitalis/scripts/test-renderer-heavy.sh` (heavy
   tier on, md5-verified deploy, Helium ×3). A renderer crash = a real
   regression: **bail the offending op to lite** (correct-but-slow) rather than
   ship the miscompile, and add a region-level test before re-enabling it.

## Handoff Document Format

Your output handoff document MUST follow this exact structure:

```
# Digitalis Handoff #N: [Brief Title]

## What Was Done
[Describe each change with file paths and technical details]

## How It Was Verified
[What tests were run, what logs were checked, what was the result]

## Current State
[Is hello-digitalis running? What's the current behavior?]

## Files Modified (This Session)
| File | Change |
|------|--------|
| ... | ... |

## Current Blocker (if any)
[What's preventing progress, with technical details]

## What Should Be Done Next
[Prioritized list of next steps]

## Rules for Working on This Project
[Copy rules from previous handoff, add any new lessons learned]

## Build & Test
[Copy build commands]

## STATUS: IN_PROGRESS
```

## Completion

When ALL 22 sample modules pass:
1. `.claude/scripts/test-samples.sh` (0 CRASH — apps launch without crashing)

`--screenshots` is an opt-in regression check; do not block completion on it
unless the active cycle is explicitly fixing a rendering bug.

Change the last line to: `## STATUS: COMPLETE`

Otherwise keep it as: `## STATUS: IN_PROGRESS`

## Mandatory Per-Cycle Prebuilt-APK Verification

At the end of every cycle, **after** `test-samples.sh` and **before**
writing the handoff, run:

```bash
.claude/scripts/test-prebuilts.sh
```

This scans every `*.apk` under `sample/prebuilts/`, installs and
launches each one on the booted emulator, and reports per-APK
PASS/FAIL. Whichever APKs happen to be present in the directory get
tested — the script discovers them at runtime; do NOT assume any
specific app names.

In the handoff, include a section titled exactly `## Prebuilt-APK
Status` that **copy-pastes** the script's `=== Prebuilt-APK regression
===` block (one line per APK, plus the `Results: N PASS, M FAIL`
line). If the emulator wasn't running this cycle, the script will
report so and exit 0 — record that in the section verbatim. This is
non-negotiable; the user reads this section to track prebuilt-APK
status across cycles.

## IMPORTANT

- START by reading the handoff document (or CLAUDE.md for fresh starts). It has all the context you need.
- DO real work. You have full tool access — edit files, run builds, deploy, check logs.
- WRITE your handoff document EARLY — as soon as you have test results. Don't delay writing it.
- Be SPECIFIC in your handoff — include exact file paths, line numbers, error messages.
- If you can't make progress on the top priority, document WHY and move to the next item.
- BUDGET: You have limited budget per cycle. Focus on ONE fix per cycle, verify it, write the handoff, and exit. Don't try to do everything in one cycle.
PROMPT_RULES
}

# ──────────────────────────────────────────────
# Run a single subagent cycle
# Returns 0 on success, 1 on failure
# ──────────────────────────────────────────────
run_subagent() {
    local current=$1
    local next=$2
    local user_idea="${3:-}"
    local log_file="${LOG_DIR}/cycle-${next}.log"
    local prompt_file
    prompt_file=$(mktemp "${LOG_DIR}/prompt-${next}-XXXXX.txt")

    build_prompt "$current" "$next" "$user_idea" > "$prompt_file"

    echo "[$(date '+%H:%M:%S')] Prompt written to ${prompt_file} ($(wc -c < "$prompt_file") bytes)"
    echo "[$(date '+%H:%M:%S')] Log: ${log_file}"
    echo "[$(date '+%H:%M:%S')] Running claude -p --model ${MODEL} --max-budget-usd ${MAX_BUDGET} ..."
    echo ""

    # Run claude with stream-json output piped through a progress filter.
    # The filter shows compact tool-call lines and a heartbeat every 30s,
    # while writing the full raw stream to log_file.
    local exit_code=0
    if (cd "${WORK_DIR}" && claude -p \
        --dangerously-skip-permissions \
        --model "${MODEL}" \
        --max-budget-usd "${MAX_BUDGET}" \
        --verbose \
        --output-format stream-json \
        < "$prompt_file" 2>"${log_file}.stderr") \
        | python3 "${SCRIPT_DIR}/dispatch-progress.py" "$log_file" 30; then
        echo ""
        echo "[$(date '+%H:%M:%S')] Subagent exited successfully."
        return 0
    else
        exit_code=$?
        echo ""
        echo "[$(date '+%H:%M:%S')] Subagent exited with code ${exit_code}."
        if [[ -s "${log_file}.stderr" ]]; then
            echo "[$(date '+%H:%M:%S')] Stderr:"
            tail -10 "${log_file}.stderr" 2>/dev/null || true
        fi
        echo "[$(date '+%H:%M:%S')] Last 20 lines of log:"
        tail -20 "$log_file" 2>/dev/null || true
        return 1
    fi
}

# ──────────────────────────────────────────────
# Verify that hello-digitalis is actually running
# ──────────────────────────────────────────────
verify_completion() {
    echo "[$(date '+%H:%M:%S')] Verifying all samples pass..."

    # Check if emulator is accessible
    if ! adb devices 2>/dev/null | grep -q "emulator\|device"; then
        echo "[$(date '+%H:%M:%S')] ✗ No emulator/device connected"
        return 1
    fi

    # Check boot
    if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; then
        echo "[$(date '+%H:%M:%S')] ✗ Emulator not booted"
        return 1
    fi

    # Step 1: Run test-samples.sh and check for 0 crashes
    local test_output
    test_output=$("${WORK_DIR}/.claude/scripts/test-samples.sh" 2>&1) || true
    echo "$test_output" | tail -5

    if ! echo "$test_output" | grep -q "0 CRASH"; then
        local crashes
        crashes=$(echo "$test_output" | grep -oP '\d+ CRASH' || echo "unknown")
        echo "[$(date '+%H:%M:%S')] ✗ Still have crashes: ${crashes}"
        return 1
    fi
    echo "[$(date '+%H:%M:%S')] ✓ All samples passing (0 CRASH)"

    # Step 2: Run screenshot tests and check for 0 failures
    echo "[$(date '+%H:%M:%S')] Running screenshot tests..."
    local screenshot_output
    screenshot_output=$("${WORK_DIR}/.claude/scripts/test-samples.sh" --screenshots 2>&1) || true
    echo "$screenshot_output" | tail -5

    if echo "$screenshot_output" | grep -q "0 FAIL"; then
        echo "[$(date '+%H:%M:%S')] ✓ All screenshot tests passing (0 FAIL)"
        return 0
    else
        local fails
        fails=$(echo "$screenshot_output" | grep -oP '\d+ FAIL' || echo "unknown")
        echo "[$(date '+%H:%M:%S')] ✗ Screenshot test failures: ${fails}"
        return 1
    fi
}

# ──────────────────────────────────────────────
# Main dispatch loop
# ──────────────────────────────────────────────
main() {
    local user_idea="${*}"

    echo "╔══════════════════════════════════════════════╗"
    echo "║      Digitalis Dispatch System               ║"
    echo "║      ARM64 → x86_64 Binary Translation       ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    echo "Config:"
    echo "  Work dir:     ${WORK_DIR}"
    echo "  Model:        ${MODEL}"
    echo "  Max budget:   \$${MAX_BUDGET}/cycle"
    echo "  Max retries:  ${MAX_RETRIES}/cycle"
    echo "  Retry wait:   ${RETRY_WAIT}s"
    echo "  Max cycles:   ${MAX_CYCLES}"
    echo "  Log dir:      ${LOG_DIR}"
    if [[ -n "$user_idea" ]]; then
        echo "  Initial idea: ${user_idea}"
    fi
    echo ""

    local cycle=0

    while (( cycle < MAX_CYCLES )); do
        cycle=$((cycle + 1))
        maybe_reboot_emulator "$cycle"
        local current
        current=$(find_latest_handoff)
        local next=$((current + 1))
        local input_file="${WORK_DIR}/${HANDOFF_PREFIX}-${current}.md"
        local output_file="${WORK_DIR}/${HANDOFF_PREFIX}-${next}.md"

        if (( current == 0 )); then
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "[$(date '+%H:%M:%S')] Cycle ${cycle}: fresh start → handoff-${next}.md"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        else
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "[$(date '+%H:%M:%S')] Cycle ${cycle}: handoff-${current}.md → handoff-${next}.md"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

            if [[ ! -f "$input_file" ]]; then
                echo "[$(date '+%H:%M:%S')] ERROR: Input file not found: ${input_file}"
                exit 1
            fi
        fi

        # Retry loop for this cycle
        local retries=0
        local success=false

        while (( retries < MAX_RETRIES )); do
            if run_subagent "$current" "$next" "$user_idea"; then
                success=true
                break
            else
                retries=$((retries + 1))
                if (( retries < MAX_RETRIES )); then
                    echo "[$(date '+%H:%M:%S')] Retry ${retries}/${MAX_RETRIES} in ${RETRY_WAIT}s..."
                    sleep "$RETRY_WAIT"
                fi
            fi
        done

        if ! $success; then
            echo "[$(date '+%H:%M:%S')] ERROR: Cycle ${cycle} failed after ${MAX_RETRIES} attempts."
            echo "[$(date '+%H:%M:%S')] Check logs in ${LOG_DIR}/"
            exit 1
        fi

        # Check that the handoff was written
        if [[ ! -f "$output_file" ]]; then
            echo "[$(date '+%H:%M:%S')] WARNING: handoff-${next}.md was not created."
            echo "[$(date '+%H:%M:%S')] Subagent may not have finished writing. Retrying cycle..."
            # Don't increment — retry with the same handoff number
            continue
        fi

        echo "[$(date '+%H:%M:%S')] handoff-${next}.md written ($(wc -l < "$output_file") lines)"

        # Keep user_idea across cycles so build_prompt can keep emitting the
        # "USER GOAL" section. Previously we cleared it after the first
        # cycle, which let subsequent cycles fall back to the hardcoded
        # sample-suite GOAL even when the user's actual question was about
        # something else entirely. The PRIMARY-TASK precedence in
        # build_prompt now keys off the handoff's STATUS line instead.

        # Check for completion. Match ONLY a trailing "## STATUS: COMPLETE"
        # status header (the documented convention), not any mid-body prose
        # occurrence of the phrase — a forward-looking "when done, write
        # STATUS: COMPLETE" instruction once tripped the naive substring grep
        # and falsely ended the loop.
        if grep -qE "^## STATUS: COMPLETE" "$output_file" 2>/dev/null; then
            echo ""
            echo "[$(date '+%H:%M:%S')] ★ Subagent reports STATUS: COMPLETE"
            echo ""

            if verify_completion; then
                if [[ "${DIGITALIS_CONTINUOUS:-0}" == "1" ]]; then
                    echo "[$(date '+%H:%M:%S')] DIGITALIS_CONTINUOUS=1 — gates green, continuing to next cycle."
                    continue
                fi
                echo ""
                echo "╔══════════════════════════════════════════════╗"
                echo "║           DIGITALIS COMPLETE!                ║"
                echo "║   hello-digitalis running on x86_64          ║"
                echo "║   Total cycles: ${cycle}                          ║"
                echo "╚══════════════════════════════════════════════╝"
                exit 0
            else
                echo "[$(date '+%H:%M:%S')] Verification failed. Appending note to handoff."
                cat >> "$output_file" <<EOF

## Dispatch Verification Note
Automated verification at $(date) could not confirm hello-digitalis is running.
The next subagent should investigate and re-verify.
EOF
            fi
        fi

        echo "[$(date '+%H:%M:%S')] Cycle ${cycle} complete. Moving to next cycle."
        echo ""
    done

    echo "[$(date '+%H:%M:%S')] ERROR: Reached max cycles (${MAX_CYCLES}) without completion."
    exit 1
}

# region digitalis
# True iff a qemu-system-x86_64 PROCESS is running. Uses `ps -eo comm` (exact
# process name), NOT `pgrep -f qemu-system-x86_64` — the latter self-matches this
# script's own command line and would report a phantom emulator.
qemu_alive() {
    ps -eo comm 2>/dev/null | grep -q '^qemu-system-x86'
}

# Relaunch the emulator from a dead process. Mirrors the proven interactive
# recipe (background + absolute paths + $HOME log + ANDROID_PRODUCT_OUT for the
# build-tree image), then waits for adb device + boot and re-establishes
# root/remount. Returns non-zero only if the emulator binary is absent.
launch_emulator() {
    if [ ! -x "$EMULATOR_BIN" ]; then
        echo "[$(date '+%H:%M:%S')] ⚠ No emulator binary at ${EMULATOR_BIN}; cannot auto-relaunch."
        return 1
    fi
    echo "[$(date '+%H:%M:%S')] ⟳ qemu process is dead — relaunching emulator..."
    ANDROID_BUILD_TOP="$WORK_DIR" \
    ANDROID_PRODUCT_OUT="$EMULATOR_PRODUCT_OUT" \
    ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${HOME}/Android/Sdk}" \
    DISPLAY="${DISPLAY:-:0}" \
    nohup "$EMULATOR_BIN" -memory 4096 -writable-system -qemu -cpu host \
        > "$EMULATOR_LOG" 2>&1 &
    disown 2>/dev/null || true
    local n=0
    while ! adb devices 2>/dev/null | grep -qE "emulator-[0-9]+[[:space:]]+device" && [ $n -lt 90 ]; do
        sleep 2; n=$((n + 1))
    done
    adb wait-for-device >/dev/null 2>&1 || true
    n=0
    while [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ] && [ $n -lt 180 ]; do
        sleep 2; n=$((n + 1))
    done
    adb root >/dev/null 2>&1 || true
    sleep 2
    adb wait-for-device >/dev/null 2>&1 || true
    adb remount >/dev/null 2>&1 || true
    local m=0
    while ! adb shell pm list packages >/dev/null 2>&1 && [ $m -lt 30 ]; do sleep 2; m=$((m + 1)); done
    if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
        echo "[$(date '+%H:%M:%S')] ⟳ Emulator relaunched and booted (root+remount done)."
    else
        echo "[$(date '+%H:%M:%S')] ⚠ Emulator relaunch did not confirm boot; continuing anyway."
    fi
}

# Reboot the emulator on a fixed cadence or when it looks unhealthy, then wait
# for boot and re-establish root/remount. Preserves the deployed translator
# (the emulator runs -writable-system, so /system survives a reboot within the
# session). No-op when no emulator is connected (host-only runs).
reboot_emulator() {
    # If the qemu process is gone, a guest-level `adb reboot` is impossible —
    # relaunch the process instead.
    if ! qemu_alive; then
        launch_emulator
        return 0
    fi
    echo "[$(date '+%H:%M:%S')] ⟳ Rebooting emulator (clearing exhaustion/ANR state)..."
    if ! adb reboot >/dev/null 2>&1; then
        # adb reboot failed — the process likely just died. Try a full relaunch.
        launch_emulator
        return 0
    fi
    sleep 5
    local n=0
    while [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ] && [ $n -lt 180 ]; do
        sleep 2; n=$((n + 1))
    done
    if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; then
        echo "[$(date '+%H:%M:%S')] ⚠ Emulator did not finish booting after reboot; continuing anyway."
        return 0
    fi
    adb root >/dev/null 2>&1 || true
    sleep 2
    adb wait-for-device >/dev/null 2>&1 || true
    adb remount >/dev/null 2>&1 || true
    # Let the framework settle so the first cycle's device gate isn't racy.
    local m=0
    while ! adb shell pm list packages >/dev/null 2>&1 && [ $m -lt 30 ]; do sleep 2; m=$((m + 1)); done
    echo "[$(date '+%H:%M:%S')] ⟳ Emulator back up (root+remount done)."
}

maybe_reboot_emulator() {
    local cycle=$1
    # No adb device? Distinguish "host-only run (no emulator by design)" from
    # "the emulator process died mid-run." If we can auto-launch and the qemu
    # process is gone, relaunch it; otherwise treat it as a host-only run.
    if ! adb devices 2>/dev/null | grep -qE "emulator|device$"; then
        if [ -x "$EMULATOR_BIN" ] && ! qemu_alive; then
            echo "[$(date '+%H:%M:%S')] No adb device and qemu process is dead — relaunching emulator."
            launch_emulator
        fi
        return 0
    fi

    # Health-triggered reboot: device unreachable for shell, or memory floored.
    local avail
    avail=$(adb shell cat /proc/meminfo 2>/dev/null | awk '/MemAvailable/{print $2}')
    if [ -z "$avail" ]; then
        echo "[$(date '+%H:%M:%S')] Emulator shell unreachable — health reboot."
        reboot_emulator; return 0
    fi
    if [ "$avail" -lt "$REBOOT_MEM_FLOOR_KB" ]; then
        echo "[$(date '+%H:%M:%S')] MemAvailable ${avail}kB < floor ${REBOOT_MEM_FLOOR_KB}kB — health reboot."
        reboot_emulator; return 0
    fi

    # Cadence reboot: every REBOOT_EVERY_CYCLES cycles (not on the first).
    if [ "$REBOOT_EVERY_CYCLES" -gt 0 ] && [ "$cycle" -gt 1 ] \
       && [ $(( (cycle - 1) % REBOOT_EVERY_CYCLES )) -eq 0 ]; then
        echo "[$(date '+%H:%M:%S')] Cadence reboot (cycle ${cycle}, every ${REBOOT_EVERY_CYCLES})."
        reboot_emulator
    fi
}
# endregion

main "$@"
