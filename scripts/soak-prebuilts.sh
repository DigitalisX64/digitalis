#!/usr/bin/env bash
#
# soak-prebuilts.sh — reproduction + instrumentation driver for the
# "emulator-exhaustion flaky SIGSEGV".
#
# Symptom being chased:
# after a long test session, a *different* prebuilt app dies each run with
#   Fatal signal 11 (SIGSEGV), code 2 (SEGV_ACCERR), fault addr 0x76....fff0
# — the SAME high host address every time, near a page boundary; each app
# passes in isolation; `adb reboot` clears it. That signature (constant HIGH
# host address, different app, reboot-clears) points at a host-side
# (emulator/gfxstream) resource, NOT the low-2GB Berberis exec-region leak.
#
# This driver does two things over many launch cycles:
#   1. Samples the resources that could be exhausting, per guest app process
#      and for the host emulator, into a CSV so growth is visible:
#        - total VMA count            (/proc/<pid>/maps line count)
#        - memfd:exec region count + KB  (Berberis exec + write aliases)
#        - low-2GB exec-alias KB      (the b/232598137 exec-region leak metric:
#                                       exec aliases live in MAP_32BIT space and
#                                       are NEVER unmapped — only the writable
#                                       alias is Detach()ed)
#        - host emulator RSS KB       (qemu-system-x86_64)
#   2. Scans logcat + the emulator log each round for the SEGV_ACCERR /
#      gfxstream-abort signatures and records the first flake it sees, so a
#      soak that finally trips can capture the faulting address + maps.
#
# It is a *diagnostic* tool, not a gate: it never fails the build. Point it at
# an already-booted emulator; it discovers the top-level prebuilt APKs the same
# way test-prebuilts.sh does (non-recursive; top-apps/ and top-games/ excluded).
#
# Usage:
#   digitalis/scripts/soak-prebuilts.sh [ROUNDS]
# Env knobs:
#   ROUNDS               (default 20)  number of launch cycles
#   SOAK_WATCH_SECONDS   (default 12)  dwell per app per round before sampling
#   SOAK_OUT             (default /tmp/soak-prebuilts)  output dir (CSV + logs)
#   SOAK_PERSIST         (default 0)   1 = launch each app ONCE and keep it
#                                      alive across all rounds, re-sampling the
#                                      SAME pids each round. Use this to watch
#                                      the b/232598137 exec-region leak grow
#                                      *within* a long-lived process (the churn
#                                      default measures per-cold-launch
#                                      footprint + reproduces the flake instead).
#
# Copyright (C) 2026 utzcoz
# SPDX-License-Identifier: Apache-2.0

set -u
set -o pipefail

WORK_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PREBUILTS_DIR="${WORK_DIR}/sample/prebuilts"
AAPT2="${WORK_DIR}/out/host/linux-x86/bin/aapt2"
ROUNDS="${1:-${ROUNDS:-20}}"
WATCH="${SOAK_WATCH_SECONDS:-12}"
PERSIST="${SOAK_PERSIST:-0}"
OUT="${SOAK_OUT:-/tmp/soak-prebuilts}"
CSV="${OUT}/samples.csv"
FLAKES="${OUT}/flakes.log"
EMU_LOG="${EMU_LOG:-/tmp/emu.log}"

mkdir -p "${OUT}"
: > "${FLAKES}"
echo "round,ts,pkg,pid,total_vmas,memfd_exec_n,memfd_exec_kb,low2g_exec_kb,host_rss_kb" > "${CSV}"

if ! adb get-state >/dev/null 2>&1; then
    echo "[soak] no adb device — nothing to do"; exit 0
fi
if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; then
    echo "[soak] device not booted — nothing to do"; exit 0
fi
if [ ! -x "${AAPT2}" ]; then
    echo "[soak] aapt2 missing at ${AAPT2}"; exit 2
fi

shopt -s nullglob
APKS=( "${PREBUILTS_DIR}"/*.apk )   # non-recursive on purpose
shopt -u nullglob
if [ ${#APKS[@]} -eq 0 ]; then
    echo "[soak] no *.apk under ${PREBUILTS_DIR}"; exit 0
fi

# Resolve package names once and make sure each is installed.
declare -a PKGS=()
for apk in "${APKS[@]}"; do
    pkg="$("${AAPT2}" dump packagename "${apk}" 2>/dev/null | head -1)"
    [ -z "${pkg}" ] && continue
    adb install -r -g "${apk}" >/dev/null 2>&1 || true
    PKGS+=( "${pkg}" )
done
echo "[soak] ${#PKGS[@]} packages, ${ROUNDS} rounds, ${WATCH}s dwell → ${CSV}"

host_rss_kb() {
    # RSS of the emulator host process, in KB.
    local hp
    hp="$(pgrep -f qemu-system-x86_64 | head -1)"
    [ -z "${hp}" ] && { echo 0; return; }
    awk '/^VmRSS:/{print $2}' "/proc/${hp}/status" 2>/dev/null || echo 0
}

# Sample one live guest pid's address space into the CSV.
sample_pid() {
    local round="$1" pkg="$2" pid="$3" hrss="$4"
    [ -z "${pid}" ] && return
    # Pull maps once; compute all metrics from it.
    local maps
    maps="$(adb shell "cat /proc/${pid}/maps" 2>/dev/null | tr -d '\r')"
    [ -z "${maps}" ] && return
    local line
    line="$(printf '%s\n' "${maps}" | awk -v r="${round}" -v pkg="${pkg}" -v pid="${pid}" -v hrss="${hrss}" '
        { total++ }
        /memfd:exec/ {
            n++; split($1,a,"-");
            s=strtonum("0x" a[1]); e=strtonum("0x" a[2]); kb=(e-s)/1024; exkb+=kb;
            if (s < 2147483648) low2g+=kb;   # MAP_32BIT exec aliases (the leak)
        }
        END { printf "%s,%d,%s,%s,%d,%d,%d,%d,%s", r, systime(), pkg, pid, total, n+0, exkb+0, low2g+0, hrss }
    ')"
    echo "${line}" >> "${CSV}"
}

# Scan for the flake signatures; append any hit (with faulting address + the
# live app maps) to FLAKES so a tripped soak is self-documenting.
scan_flakes() {
    local round="$1"
    local crash
    crash="$(adb logcat -d -b crash,main 2>/dev/null | tr -d '\r' | \
             grep -iE 'SEGV_ACCERR|Unhandled Vulkan structure|VkDecoderGlobalState.*abort|Fatal signal .*fff0' | head -5)"
    if [ -n "${crash}" ]; then
        { echo "=== round ${round} flake ==="; echo "${crash}"; } >> "${FLAKES}"
        echo "[soak] FLAKE in round ${round}:"; echo "${crash}"
    fi
    # Emulator-side gfxstream/host aborts.
    if [ -r "${EMU_LOG}" ]; then
        local emu
        emu="$(grep -iE 'aborting|Unhandled Vulkan|out of memory|mmap.*failed' "${EMU_LOG}" 2>/dev/null | tail -3)"
        [ -n "${emu}" ] && { echo "=== round ${round} emu-log ==="; echo "${emu}"; } >> "${FLAKES}"
    fi
}

for r in $(seq 1 "${ROUNDS}"); do
    adb logcat -c >/dev/null 2>&1 || true
    hrss="$(host_rss_kb)"
    for pkg in "${PKGS[@]}"; do
        # Churn mode (default): force-stop + relaunch each round (fresh pid) —
        # reproduces the per-launch flake. Persist mode: launch only if dead,
        # so the same long-lived pid accumulates and the exec-region leak shows.
        if [ "${PERSIST}" = "1" ]; then
            if [ -z "$(adb shell pidof "${pkg}" 2>/dev/null | tr -d '\r')" ]; then
                adb shell monkey --pct-syskeys 0 -p "${pkg}" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
            fi
        else
            adb shell am force-stop "${pkg}" >/dev/null 2>&1 || true
            adb shell monkey --pct-syskeys 0 -p "${pkg}" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
        fi
    done
    sleep "${WATCH}"
    for pkg in "${PKGS[@]}"; do
        pid="$(adb shell pidof "${pkg}" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
        sample_pid "${r}" "${pkg}" "${pid}" "${hrss}"
    done
    scan_flakes "${r}"
    # Per-round leak headline: max low-2GB exec-alias KB seen this round.
    max_low2g="$(awk -F, -v r="${r}" '$1==r{if($8>m)m=$8}END{print m+0}' "${CSV}")"
    echo "[soak] round ${r}/${ROUNDS}: host_rss=$((hrss/1024))MB  max_low2g_exec=$((max_low2g/1024))MB"
done

echo "[soak] done. samples: ${CSV}  flakes: ${FLAKES}"
if [ "${PERSIST}" = "1" ]; then
    echo "[soak] low-2GB exec-alias leak growth per long-lived pkg (first -> last round):"
else
    echo "[soak] per-cold-launch low-2GB exec-alias footprint per pkg (min .. max KB):"
fi
awk -F, 'NR>1 && $8!=""{ if(!(($3) in seen)){seen[$3]=1; first[$3]=$8; mn[$3]=$8} ; last[$3]=$8; if($8>mx[$3])mx[$3]=$8; if($8<mn[$3])mn[$3]=$8 }
         END{ for(p in seen) printf "  %-32s  %6d -> %6d KB   (min %d .. max %d)\n", p, first[p], last[p], mn[p], mx[p] }' "${CSV}" | sort
