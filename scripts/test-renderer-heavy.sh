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
# test-renderer-heavy.sh — heavy-tier renderer-crash gate.
#
# A heavy-optimizer miscompile can pass every per-op host exec test and the
# main-process prebuilt gate yet deterministically crash a Chromium *renderer*
# (sandboxed_process) — the page shows "Aw, Snap!" while the browser process
# stays alive. (This is exactly how a bad FCSEL heavy lowering shipped once.)
# This gate exercises that path: it deploys the freshly-built libberberis to
# BOTH /system paths with an md5 check (defeating the stale-inode trap),
# forces the heavy tier on, launches a Chromium-based prebuilt a few times, and
# FAILS if the renderer crashes.
#
# Requires: a booted emulator, a Chromium-based prebuilt installed. Defaults to
# Helium; override with arg 1 = package. Exits non-zero on a renderer crash.

set -u
PKG="${1:-io.github.jqssun.helium}"
RUNS="${RENDERER_RUNS:-3}"
OUT="out/target/product/emu64xa/system/lib64/libberberis_arm64.so"

if ! adb shell pm list packages 2>/dev/null | grep -q "$PKG"; then
    echo "SKIP: $PKG not installed — renderer gate not run."
    exit 0
fi

# Deploy the freshly-built lib to BOTH paths and verify md5 (stale-inode trap).
adb root >/dev/null 2>&1; adb remount >/dev/null 2>&1
adb shell "am force-stop $PKG; stop" >/dev/null 2>&1
adb push "$OUT" /system/lib64/libberberis_arm64.so >/dev/null 2>&1
adb push "$OUT" /system/lib64/arm64/libberberis_arm64.so >/dev/null 2>&1
adb shell sync
built=$(md5sum "$OUT" | awk '{print $1}')
p1=$(adb shell md5sum /system/lib64/libberberis_arm64.so 2>/dev/null | tr -d '\r' | awk '{print $1}')
p2=$(adb shell md5sum /system/lib64/arm64/libberberis_arm64.so 2>/dev/null | tr -d '\r' | awk '{print $1}')
if [ "$built" != "$p1" ] || [ "$built" != "$p2" ]; then
    echo "FAIL: deployed lib md5 mismatch (built=$built p1=$p1 p2=$p2) — stale deploy, cannot trust the gate."
    exit 2
fi

adb shell "start" >/dev/null 2>&1
for i in $(seq 1 30); do adb shell pm list packages 2>/dev/null | grep -q "$PKG" && break; sleep 3; done
adb shell "sleep 10"
adb shell setprop berberis.mode two-gear

crashes=0
for run in $(seq 1 "$RUNS"); do
    adb shell "am force-stop $PKG; logcat -c" >/dev/null 2>&1
    adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    adb shell "sleep 16"
    # The reliable renderer-crash marker: ActivityManager schedules a restart of
    # the *crashed* sandboxed service. (Chromium's own signal handler swallows
    # the fault, so debuggerd's "Fatal signal" may not fire.)
    n=$(adb logcat -d 2>/dev/null | grep -cE "Scheduling restart of crashed service.*SandboxedProcessService")
    echo "  $PKG run $run: renderer_crashes=$n"
    [ "$n" -gt 0 ] && crashes=$((crashes + 1))
done

if [ "$crashes" -gt 0 ]; then
    echo "RENDERER GATE FAIL: $PKG renderer crashed in $crashes/$RUNS heavy-tier launches."
    echo "A heavy-optimizer change miscompiles a real region. Bail the offending op to lite."
    exit 1
fi
echo "RENDERER GATE PASS: $PKG rendered cleanly ($RUNS/$RUNS) with the heavy tier on."
exit 0
