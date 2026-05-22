#!/usr/bin/env bash
# Install and launch every APK in sample/prebuilts/, watch for crashes,
# report per-APK pass/fail. Generic: any *.apk dropped into
# sample/prebuilts/ is exercised, no per-app hard-coding.
#
# Exit code: 0 if every APK survives the watch window without a fatal
# signal / Undefined arm64 instruction / FATAL EXCEPTION / process
# disappearance; non-zero otherwise.

set -u
set -o pipefail

WORK_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PREBUILTS_DIR="${WORK_DIR}/sample/prebuilts"
AAPT2="${WORK_DIR}/out/host/linux-x86/bin/aapt2"
WATCH_SECONDS="${WATCH_SECONDS:-18}"

if [ ! -d "${PREBUILTS_DIR}" ]; then
    echo "[prebuilts] ${PREBUILTS_DIR} does not exist — no prebuilt APKs to test"
    exit 0
fi

shopt -s nullglob
APKS=( "${PREBUILTS_DIR}"/*.apk )
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
    base="$(basename "${apk}")"

    pkg="$("${AAPT2}" dump packagename "${apk}" 2>/dev/null | head -1)"
    if [ -z "${pkg}" ]; then
        RESULTS+=( "SKIP  ${base}  (no package name)" )
        continue
    fi

    adb install -r -g "${apk}" >/dev/null 2>&1 || {
        RESULTS+=( "FAIL  ${base}  ${pkg}  (install failed)" )
        fail=$((fail+1))
        continue
    }

    adb shell am force-stop "${pkg}" >/dev/null 2>&1 || true
    adb logcat -c >/dev/null 2>&1 || true

    # Launch any LAUNCHER-categorized activity for the package via monkey.
    # Avoids manifest parsing — handles APKs with multiple launchable
    # activities (e.g. Facebook) and APKs with non-default launcher names.
    launch_out="$(adb shell monkey --pct-syskeys 0 -p "${pkg}" -c android.intent.category.LAUNCHER 1 2>&1)"
    if echo "${launch_out}" | grep -qE "Events injected: 0|No activities found"; then
        RESULTS+=( "SKIP  ${base}  ${pkg}  (no LAUNCHER activity)" )
        continue
    fi

    sleep "${WATCH_SECONDS}"

    pid="$(adb shell pidof "${pkg}" 2>/dev/null | tr -d '\r')"
    log="$(adb logcat -d 2>/dev/null | grep -E "Fatal signal|Undefined arm64 instruction|FATAL EXCEPTION|libc.*tgkill|signal 11|signal 6|signal 4|SIG(11|6|4|SEGV|ABRT|ILL)\b" | head -3 || true)"

    if [ -n "${log}" ]; then
        RESULTS+=( "FAIL  ${base}  ${pkg}  ${log:0:160}" )
        fail=$((fail+1))
    elif [ -z "${pid}" ]; then
        RESULTS+=( "FAIL  ${base}  ${pkg}  (process disappeared within ${WATCH_SECONDS}s)" )
        fail=$((fail+1))
    else
        RESULTS+=( "PASS  ${base}  ${pkg}  (alive, pid=${pid})" )
        pass=$((pass+1))
    fi

    adb shell am force-stop "${pkg}" >/dev/null 2>&1 || true
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
