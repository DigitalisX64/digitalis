#!/usr/bin/env bash
#
# heavybail-sweep.sh — heavy-tier (second-gear) gear-up bail measurement driver.
# Verifies the second gear actually engages on real apps: a silent heavy bail
# costs only speed, so this sweep is how a coverage regression is noticed.
#
# WHY THIS EXISTS
# ---------------
# The heavy optimizer (`heavy_optimizer/arm64/`) is the two-gear "second gear".
# When its frontend cannot translate an instruction it bails (success_ = false),
# the region stops, and the caller falls back to the lite translator. Each such
# bail is a gear-up opportunity lost. Plan3 Tier 2 ("heavy-tier close-the-gap")
# is prioritized by a *measured* histogram of which instructions bail most in
# real apps. This driver + its decoder recreate that measurement so Tier 2
# progress can be re-measured any time (the earlier scratchpad scripts were
# never committed and are gone).
#
# THE TEMPORARY DIAGNOSTIC (apply BEFORE running, revert AFTER — NEVER commit)
# ---------------------------------------------------------------------------
# The heavy frontend does not log its bails in production. To measure them,
# apply this one-line diagnostic at the bail point in
#   frameworks/libs/binary_translation/heavy_optimizer/arm64/heavy_optimize_region.cc
# inside the `if (!frontend.success())` branch, BEFORE the `break;` (at that
# point frontend.GetInsnAddr() still points at the gating instruction):
#
#   if (!frontend.success()) {
#     // TEMP heavy-bail histogram diagnostic — apply/revert per sweep, NEVER commit.
#     ALOGE("HEAVY_BAIL insn=0x%08x", *ToHostAddr<const uint32_t>(frontend.GetInsnAddr()));
#     break;
#   }
#
# ALOGE (LOG_TAG "berberis", via <cutils/log.h>) lands in logcat, so this
# sweep can harvest it across every launched app. Then:
#   1. m libberberis_arm64
#   2. deploy to BOTH /system/lib64/libberberis_arm64.so and
#      /system/lib64/arm64/libberberis_arm64.so; adb shell stop && start
#   3. run this script
#   4. `git checkout` the diagnostic (revert) and rebuild for the clean tree.
#
# WHAT THIS DRIVER DOES
# ---------------------
# Discovers the top-level prebuilt APKs (same convention as test-prebuilts.sh /
# Non-recursive on sample/prebuilts/, top-apps/ & top-games/
# excluded), makes sure each is installed, then for each app: clears logcat,
# launches it, dwells, and harvests every `HEAVY_BAIL insn=0x........` line into
# a raw word list. Finally it hands that list to decode-bail-histogram.py, which
# disassembles each unique word and prints a mnemonic-frequency ranking.
#
# It is a *diagnostic* tool, not a gate — it never fails the build. Point it at
# an already-booted emulator that has the diagnostic libberberis_arm64.so loaded.
#
# Usage:
#   digitalis/scripts/heavybail-sweep.sh [OUT_DIR]
# Env knobs:
#   HB_WATCH_SECONDS  (default 18)  dwell per app before harvesting logcat
#   HB_OUT            (default /tmp/heavybail)  output dir
#   HB_DECODE         (default 1)   1 = run decode-bail-histogram.py at the end
#
# Copyright (C) 2026 utzcoz
# SPDX-License-Identifier: Apache-2.0

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PREBUILTS_DIR="${WORK_DIR}/sample/prebuilts"
AAPT2="${WORK_DIR}/out/host/linux-x86/bin/aapt2"
WATCH="${HB_WATCH_SECONDS:-18}"
OUT="${1:-${HB_OUT:-/tmp/heavybail}}"
DECODE="${HB_DECODE:-1}"
WORDS="${OUT}/bail_words.txt"        # one 0x........ per event (with dups)
PERAPP="${OUT}/per_app.txt"          # per-app event counts

mkdir -p "${OUT}"
: > "${WORDS}"
: > "${PERAPP}"

if ! adb get-state >/dev/null 2>&1; then
    echo "[heavybail] no adb device — nothing to do"; exit 0
fi
if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; then
    echo "[heavybail] device not booted — nothing to do"; exit 0
fi
if [ ! -x "${AAPT2}" ]; then
    echo "[heavybail] aapt2 missing at ${AAPT2} — build a host image first"; exit 2
fi

# Sanity: warn loudly if the loaded lib carries no HEAVY_BAIL diagnostic. We
# can't introspect the binary from here, so just remind the operator.
echo "[heavybail] NOTE: requires the TEMP HEAVY_BAIL diagnostic compiled into"
echo "[heavybail]       the loaded libberberis_arm64.so (see this script's header)."

shopt -s nullglob
APKS=( "${PREBUILTS_DIR}"/*.apk )   # non-recursive on purpose
shopt -u nullglob
if [ ${#APKS[@]} -eq 0 ]; then
    echo "[heavybail] no *.apk under ${PREBUILTS_DIR}"; exit 0
fi

# Resolve package + launchable-activity once; ensure installed.
declare -a PKGS=()
for apk in "${APKS[@]}"; do
    pkg="$("${AAPT2}" dump packagename "${apk}" 2>/dev/null | head -1)"
    [ -z "${pkg}" ] && continue
    adb install -r -g "${apk}" >/dev/null 2>&1 || true
    PKGS+=( "${pkg}" )
done
echo "[heavybail] ${#PKGS[@]} packages, ${WATCH}s dwell each → ${WORDS}"

total_events=0
for pkg in "${PKGS[@]}"; do
    adb shell am force-stop "${pkg}" >/dev/null 2>&1 || true
    adb logcat -c >/dev/null 2>&1 || true
    adb shell monkey --pct-syskeys 0 -p "${pkg}" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
    sleep "${WATCH}"
    # Harvest HEAVY_BAIL lines; extract the 0x........ word.
    got="$(adb logcat -d 2>/dev/null | tr -d '\r' | \
           grep -oE 'HEAVY_BAIL insn=0x[0-9a-fA-F]{8}' | \
           grep -oE '0x[0-9a-fA-F]{8}')"
    n=0
    if [ -n "${got}" ]; then
        printf '%s\n' "${got}" >> "${WORDS}"
        n="$(printf '%s\n' "${got}" | grep -c .)"
    fi
    total_events=$((total_events + n))
    printf '%-40s %6d\n' "${pkg}" "${n}" | tee -a "${PERAPP}"
    adb shell am force-stop "${pkg}" >/dev/null 2>&1 || true
done

echo "[heavybail] harvested ${total_events} bail events → ${WORDS}"
echo "[heavybail] per-app counts → ${PERAPP}"

if [ "${DECODE}" = "1" ] && [ "${total_events}" -gt 0 ]; then
    echo "[heavybail] decoding histogram..."
    python3 "${SCRIPT_DIR}/decode-bail-histogram.py" "${WORDS}" | tee "${OUT}/histogram.txt"
    echo "[heavybail] histogram → ${OUT}/histogram.txt"
elif [ "${total_events}" -eq 0 ]; then
    echo "[heavybail] 0 events — is the HEAVY_BAIL diagnostic compiled in and loaded?"
fi
