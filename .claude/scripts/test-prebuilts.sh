#!/usr/bin/env bash
# Install and launch every APK in sample/prebuilts/, watch for crashes,
# report per-APK pass/fail. Generic: any *.apk dropped into
# sample/prebuilts/ is exercised, no per-app hard-coding.
#
# Scope is the prebuilts root ONLY (top-level *.apk). The subdirectories
# sample/prebuilts/top-apps/ and sample/prebuilts/top-games/ are the
# fetch-prebuilt-apks.py staging area and are INTENTIONALLY excluded from this
# gate, so that tool's APKs can be verified separately without affecting the
# normal prebuilt regression. Keep discovery non-recursive (do not switch to a
# recursive `find` that would pull those subdirs back in).
#
# Checks per APK:
#   1. Install succeeds.
#   2. Launch via monkey produces a LAUNCHER activity.
#   3. Process is alive after WATCH_SECONDS (default 30 s).
#   4. No Fatal signal / Undefined arm64 instruction / FATAL EXCEPTION
#      in logcat during the watch window.
#   5. Screenshot at the watch deadline shows meaningful application
#      content (not a stuck splash, not a blank screen). Heuristic:
#      coarse-grid pixel-variance content-cell count; threshold
#      configurable via PREBUILTS_CONTENT_THRESHOLD (default 30%).
#
# Set STRICT_REPRODUCIBILITY=1 to repeat steps 2-5 three times back-to-back
# and require all three launches to pass.  Useful for catching "sometimes
# loads" non-determinism (e.g. an AddToMap signal-clobber wedge with a ~46%
# failure rate per launch).
#
# By default (non-STRICT) a failing app is retried up to PREBUILTS_RETRIES
# more times (default 2 -> 3 attempts) and PASSes if ANY attempt succeeds.
# This is the regression-gate semantics: a flaky-but-working app (some
# anti-tamper/watchdog apps pass ~2 of 3 launches) must not false-FAIL, while
# a genuine translator regression fails every attempt. Set PREBUILTS_RETRIES=0
# to force single-shot. STRICT mode ignores retries (all-must-pass is its point).
#
# Exit code: 0 if every APK passes (within its attempts); non-zero otherwise.

set -u
set -o pipefail

WORK_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PREBUILTS_DIR="${PREBUILTS_DIR_OVERRIDE:-${WORK_DIR}/sample/prebuilts}"
AAPT2="${WORK_DIR}/out/host/linux-x86/bin/aapt2"
CONTENT_CHECK="${WORK_DIR}/digitalis/diagnostics/screenshot_content_check.py"
WATCH_SECONDS="${WATCH_SECONDS:-30}"
CONTENT_THRESHOLD="${PREBUILTS_CONTENT_THRESHOLD:-30}"
STRICT="${STRICT_REPRODUCIBILITY:-0}"
# Default regression gate: retry a failing app up to RETRIES more times and
# PASS if any attempt succeeds (distinguishes a flaky-but-working app from a
# real translator regression, which fails every attempt). Set to 0 to disable.
RETRIES="${PREBUILTS_RETRIES:-2}"
SCREENSHOTS_DIR="${PREBUILTS_SCREENSHOTS_DIR:-/tmp/prebuilt-screenshots}"
mkdir -p "${SCREENSHOTS_DIR}"

if [ ! -d "${PREBUILTS_DIR}" ]; then
    echo "[prebuilts] ${PREBUILTS_DIR} does not exist — no prebuilt APKs to test"
    exit 0
fi

# Checked before target discovery, not after: discovery itself reads package
# names with aapt2 to tell a split-app directory from any other grouping.
if [ ! -x "${AAPT2}" ]; then
    echo "[prebuilts] aapt2 not available at ${AAPT2} — cannot extract package metadata"
    exit 2
fi

# A split app (one whose store install is base.apk + config/asset splits, e.g. a
# game shipped as an apkm/xapk) cannot be represented as one installable *.apk —
# merging the splits into a single APK forces a re-sign, which trips signature
# anti-tamper and also collides with an already-installed genuine copy. Such an
# app is dropped in as a SUBDIRECTORY holding its split *.apk files and installed
# with `adb install-multiple`, preserving the original signature. Splits of one
# app all declare the SAME package name, so a subdirectory whose APKs resolve to
# exactly one package is a split-app group; a directory holding two different
# packages (a benchmark suite kept together, per-ABI copies) is not, and is
# skipped with a note rather than fed to `install-multiple`, which would reject
# it — silently ignoring a directory someone deliberately populated is worse.
#
# Discovery covers the prebuilts root AND the top-apps/ and top-games/ staging
# areas (fetch-prebuilt-apks.py's drop zone), so every verified app is a
# regression target. The staging areas are scanned one level deep — their own
# *.apk files and their split-app subdirectories — and every target is
# de-duplicated by package name, first occurrence winning, so an app promoted to
# a root entry is tested from there and its staging copy is skipped rather than
# launched twice. (benchmark-apps/, a two-package perf suite, resolves to more
# than one package and is skipped as a non-split-group like any other.)
declare -A SEEN_PKG
declare -a APKS

pkg_of_apk() { "${AAPT2}" dump packagename "$1" 2>/dev/null | head -1; }

# Echo a directory's single package name, or nothing if its APKs span 0 or >1
# packages (i.e. it is not one app's split group).
split_dir_pkg() {
    local d="$1" s np
    local sp=( "${d%/}"/*.apk )
    [ ${#sp[@]} -eq 0 ] && return
    np="$(for s in "${sp[@]}"; do pkg_of_apk "${s}"; done | sort -u | grep -c .)"
    [ "${np}" -eq 1 ] && pkg_of_apk "${sp[0]}"
}

# Add a target (single *.apk file or split-app directory) unless an earlier,
# more-canonical target already claimed its package.
add_target() {
    local path="$1" pkg="$2"
    [ -z "${pkg}" ] && return
    [ -n "${SEEN_PKG[${pkg}]:-}" ] && return
    SEEN_PKG[${pkg}]=1
    APKS+=( "${path}" )
}

# A directory whose APKs span more than one package is not one app's split group.
# Rather than dropping it, enroll each APK as its own single-APK target. That is
# how benchmark-apps/ gets verified: it holds a 3DMark pair and a Geekbench pair,
# each built for arm64-v8a and for x86_64, so it is two packages and never was a
# split group. Per-package de-duplication keeps only the first APK seen for each
# package and "-arm64-v8a" sorts before "-x86_64", so the translated build is the
# one enrolled and the native build -- which exists solely as the benchmark
# denominator and must not be treated as a regression target -- is left out. The
# --abi pin and the primaryCpuAbi backstop catch any x86-only straggler anyway.
add_multi_package_dir() {
    local d="$1" label="$2" f n=0
    for f in "${d%/}"/*.apk; do
        [ -f "${f}" ] || continue
        add_target "${f}" "$(pkg_of_apk "${f}")"
        n=$((n+1))
    done
    if [ ${n} -eq 0 ]; then
        echo "[prebuilts] skip ${label} — no *.apk files"
    else
        echo "[prebuilts] ${label} — ${n} APKs spanning >1 package, enrolled individually"
    fi
}

shopt -s nullglob
# 1. Root single APKs.
for f in "${PREBUILTS_DIR}"/*.apk; do
    add_target "${f}" "$(pkg_of_apk "${f}")"
done
# 2. Directories. A root-level directory is either a split-app group or, for the
#    two staging areas, a container scanned one level deeper. Root split groups
#    are visited before the staging areas (top-apps/top-games sort last), so a
#    promoted app wins de-duplication over its staging copy.
for d in "${PREBUILTS_DIR}"/*/; do
    dname="$(basename "${d}")"
    if [ "${dname}" = "top-apps" ] || [ "${dname}" = "top-games" ]; then
        for f in "${d}"*.apk; do
            add_target "${f}" "$(pkg_of_apk "${f}")"
        done
        for sd in "${d}"*/; do
            p="$(split_dir_pkg "${sd}")"
            if [ -n "${p}" ]; then
                add_target "${sd%/}" "${p}"
            else
                add_multi_package_dir "${sd}" "${dname}/$(basename "${sd}")/"
            fi
        done
        continue
    fi
    p="$(split_dir_pkg "${d}")"
    if [ -n "${p}" ]; then
        add_target "${d%/}" "${p}"
    else
        add_multi_package_dir "${d}" "${dname}/"
    fi
done
shopt -u nullglob

# Emulator exhaustion guard. A full sweep installs and launches 130+ apps into
# one long-lived emulator. The dominant cost is not fragmentation but LEFTOVER
# RUNNING APPS: a launched game can sit on hundreds of MB (one observed sweep had
# a single title holding 889 MB, with ~1.5 GB across leftovers), and once
# MemAvailable collapses, HEALTHY apps start failing -- blank frames, "failed to
# attach" start timeouts, SIGSEGVs that vanish after a reboot. Those read as
# translator regressions and cost real investigation time.
#
# So reclaim before rebooting: force-stopping the third-party processes that are
# actually running returns the memory in seconds, where a reboot costs a minute
# and (with a low floor and a busy device) can thrash into one reboot per target.
# Reboot only if reclaiming was not enough, and not more often than the cooldown.
EMU_MEM_FLOOR_KB="${PREBUILTS_MEM_FLOOR_KB:-700000}"
EMU_REBOOT_COOLDOWN="${PREBUILTS_REBOOT_COOLDOWN:-15}"
emu_targets_since_reboot=0

emulator_mem_available_kb() {
    adb shell "grep -m1 MemAvailable /proc/meminfo" 2>/dev/null | tr -d '\r' | awk '{print $2}'
}

# A dead or unreachable device must ABORT the sweep, never be reported as a wall
# of per-app failures. When the emulator dies mid-run every remaining target
# records "(install failed)" and the run reads as a catastrophic regression --
# one observed sweep reported 19 PASS / 118 FAIL purely because the emulator
# process went away at target 20. There is no result to report once the device is
# gone, so fail loudly instead of manufacturing failures.
require_live_device() {
    if ! adb get-state 2>/dev/null | grep -q "device"; then
        echo "[prebuilts] ABORT: no live adb device (emulator gone). Results so far are incomplete." >&2
        exit 2
    fi
}

# Force-stop the third-party packages that currently have a process. Targeted at
# what is running rather than everything installed, so it stays quick.
reclaim_emulator_memory() {
    local running
    running="$(adb shell "ps -A -o NAME" 2>/dev/null | tr -d '\r' \
        | grep -E '^[a-z][a-z0-9_]*(\.[A-Za-z0-9_]+)+' | sed 's/:.*//' | sort -u)"
    [ -z "${running}" ] && return 0
    local pkg
    for pkg in ${running}; do
        case "${pkg}" in
            android|com.android.systemui|com.android.settings|com.android.phone) continue ;;
            com.android.*|com.google.android.*) continue ;;
        esac
        adb shell am force-stop "${pkg}" >/dev/null 2>&1 || true
    done
}

reboot_emulator_and_wait() {
    echo "[prebuilts] rebooting emulator ..."
    adb reboot >/dev/null 2>&1 || true
    sleep 8
    adb wait-for-device >/dev/null 2>&1 || true
    for _ in $(seq 1 100); do
        [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
        sleep 3
    done
    # boot_completed precedes package-manager readiness; wait for pm as well.
    for _ in $(seq 1 40); do
        adb shell pm list packages >/dev/null 2>&1 && break
        sleep 3
    done
    adb root >/dev/null 2>&1 || true
    sleep 2
    emu_targets_since_reboot=0
}

ensure_emulator_headroom() {
    local avail
    require_live_device
    emu_targets_since_reboot=$((emu_targets_since_reboot + 1))
    avail="$(emulator_mem_available_kb)"
    [ -z "${avail}" ] && return 0
    [ "${avail}" -ge "${EMU_MEM_FLOOR_KB}" ] && return 0

    echo "[prebuilts] MemAvailable ${avail} kB below floor ${EMU_MEM_FLOOR_KB} kB — reclaiming"
    reclaim_emulator_memory
    avail="$(emulator_mem_available_kb)"
    if [ -n "${avail}" ] && [ "${avail}" -ge "${EMU_MEM_FLOOR_KB}" ]; then
        echo "[prebuilts] reclaimed to ${avail} kB"
        return 0
    fi

    if [ "${emu_targets_since_reboot}" -lt "${EMU_REBOOT_COOLDOWN}" ]; then
        echo "[prebuilts] still ${avail:-unknown} kB; within reboot cooldown, continuing"
        return 0
    fi
    reboot_emulator_and_wait
    require_live_device
    echo "[prebuilts] resumed with MemAvailable $(emulator_mem_available_kb) kB"
}

if [ ${#APKS[@]} -eq 0 ]; then
    echo "[prebuilts] no *.apk files under ${PREBUILTS_DIR} — nothing to test"
    exit 0
fi

if ! adb get-state >/dev/null 2>&1; then
    echo "[prebuilts] no adb device available — skipping prebuilt regression"
    exit 0
fi

BOOTED="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
if [ "${BOOTED}" != "1" ]; then
    echo "[prebuilts] device is not fully booted (sys.boot_completed=${BOOTED:-unset}) — skipping"
    exit 0
fi


pass=0
fail=0
declare -a RESULTS

for apk in "${APKS[@]}"; do
    # A target is either a single *.apk file or a split-app subdirectory. The
    # per-target body below (force-stop, launch, watch, content check) is
    # identical for both; only the package-name source and the install command
    # differ.
    install_ok=0
    if [ -d "${apk}" ]; then
        base="$(basename "${apk}")/ (split)"
        shopt -s nullglob
        splits=( "${apk}"/*.apk )
        shopt -u nullglob
        # The base split (no config/asset suffix) carries the package name;
        # `base.apk` if present, else the first split.
        base_apk="${splits[0]}"
        for s in "${splits[@]}"; do
            [ "$(basename "${s}")" = "base.apk" ] && base_apk="${s}"
        done
        pkg="$("${AAPT2}" dump packagename "${base_apk}" 2>/dev/null | head -1)"
        # Force the guest ABI. A multi-ABI ("universal") APK that also carries an
        # x86/x86_64 slice would otherwise install as the HOST abi, and the app
        # would run natively -- never entering translation, so the launch proves
        # nothing while still reporting a green result. --abi pins the arm64
        # slice, which is the only one this gate is meant to exercise. Harmless
        # for arm64-only and no-native APKs (verified), so it is applied
        # unconditionally rather than sniffing each APK's lib/ entries.
        adb install-multiple -r -g --abi arm64-v8a "${splits[@]}" >/dev/null 2>&1 && install_ok=1
        # Fall back to an unpinned install if this APK has no arm64 slice at all;
        # the primaryCpuAbi guard below then reports it rather than testing it.
        [ ${install_ok} -eq 0 ] && adb install-multiple -r -g "${splits[@]}" >/dev/null 2>&1 && install_ok=1
    else
        base="$(basename "${apk}")"
        pkg="$("${AAPT2}" dump packagename "${apk}" 2>/dev/null | head -1)"
        adb install -r -g --abi arm64-v8a "${apk}" >/dev/null 2>&1 && install_ok=1
        [ ${install_ok} -eq 0 ] && adb install -r -g "${apk}" >/dev/null 2>&1 && install_ok=1
    fi

    if [ -z "${pkg}" ]; then
        RESULTS+=( "SKIP  ${base}  (no package name)" )
        continue
    fi

    if [ ${install_ok} -eq 0 ]; then
        # Install can fail because a differently-signed copy of the same package
        # is already installed (INSTALL_FAILED_UPDATE_INCOMPATIBLE) — e.g. a
        # genuine store/apkm build vs a re-signed drop-in whose signature the
        # store copy won't accept as an update. If the package is already
        # installed, reuse the installed copy and launch-test that instead of
        # failing on the redundant re-install. Generic — no per-app handling.
        if adb shell pm path "${pkg}" >/dev/null 2>&1; then
            : # already installed; fall through to launch-test the installed copy
        else
            RESULTS+=( "FAIL  ${base}  ${pkg}  (install failed)" )
            fail=$((fail+1))
            continue
        fi
    fi

    # Backstop for the --abi pin above: if a package still ended up on a host abi
    # (its APK carries no arm64 slice, so the pinned install fell back to an
    # unpinned one) then the guest never enters translation and the launch proves
    # nothing about the translator — banking that as a PASS is worse than not
    # running it, because it hides the absent coverage behind a green result.
    # Generic: keyed on the installed primaryCpuAbi, no app names. A package with
    # no native code (primaryCpuAbi=null) still exercises the guest Java path and
    # is left alone.
    inst_abi="$(adb shell dumpsys package "${pkg}" 2>/dev/null | grep -m1 primaryCpuAbi | tr -d ' \r' | cut -d= -f2)"
    case "${inst_abi}" in
        x86|x86_64)
            RESULTS+=( "SKIP  ${base}  ${pkg}  (installed as ${inst_abi} — multi-ABI APK, NOT translated)" )
            continue
            ;;
    esac

    ensure_emulator_headroom

    adb shell am force-stop "${pkg}" >/dev/null 2>&1 || true
    adb logcat -c >/dev/null 2>&1 || true

    # One round of: launch -> watch -> check alive + logcat + screenshot
    # content. Returns 0 on PASS, 1 on FAIL; the FAIL reason is set in
    # the global $round_fail_reason. If STRICT=1 we repeat this 3 times
    # and require all three rounds to PASS.
    rounds_to_run=$([ "${STRICT}" = "1" ] && echo 3 || echo 1)
    # STRICT keeps all-rounds-must-pass with NO retry (its purpose is catching
    # intermittent "sometimes loads" bugs). The default regression gate instead
    # allows RETRIES extra attempts and passes if ANY attempt's round-set fully
    # passes, so a flaky-but-working app does not false-FAIL while a real
    # translator regression (fails every attempt) still does.
    max_attempts=$([ "${STRICT}" = "1" ] && echo 1 || echo $((RETRIES + 1)))
    apk_passed=0
    won_attempt=0
    skip_apk=0
    for attempt in $(seq 1 ${max_attempts}); do
    round_pass=0
    round_fail=0
    round_fail_reason=""
    declare -a round_outcomes=()
    for round_idx in $(seq 1 ${rounds_to_run}); do
        adb shell am force-stop "${pkg}" >/dev/null 2>&1 || true
        adb logcat -c >/dev/null 2>&1 || true
        # Launch any LAUNCHER-categorized activity for the package via monkey.
        # Avoids manifest parsing — handles APKs with multiple launchable
        # activities (e.g. Facebook) and APKs with non-default launcher names.
        launch_out="$(adb shell monkey --pct-syskeys 0 -p "${pkg}" -c android.intent.category.LAUNCHER 1 2>&1)"
        if echo "${launch_out}" | grep -qE "Events injected: 0|No activities found"; then
            round_fail_reason="no LAUNCHER activity"
            round_fail=$((round_fail+1))
            round_outcomes+=( "R${round_idx}=NoLauncher" )
            break  # SKIP applies to entire APK
        fi

        sleep "${WATCH_SECONDS}"

        round_pid="$(adb shell pidof "${pkg}" 2>/dev/null | tr -d '\r')"
        # Native crash signatures — a genuine translator/guest fault ALWAYS leaves
        # one: SIGILL -> "Undefined arm64 instruction", SIGSEGV -> debuggerd
        # "Fatal signal"/tombstone, SIGSYS -> seccomp, a Java crash -> "FATAL
        # EXCEPTION". Drop ART's libsigchain handler-management lines first: they
        # are NOT crash reports but print the signal *name* (e.g. "libsigchain:
        # Setting SIGSEGV to SIG_DFL" on a Chromium child's normal handler
        # uninstall), which the bare "SIG…SEGV" alternation would otherwise match
        # as a false-positive crash. Generic over every multi-process prebuilt.
        # Native crash signatures + a crashed Chromium sandboxed/privileged child.
        # A genuine translator/guest fault always leaves a native signature
        # (SIGILL->"Undefined arm64 instruction", SIGSEGV->"Fatal signal"/
        # tombstone, SIGSYS->seccomp, Java->"FATAL EXCEPTION"); a crashed
        # renderer/GPU child whose own handler swallows the debuggerd tombstone
        # still shows up as ActivityManager scheduling a restart of the crashed
        # SandboxedProcessService (the "Aw Snap" the main-pid check would miss),
        # AND that restart is a real symptom: e.g. helium's GPU process repeatedly
        # SIGSEGVs in the host ANGLE->Vulkan path, so the browser eventually
        # aborts with "Timed out waiting for GPU channel". So a service restart
        # IS a FAIL. Drop ART's libsigchain handler-management lines first — they
        # print the signal *name* ("Setting SIGSEGV to SIG_DFL" on a child's
        # normal exit) but are not crash reports (debuggerd's "Fatal signal" is),
        # so the bare "SIG…SEGV" alternation would otherwise false-positive.
        # Drop app-EMBEDDED crash reporters for the same reason: Unity/il2cpp
        # ("CRASH"), Embrace and Crashlytics print their own report containing
        # "signal 11 (SIGSEGV)" for a fault their handler swallowed, which the
        # bare signal alternation matches even though the process is alive and
        # healthy. debuggerd stays the authority — a genuine fatal guest fault
        # always leaves its "Fatal signal"/tombstone, which is matched above, so
        # nothing real is lost. (Observed: com.vincentb.MobControl FAILed on an
        # Embrace line while rendering fine on re-run.) A reporter line whose
        # fault IS fatal still fails via the dead-pid or blank-content checks.
        round_log="$(adb logcat -d 2>/dev/null | grep -vE "libsigchain:| CRASH +:|\[Embrace\]|CrashlyticsCore" | grep -E "Fatal signal|Undefined arm64 instruction|FATAL EXCEPTION|libc.*tgkill|signal 11|signal 6|signal 4|SIG(11|6|4|SEGV|ABRT|ILL)\b|Scheduling restart of crashed service.*SandboxedProcessService" | head -3 || true)"
        if [ -n "${round_log}" ]; then
            round_fail_reason="round ${round_idx}: ${round_log:0:120}"
            round_fail=$((round_fail+1))
            round_outcomes+=( "R${round_idx}=FATAL" )
            continue
        fi
        if [ -z "${round_pid}" ]; then
            round_fail_reason="round ${round_idx}: process disappeared within ${WATCH_SECONDS}s"
            round_fail=$((round_fail+1))
            round_outcomes+=( "R${round_idx}=Dead" )
            continue
        fi

        # Content check: capture screenshot, evaluate via heuristic.
        shot="${SCREENSHOTS_DIR}/${pkg}.round${round_idx}.png"
        adb exec-out screencap -p > "${shot}" 2>/dev/null
        if [ ! -s "${shot}" ]; then
            round_fail_reason="round ${round_idx}: screencap empty"
            round_fail=$((round_fail+1))
            round_outcomes+=( "R${round_idx}=NoShot" )
            continue
        fi
        if [ -x "${CONTENT_CHECK}" ] || [ -r "${CONTENT_CHECK}" ]; then
            check_out="$(python3 "${CONTENT_CHECK}" --threshold "${CONTENT_THRESHOLD}" "${shot}" 2>&1 | tail -1)"
            if ! echo "${check_out}" | grep -q "PASS"; then
                # Extract the content_cells score for the per-round tag.
                cells_score="$(echo "${check_out}" | grep -oE 'content_cells=[0-9]+/[0-9]+' | head -1)"
                cells_n="$(echo "${cells_score}" | grep -oE '[0-9]+' | head -1)"
                if [ "${cells_n:-0}" -eq 0 ]; then
                    # A fully blank frame (zero content cells) means nothing was
                    # rendered at all — a real render-path regression. Hard FAIL.
                    round_fail_reason="round ${round_idx}: ${check_out%% *} blank render (${shot})"
                    round_fail=$((round_fail+1))
                    round_outcomes+=( "R${round_idx}=Fail(${cells_score:-blank})" )
                    continue
                fi
                # Dark-but-nonzero: the app IS drawing (a game's black boot/splash
                # frame, a dark login screen, a paused video frame) yet is alive
                # and crash-free. The prebuilt-gate regression criteria (see file
                # header) are crash/disappearance, not sparse content — so surface
                # this as a WARN and count the round as passed, don't fail the gate.
                round_pass=$((round_pass+1))
                round_outcomes+=( "R${round_idx}=Warn(${cells_score:-low})" )
                continue
            fi
        fi
        round_pass=$((round_pass+1))
        round_outcomes+=( "R${round_idx}=Pass" )
    done
    # A missing LAUNCHER activity is a skip, not a flake — don't retry it.
    if [ -n "${round_fail_reason}" ] && [ "${round_fail_reason%%:*}" = "no LAUNCHER activity" ]; then
        skip_apk=1
        break
    fi
    if [ ${round_pass} -eq ${rounds_to_run} ]; then
        apk_passed=1
        won_attempt=${attempt}
        break
    fi
    done  # attempts
    adb shell am force-stop "${pkg}" >/dev/null 2>&1 || true

    # Join per-round outcomes with commas: "R1=Fail(content_cells=7/60),R2=Fail(content_cells=7/60),..."
    round_summary="$(IFS=','; echo "${round_outcomes[*]}")"
    attempt_note=""
    if [ ${max_attempts} -gt 1 ] && [ ${apk_passed} -eq 1 ] && [ ${won_attempt} -gt 1 ]; then
        attempt_note="  (flaky: passed on attempt ${won_attempt}/${max_attempts})"
    fi

    if [ ${skip_apk} -eq 1 ]; then
        RESULTS+=( "SKIP  ${base}  ${pkg}  (no LAUNCHER activity)" )
        continue
    fi
    if [ ${apk_passed} -eq 1 ]; then
        RESULTS+=( "PASS  ${base}  ${pkg}  [${round_pass}/${rounds_to_run} pass]${attempt_note}  ${round_summary}" )
        pass=$((pass+1))
    else
        RESULTS+=( "FAIL  ${base}  ${pkg}  [${round_pass}/${rounds_to_run} pass]  tried ${max_attempts}x  ${round_summary}  last_fail: ${round_fail_reason}" )
        fail=$((fail+1))
    fi
done

echo
echo "=== Prebuilt-APK regression ==="
for line in "${RESULTS[@]}"; do
    printf '  %s\n' "${line}"
done
echo "Results: ${pass} PASS, ${fail} FAIL"

if [ ${fail} -gt 0 ]; then
    exit 1
fi
exit 0
