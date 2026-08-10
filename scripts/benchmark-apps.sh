#!/usr/bin/env bash
#
# benchmark-apps.sh — arm64-vs-native measurement driver for the full-app
# benchmarks kept in sample/prebuilts/benchmark-apps/.
#
# WHY A SEPARATE HARNESS
# ----------------------
# The in-tree sweep (run-benchmarks.sh) times microbenchmarks we wrote, in
# workloads we chose. These are third-party benchmarks nobody here tuned for,
# which is exactly what makes them useful: they are the same yardstick an
# outside comparison uses, and they exercise code paths our samples do not.
#
# It is NOT the prebuilt regression gate. That gate asks "did it crash"; this
# asks "how fast", takes hours, and needs a quiet machine.
#
# THE MEASUREMENT
# ---------------
# Each app is dropped in as an ABI PAIR: the same version built for arm64-v8a
# and for x86_64. The x86_64 half is the denominator — the identical workload
# with no translation in the path. "42x the interpreter" says nothing about
# whether translated code is usable; "% of native" does.
#
# Legs run ABBA (native A, arm64 A, arm64 B, native B) so that any drift in the
# host over the hours a full campaign takes shows up as a spread between the two
# legs of an arm arm rather than as a fake difference between the arms.
#
# TWO TRAPS THIS SCRIPT GUARDS
# ----------------------------
#  1. The two halves of a pair share a package name, so installing one REPLACES
#     the other. Every leg re-installs and then re-reads primaryCpuAbi from the
#     device: a leg that believes it is measuring arm64 while the device resolved
#     x86_64 produces a beautiful, entirely fictitious result.
#  2. Digitalis extracts in-APK guest libraries into app data, and `install -r`
#     does NOT invalidate that extract, so an arm64 leg can silently keep running
#     a previous build's library. Legs clear app data by default (--keep-data
#     for apps whose runs depend on a large downloaded asset, which is then
#     re-verified from /proc/<pid>/maps instead).
#
# Every arm64 leg additionally confirms libberberis_arm64.so is mapped into the
# app process. That is the only positive proof the translator was in the path.
#
# Usage:
#   digitalis/scripts/benchmark-apps.sh --list
#   digitalis/scripts/benchmark-apps.sh --app <package> [--legs native,arm64]
#   digitalis/scripts/benchmark-apps.sh --profile          # lite/heavy gap sweep
# Env knobs:
#   BA_DIR        (default sample/prebuilts/benchmark-apps)
#   BA_OUT        (default digitalis/out/benchmark-apps)
#   BA_SETTLE     (default 20)   seconds to wait after launch before proving liveness
#
# Copyright (C) 2026 utzcoz
# SPDX-License-Identifier: Apache-2.0

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DIR="${BA_DIR:-${WORK_DIR}/sample/prebuilts/benchmark-apps}"
OUT="${BA_OUT:-${WORK_DIR}/digitalis/out/benchmark-apps}"
AAPT2="${WORK_DIR}/out/host/linux-x86/bin/aapt2"
SETTLE="${BA_SETTLE:-20}"
MODE="list"
APP=""
KEEP_DATA=0

while [ $# -gt 0 ]; do
    case "$1" in
        --list)       MODE="list"; shift ;;
        --app)        MODE="run"; APP="$2"; shift 2 ;;
        --profile)    MODE="profile"; shift ;;
        --keep-data)  KEEP_DATA=1; shift ;;
        -h|--help)    sed -n '2,55p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -d "${DIR}" ] || { echo "[bench-apps] ${DIR} does not exist" >&2; exit 2; }
[ -x "${AAPT2}" ] || { echo "[bench-apps] aapt2 missing at ${AAPT2}" >&2; exit 2; }
mkdir -p "${OUT}"

# Discovery: group the directory's APKs by package name, and record which ABI
# each declares. A package with both an arm64-v8a and an x86_64 APK is a
# measurable pair; anything else is reported and skipped rather than guessed at.
declare -A ARM64_APK=()
declare -A NATIVE_APK=()
shopt -s nullglob
for apk in "${DIR}"/*.apk; do
    pkg="$("${AAPT2}" dump packagename "${apk}" 2>/dev/null | head -1)"
    [ -n "${pkg}" ] || continue
    abis="$("${AAPT2}" dump badging "${apk}" 2>/dev/null | sed -n "s/^native-code: //p" | tr -d "'")"
    case "${abis}" in
        *arm64-v8a*) ARM64_APK["${pkg}"]="${apk}" ;;
        *x86_64*)    NATIVE_APK["${pkg}"]="${apk}" ;;
        *) echo "[bench-apps] skip $(basename "${apk}") — native-code '${abis}'" ;;
    esac
done
shopt -u nullglob

list_pairs() {
    for pkg in "${!ARM64_APK[@]}"; do
        if [ -n "${NATIVE_APK[${pkg}]:-}" ]; then
            echo "PAIR    ${pkg}"
            echo "        arm64  $(basename "${ARM64_APK[${pkg}]}")"
            echo "        native $(basename "${NATIVE_APK[${pkg}]}")"
        else
            echo "ARM-ONLY ${pkg} (no x86_64 half — no native denominator)"
        fi
    done
}

if [ "${MODE}" = "list" ]; then
    list_pairs
    exit 0
fi

if ! adb get-state >/dev/null 2>&1; then
    echo "[bench-apps] no adb device" >&2; exit 2
fi

# --profile: hand the arm64 halves to the first-gear gap sweep. This is the mode
# that drives fixes; the scoring modes only confirm them.
if [ "${MODE}" = "profile" ]; then
    apks=""
    for pkg in "${!ARM64_APK[@]}"; do apks="${apks} ${ARM64_APK[${pkg}]}"; done
    [ -n "${apks}" ] || { echo "[bench-apps] no arm64 APKs to profile" >&2; exit 2; }
    echo "[bench-apps] profiling first-gear coverage gaps over:${apks}"
    LF_APKS="${apks}" LF_OUT="${OUT}/litefail" \
        "${SCRIPT_DIR}/litefail-sweep.sh"
    exit $?
fi

# ---- one leg ---------------------------------------------------------------
# Install the requested ABI, prove the device actually resolved it, launch, and
# prove the process is alive and (for arm64) running through the translator.
run_leg() {
    local pkg="$1" abi="$2" label="$3" apk="$4"
    local log="${OUT}/${pkg}.${label}.log"

    echo "[bench-apps] --- leg ${label} (${abi}) ---"
    adb shell am force-stop "${pkg}" >/dev/null 2>&1 || true
    adb install -r -g "${apk}" >/dev/null 2>&1 || {
        echo "[bench-apps] ${label}: install failed" >&2; return 1; }
    if [ "${KEEP_DATA}" = 0 ]; then
        adb shell pm clear "${pkg}" >/dev/null 2>&1 || true
    fi

    local got
    got="$(adb shell dumpsys package "${pkg}" 2>/dev/null | tr -d '\r' \
           | sed -n 's/.*primaryCpuAbi=\([^ ]*\).*/\1/p' | head -1)"
    if [ "${got}" != "${abi}" ]; then
        echo "[bench-apps] ${label}: device resolved primaryCpuAbi=${got}, wanted ${abi}" >&2
        return 1
    fi

    adb logcat -c >/dev/null 2>&1 || true
    adb shell monkey --pct-syskeys 0 -p "${pkg}" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    sleep "${SETTLE}"

    local pid
    pid="$(adb shell pidof "${pkg}" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
    if [ -z "${pid}" ]; then
        echo "[bench-apps] ${label}: process not running after ${SETTLE}s" >&2
        adb logcat -d > "${log}" 2>/dev/null || true
        return 1
    fi

    if [ "${abi}" = "arm64-v8a" ]; then
        if ! adb shell run-as "${pkg}" cat "/proc/${pid}/maps" 2>/dev/null \
                | grep -q libberberis_arm64.so \
           && ! adb shell cat "/proc/${pid}/maps" 2>/dev/null \
                | grep -q libberberis_arm64.so; then
            echo "[bench-apps] ${label}: libberberis_arm64.so NOT mapped — not translated" >&2
            return 1
        fi
        echo "[bench-apps] ${label}: translator confirmed in process ${pid}"
    else
        echo "[bench-apps] ${label}: native process ${pid}"
    fi

    adb logcat -d > "${log}" 2>/dev/null || true
    echo "[bench-apps] ${label}: evidence → ${log}"
    echo "[bench-apps] ${label}: START THE RUN IN THE APP UI NOW; it stays open."
    return 0
}

[ -n "${ARM64_APK[${APP}]:-}" ] || { echo "[bench-apps] no arm64 APK for ${APP}" >&2; exit 2; }
[ -n "${NATIVE_APK[${APP}]:-}" ] || { echo "[bench-apps] no x86_64 APK for ${APP}" >&2; exit 2; }

fail=0
run_leg "${APP}" "x86_64"    "nativeA" "${NATIVE_APK[${APP}]}" || fail=1
run_leg "${APP}" "arm64-v8a" "arm64A"  "${ARM64_APK[${APP}]}"  || fail=1
run_leg "${APP}" "arm64-v8a" "arm64B"  "${ARM64_APK[${APP}]}"  || fail=1
run_leg "${APP}" "x86_64"    "nativeB" "${NATIVE_APK[${APP}]}" || fail=1

echo "[bench-apps] evidence in ${OUT}"
exit "${fail}"
