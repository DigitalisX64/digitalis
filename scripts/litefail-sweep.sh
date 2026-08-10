#!/usr/bin/env bash
#
# litefail-sweep.sh — first-gear (lite translator) coverage-gap measurement.
# The companion to heavybail-sweep.sh, for the tier that actually gates.
#
# WHY THIS EXISTS
# ---------------
# A heavy-tier bail costs speed. A LITE-tier failure costs an order of
# magnitude, because lite is the gatekeeper for everything downstream:
#
#   * First gear is always lite. The heavy optimizer is only attempted for a
#     region that is already hot, and hotness is counted by a profiling counter
#     that lite installs INTO the region it translated.
#   * A region lite cannot translate installs `kInterpreted`, which carries no
#     counter — so it can never gear up. Heavy's implementation of that
#     instruction, if it has one, is unreachable.
#   * A region lite translates only partially is clamped at the failure point;
#     the offending instruction becomes its own single-instruction interpreted
#     entry, and the hot loop is left as fragments too small for heavy to accept.
#
# So one unlowerable instruction in a hot loop costs a region exit, a
# translation-cache lookup and a guest-register flush to ThreadState twice per
# occurrence, plus the interpreter round-trip, plus the permanent loss of the
# second gear for that loop. Externally-measured cliffs of ~1% of native have
# this exact shape. This sweep is how those instructions get named instead of
# guessed at.
#
# THE TEMPORARY DIAGNOSTIC (apply BEFORE running, revert AFTER — NEVER commit)
# ---------------------------------------------------------------------------
# Lite does not log its failures in production. Apply this at the failure point
# in  frameworks/libs/binary_translation/runtime/arm64/translator_x86_64.cc,
# inside TryLiteTranslateAndInstallRegion, immediately after
#   auto [success, stop_pc] = TryLiteTranslateRegion(pc, &machine_code, params);
#
#   if (!success) {
#     // TEMP LITE_FAIL histogram diagnostic — apply/revert per sweep, NEVER commit.
#     ALOGE("LITE_FAIL insn=0x%08x", *ToHostAddr<const uint32_t>(stop_pc));
#   }
#
# stop_pc is the instruction lite stopped on in BOTH cases: the partial-region
# case (clamped at the failure point) and the size==0 case (stop_pc == pc, could
# not translate even the first instruction). It needs <log/log.h>.
#
# Then:
#   1. m libberberis_arm64
#   2. deploy to /system/lib64/libberberis_arm64.so; adb shell stop && start
#   3. run this script
#   4. `git checkout` the diagnostic and rebuild for the clean tree.
#
# WHAT THIS DRIVER DOES
# ---------------------
# Discovers the top-level prebuilt APKs (same convention as test-prebuilts.sh:
# non-recursive, top-apps/ and top-games/ excluded), SKIPS any APK that is not
# arm64-v8a, then for each app: clears logcat, launches it, dwells, and harvests
# every `LITE_FAIL insn=0x........` line. The word list is handed to
# decode-bail-histogram.py, which ranks by mnemonic.
#
# Skipping non-arm64 APKs is not tidiness. A benchmark app dropped in as an
# ABI pair installs its x86_64 half as primaryCpuAbi=x86_64, which runs natively
# and never enters the translator — it would contribute zero events and, worse,
# would REPLACE its arm64 twin on the device, since the two halves share a
# package name.
#
# It is a *diagnostic* tool, not a gate — it never fails the build.
#
# Usage:
#   digitalis/scripts/litefail-sweep.sh [OUT_DIR]
# Env knobs:
#   LF_WATCH_SECONDS  (default 25)  dwell per app before harvesting logcat
#   LF_OUT            (default digitalis/out/litefail)  output dir
#   LF_DECODE         (default 1)   1 = run decode-bail-histogram.py at the end
#   LF_APKS           (default: discovered) explicit space-separated APK list
#
# Copyright (C) 2026 utzcoz
# SPDX-License-Identifier: Apache-2.0

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PREBUILTS_DIR="${WORK_DIR}/sample/prebuilts"
AAPT2="${WORK_DIR}/out/host/linux-x86/bin/aapt2"
WATCH="${LF_WATCH_SECONDS:-25}"
OUT="${1:-${LF_OUT:-${WORK_DIR}/digitalis/out/litefail}}"
DECODE="${LF_DECODE:-1}"
WORDS="${OUT}/litefail_words.txt"
PERAPP="${OUT}/per_app.txt"

mkdir -p "${OUT}"
: > "${WORDS}"
: > "${PERAPP}"

if ! adb get-state >/dev/null 2>&1; then
    echo "[litefail] no adb device — nothing to do"; exit 0
fi
if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; then
    echo "[litefail] device not booted — nothing to do"; exit 0
fi
if [ ! -x "${AAPT2}" ]; then
    echo "[litefail] aapt2 missing at ${AAPT2} — build a host image first"; exit 2
fi

echo "[litefail] NOTE: requires the TEMP LITE_FAIL diagnostic compiled into"
echo "[litefail]       the loaded libberberis_arm64.so (see this script's header)."

shopt -s nullglob
if [ -n "${LF_APKS:-}" ]; then
    # shellcheck disable=SC2206
    APKS=( ${LF_APKS} )
else
    APKS=( "${PREBUILTS_DIR}"/*.apk )   # non-recursive on purpose
fi
shopt -u nullglob
if [ ${#APKS[@]} -eq 0 ]; then
    echo "[litefail] no *.apk under ${PREBUILTS_DIR}"; exit 0
fi

declare -a PKGS=()
for apk in "${APKS[@]}"; do
    abis="$("${AAPT2}" dump badging "${apk}" 2>/dev/null | sed -n "s/^native-code: //p")"
    case "${abis}" in
        *arm64-v8a*) ;;
        *)
            echo "[litefail] skip $(basename "${apk}") — native-code ${abis:-none}, not arm64"
            continue ;;
    esac
    pkg="$("${AAPT2}" dump packagename "${apk}" 2>/dev/null | head -1)"
    [ -z "${pkg}" ] && continue
    adb install -r -g "${apk}" >/dev/null 2>&1 || true
    PKGS+=( "${pkg}" )
done
if [ ${#PKGS[@]} -eq 0 ]; then
    echo "[litefail] no arm64 APKs to sweep"; exit 0
fi
echo "[litefail] ${#PKGS[@]} packages, ${WATCH}s dwell each → ${WORDS}"

total_events=0
for pkg in "${PKGS[@]}"; do
    adb shell am force-stop "${pkg}" >/dev/null 2>&1 || true
    adb logcat -c >/dev/null 2>&1 || true
    adb shell monkey --pct-syskeys 0 -p "${pkg}" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
    sleep "${WATCH}"
    got="$(adb logcat -d 2>/dev/null | tr -d '\r' | \
           grep -oE 'LITE_FAIL insn=0x[0-9a-fA-F]{8}' | \
           grep -oE '0x[0-9a-fA-F]{8}')"
    n=0
    if [ -n "${got}" ]; then
        printf '%s\n' "${got}" >> "${WORDS}"
        n="$(printf '%s\n' "${got}" | grep -c .)"
    fi
    total_events=$((total_events + n))
    printf '%-44s %6d\n' "${pkg}" "${n}" | tee -a "${PERAPP}"
    adb shell am force-stop "${pkg}" >/dev/null 2>&1 || true
done

echo "[litefail] harvested ${total_events} lite-failure events → ${WORDS}"
echo "[litefail] per-app counts → ${PERAPP}"

if [ "${DECODE}" = "1" ] && [ "${total_events}" -gt 0 ]; then
    echo "[litefail] decoding histogram..."
    python3 "${SCRIPT_DIR}/decode-bail-histogram.py" "${WORDS}" | tee "${OUT}/histogram.txt"
    echo "[litefail] histogram → ${OUT}/histogram.txt"
elif [ "${total_events}" -eq 0 ]; then
    echo "[litefail] 0 events — is the LITE_FAIL diagnostic compiled in and loaded?"
fi
