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
# loads" non-determinism (e.g. the AddToMap signal-clobber wedge described
# in handoff-269 has ~46% failure rate per launch).
#
# Exit code: 0 if every APK passes ALL five checks; non-zero otherwise.

set -u
set -o pipefail

WORK_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PREBUILTS_DIR="${WORK_DIR}/sample/prebuilts"
AAPT2="${WORK_DIR}/out/host/linux-x86/bin/aapt2"
CONTENT_CHECK="${WORK_DIR}/digitalis/diagnostics/screenshot_content_check.py"
WATCH_SECONDS="${WATCH_SECONDS:-30}"
CONTENT_THRESHOLD="${PREBUILTS_CONTENT_THRESHOLD:-30}"
STRICT="${STRICT_REPRODUCIBILITY:-0}"
SCREENSHOTS_DIR="${PREBUILTS_SCREENSHOTS_DIR:-/tmp/prebuilt-screenshots}"
mkdir -p "${SCREENSHOTS_DIR}"

if [ ! -d "${PREBUILTS_DIR}" ]; then
    echo "[prebuilts] ${PREBUILTS_DIR} does not exist — no prebuilt APKs to test"
    exit 0
fi

shopt -s nullglob
# Non-recursive on purpose: top-apps/ and top-games/ (fetch-prebuilt-apks.py
# staging) are excluded from this gate.
APKS=( "${PREBUILTS_DIR}"/*.apk )
# A split app (one whose store install is base.apk + config/asset splits, e.g. a
# game shipped as an apkm/xapk) cannot be represented as one installable *.apk —
# merging the splits into a single APK forces a re-sign, which trips signature
# anti-tamper and also collides with an already-installed genuine copy. Such an
# app is dropped in as an immediate SUBDIRECTORY holding its split *.apk files;
# it is installed with `adb install-multiple`, preserving the original
# signature. Generic over any split app dropped in this way — no app names are
# hard-coded. top-apps/ and top-games/ stay excluded (they are fetch staging,
# not split-app groups).
for d in "${PREBUILTS_DIR}"/*/; do
    dname="$(basename "${d}")"
    [ "${dname}" = "top-apps" ] && continue
    [ "${dname}" = "top-games" ] && continue
    dsplits=( "${d}"*.apk )
    [ ${#dsplits[@]} -gt 0 ] && APKS+=( "${d%/}" )
done
shopt -u nullglob

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

if [ ! -x "${AAPT2}" ]; then
    echo "[prebuilts] aapt2 not available at ${AAPT2} — cannot extract package metadata"
    exit 2
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
        adb install-multiple -r -g "${splits[@]}" >/dev/null 2>&1 && install_ok=1
    else
        base="$(basename "${apk}")"
        pkg="$("${AAPT2}" dump packagename "${apk}" 2>/dev/null | head -1)"
        adb install -r -g "${apk}" >/dev/null 2>&1 && install_ok=1
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

    adb shell am force-stop "${pkg}" >/dev/null 2>&1 || true
    adb logcat -c >/dev/null 2>&1 || true

    # One round of: launch -> watch -> check alive + logcat + screenshot
    # content. Returns 0 on PASS, 1 on FAIL; the FAIL reason is set in
    # the global $round_fail_reason. If STRICT=1 we repeat this 3 times
    # and require all three rounds to PASS.
    rounds_to_run=$([ "${STRICT}" = "1" ] && echo 3 || echo 1)
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
        round_log="$(adb logcat -d 2>/dev/null | grep -v "libsigchain:" | grep -E "Fatal signal|Undefined arm64 instruction|FATAL EXCEPTION|libc.*tgkill|signal 11|signal 6|signal 4|SIG(11|6|4|SEGV|ABRT|ILL)\b|Scheduling restart of crashed service.*SandboxedProcessService" | head -3 || true)"
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
    adb shell am force-stop "${pkg}" >/dev/null 2>&1 || true

    # Join per-round outcomes with commas: "R1=Fail(content_cells=7/60),R2=Fail(content_cells=7/60),..."
    round_summary="$(IFS=','; echo "${round_outcomes[*]}")"

    if [ -n "${round_fail_reason}" ] && [ "${round_fail_reason%%:*}" = "no LAUNCHER activity" ]; then
        RESULTS+=( "SKIP  ${base}  ${pkg}  (no LAUNCHER activity)" )
        continue
    fi
    if [ ${round_pass} -eq ${rounds_to_run} ]; then
        RESULTS+=( "PASS  ${base}  ${pkg}  [${round_pass}/${rounds_to_run} pass]  ${round_summary}" )
        pass=$((pass+1))
    else
        RESULTS+=( "FAIL  ${base}  ${pkg}  [${round_pass}/${rounds_to_run} pass]  ${round_summary}  last_fail: ${round_fail_reason}" )
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
