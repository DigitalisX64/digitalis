#!/bin/bash
#
# Copyright (C) 2026 utzcoz
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# collect-digitalis-crash.sh
#
# Gather everything needed to root-cause a Digitalis (ARM64->x86_64 native
# bridge) crash on a device/emulator, into one tarball to send back. Runs on the
# host with only `adb`. Safe on both `user` and `userdebug` builds (it degrades
# gracefully when root is unavailable and always falls back to `adb bugreport`).
#
# Usage:
#   ./collect-digitalis-crash.sh [package] [component]
#     package   : app to reproduce      (default: io.github.jqssun.helium — Helium)
#     component : optional explicit "pkg/activity" to start; default uses the launcher
#
# Why these fields: the reference crash was the translator's own mmap() returning
# ENOMEM (tombstone abort "mmap_posix.cc: CHECK failed ... 0xff..ff != 0xff..ff").
# mmap() can return ENOMEM for THREE distinct reasons, and the fix differs per
# reason, so we capture enough to tell them apart:
#   1) sysctl vm.max_map_count  — the per-process VMA (mapping) count ceiling
#   2) RLIMIT_AS                 — the per-process address-space ceiling
#   3) strict overcommit         — vm.overcommit_memory=2 + a low CommitLimit
# The crash-time VMA count lives in the tombstone ("memory map (N entries)").

set -u
PKG="${1:-io.github.jqssun.helium}"
COMP="${2:-}"
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo capture)"
OUT="digitalis-crash-${STAMP}"
mkdir -p "$OUT/tombstones"
say() { echo "[collect] $*"; }
sh_() { adb shell "$@" 2>/dev/null | tr -d '\r'; }

adb wait-for-device || { echo "no device; connect one and retry"; exit 1; }
# userdebug lets us read another process's /proc and /data/tombstones; harmless no-op on user.
adb root >/dev/null 2>&1 && sleep 2 && adb wait-for-device
HAVE_ROOT=$(sh_ id | grep -c "uid=0")

# ---- 0. What translator is actually in the image (confirm the patch is present) ----
sh_ 'md5sum /system/lib64/libberberis_arm64.so /system/lib64/arm64/libberberis_arm64.so' > "$OUT/libberberis_md5.txt"
adb shell getprop > "$OUT/getprop.txt" 2>/dev/null

# ---- 1. Static resource ceilings (all world-readable, work without root) ----
{
  echo "vm.max_map_count = $(sh_ 'cat /proc/sys/vm/max_map_count')"
  echo "vm.overcommit_memory = $(sh_ 'cat /proc/sys/vm/overcommit_memory')  # 0=heuristic 1=always 2=strict"
  echo "vm.overcommit_ratio  = $(sh_ 'cat /proc/sys/vm/overcommit_ratio')"
  echo "--- /proc/meminfo (Commit* matter for strict overcommit) ---"
  sh_ 'cat /proc/meminfo' | grep -iE "MemTotal|MemAvailable|CommitLimit|Committed_AS"
} > "$OUT/resource_ceilings.txt"

# ---- 2. Reproduce ----
adb logcat -c 2>/dev/null
adb shell am force-stop "$PKG" 2>/dev/null
say "launching $PKG ..."
if [ -n "$COMP" ]; then adb shell am start -n "$COMP" >/dev/null 2>&1
else adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; fi

# ---- 3. Sample live processes while the app is up (children are short-lived) ----
#     RLIMIT_AS is inherited, so ANY live app pid gives it; VmPeak/maps show usage.
: > "$OUT/live_proc.txt"
for t in $(seq 1 12); do
  for p in $(sh_ "pidof $PKG"); do
    {
      echo "===== t=${t}s pid=$p cmd=$(sh_ "cat /proc/$p/cmdline" | tr '\0' ' ') ====="
      echo "VMA_count=$(sh_ "wc -l < /proc/$p/maps")"
      sh_ "cat /proc/$p/status" | grep -iE "VmPeak|VmSize|VmRSS"
      sh_ "cat /proc/$p/limits" | grep -iE "Max address space|Max data size|Max open files|Limit"
    } >> "$OUT/live_proc.txt"
  done
  sleep 2
done

# ---- 4. Logs + tombstones ----
sleep 4
adb logcat -d > "$OUT/logcat.txt" 2>/dev/null
sh_ 'dmesg' | grep -iE "oom|out of memory|killed process|vm|mmap" > "$OUT/dmesg_mem.txt"
sh_ 'ls -la /data/tombstones/' > "$OUT/tombstones_list.txt"
adb pull /data/tombstones "$OUT/tombstones" >/dev/null 2>&1   # needs root
say "capturing bugreport (works even on user builds; ~1 min) ..."
adb bugreport "$OUT/bugreport" >/dev/null 2>&1

# ---- 5. Auto-summary: extract + interpret the decisive fields ----
TB=$(ls "$OUT"/tombstones/* 2>/dev/null; ls "$OUT"/tombstones/*/* 2>/dev/null)
{
  echo "==================== DIGITALIS CRASH SUMMARY ===================="
  echo "package     : $PKG"
  echo "have_root   : $([ "$HAVE_ROOT" = 1 ] && echo yes || echo 'no (user build — rely on bugreport for tombstones)')"
  echo
  echo "-- native-bridge props --"
  grep -iE "native.bridge|isa.arm64|ro.berberis" "$OUT/getprop.txt" 2>/dev/null
  echo
  echo "-- resource ceilings --"; cat "$OUT/resource_ceilings.txt"
  echo
  echo "-- translator abort message(s) --"
  grep -hE "Abort message:|signal [0-9]" $TB 2>/dev/null | sort -u | head
  echo
  echo "-- crash-time VMA count (tombstone) --"
  grep -hE "memory map \([0-9]+ entries\)" $TB 2>/dev/null | sort -u
  echo
  echo "-- live-process peak address space + RLIMIT_AS --"
  grep -iE "VmPeak|Max address space|VMA_count" "$OUT/live_proc.txt" 2>/dev/null | sort -u | head -20
  echo
  echo "INTERPRETATION"
  echo "  If an abort message reads mmap_posix.cc CHECK ... 0xff..ff != 0xff..ff,"
  echo "  the translator's mmap() got ENOMEM. Compare:"
  echo "   * crash-time VMA count  vs  vm.max_map_count"
  echo "       ~equal  -> the VMA ceiling fired (raise vm.max_map_count; the 64Mb"
  echo "                  memfd-region patch also cuts this structure's VMAs ~4x)."
  echo "       far below (e.g. ~5000 vs 65530) -> NOT the VMA ceiling."
  echo "   * VmPeak  vs  RLIMIT_AS (Max address space)"
  echo "       VmPeak near a finite RLIMIT_AS -> the address-space ceiling fired"
  echo "       (the 64Mb patch does NOT help this; needs the structural table fix"
  echo "        or a larger RLIMIT_AS for the app's child processes)."
  echo "   * vm.overcommit_memory=2 and Committed_AS near CommitLimit"
  echo "       -> strict overcommit refused the mapping (raise CommitLimit / ratio,"
  echo "          or add swap; not a translator bug)."
  echo "  A DIFFERENT abort message => a different bug: send tombstone + logcat, and"
  echo "  optionally the berberis trace: setenforce 0, setprop berberis.tracing"
  echo "  '<pkg>=digitalis-trace.log', relaunch, pull it from /data/user/0/<pkg>/."
  echo "================================================================"
} > "$OUT/SUMMARY.txt" 2>&1
cat "$OUT/SUMMARY.txt"

[ "$HAVE_ROOT" = 1 ] && adb shell setenforce 1 >/dev/null 2>&1
tar czf "${OUT}.tar.gz" "$OUT" 2>/dev/null && say "DONE -> ${OUT}.tar.gz  (send this file back)"
