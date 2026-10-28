#!/bin/bash
# Run the prebuilt-APK gate in batches, one FRESH EMULATOR per batch.
#
# test-prebuilts.sh installs and launches every target into whatever device is
# attached. Across a 200+ app corpus that accumulates packages and background
# services until HEALTHY apps start failing -- blank frames, start timeouts,
# SIGSEGVs that vanish on reboot -- and those read exactly like translator
# regressions. This wrapper slices the corpus and gives each slice a pristine
# device.
#
# It relaunches the emulator process rather than rebooting the guest. Repeated
# guest resets drive the host into
#   crashhandler_die: fatal: kvm_user_backed_ram_map: error registering slot: File exists
# because KVM refuses the RAM-slot re-registration, so the emulator either
# fails to come back (batch silently skipped) or dies with SIGSEGV.
#
# Environment:
#   PREBUILTS_SUBDIR  corpus to sweep (default sample/prebuilts)
#   BATCH_SIZE        targets per emulator (default 8)
#   START_AT          resume at this target index (default 0)
#   RESULTS_FILE      where to append the per-target lines
#   PREBUILTS_EMU_CMD emulator launch command (default: the in-tree emulator)
set -u

# Locate the build tree. This script is reached through digitalis/.claude, which
# the tree root symlinks as .claude, and cd resolves ".." logically -- walking up
# from the link lands outside the tree. Resolve the real path, then search upward
# for the marker rather than counting directory levels.
TOP="${ANDROID_BUILD_TOP:-}"
if [ -z "$TOP" ]; then
  TOP="$(cd -P "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  while [ "$TOP" != "/" ] && [ ! -f "$TOP/build/envsetup.sh" ]; do TOP="$(dirname "$TOP")"; done
fi
if [ ! -f "$TOP/build/envsetup.sh" ]; then
  echo "cannot locate the AOSP tree root (set ANDROID_BUILD_TOP)" >&2; exit 1
fi
cd "$TOP" || exit 1

ADB="out/host/linux-x86/bin/adb -s emulator-5554"
G="${PREBUILTS_SUBDIR:-sample/prebuilts}"
BATCH="${BATCH_SIZE:-8}"
OUT="${RESULTS_FILE:-$TOP/digitalis/out/prebuilts_batched.results}"
WORK="$TOP/digitalis/out/batched"
P="$TOP/out/target/product/emu64xa"
EMU_CMD="${PREBUILTS_EMU_CMD:-prebuilts/android-emulator/linux-x86_64/emulator -memory 4096 -writable-system -no-snapshot-save -wipe-data -qemu -cpu host}"

mkdir -p "$WORK" "$(dirname "$OUT")"

stop_emu() {
  timeout 30 $ADB emu kill >/dev/null 2>&1
  for _ in $(seq 1 30); do pgrep -x qemu-system-x86 >/dev/null || break; sleep 2; done
  pgrep -x qemu-system-x86 >/dev/null && { pkill -x qemu-system-x86; sleep 5; }
  # A dying emulator holds its KVM RAM slots until the core dumper finishes --
  # 1.6 GB takes minutes, and launching before it completes yields
  # "error registering slot: File exists" and a qemu that never serves adb.
  # crashpad_handler exceeds the 15-char comm limit, so pgrep -x cannot match
  # it; -f is required here and is safe because this script's own command line
  # does not contain that string.
  pkill -f crashpad_handler 2>/dev/null
  for _ in $(seq 1 90); do
    [ -z "$(pgrep -x qemu-system-x86)" ] && [ -z "$(pgrep -f crashpad_handler)" ] && break
    sleep 2
  done
  rm -f "$P/hardware-qemu.ini.lock" "$P/multiinstance.lock" "$P/userdata-qemu.img.lock" 2>/dev/null
}

start_emu() {
  ANDROID_PRODUCT_OUT="$P" setsid nohup $EMU_CMD > "$WORK/emu.log" 2>&1 < /dev/null &
  sleep 20
  for _ in $(seq 1 180); do
    pgrep -x qemu-system-x86 >/dev/null || { echo "   EMU-DIED during boot" | tee -a "$OUT"; return 1; }
    if [ "$(timeout 10 $ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
      # boot_completed precedes pm readiness; installing before pm is up fails.
      for _ in $(seq 1 45); do timeout 10 $ADB shell pm path android >/dev/null 2>&1 && break; sleep 2; done
      sleep 5; return 0
    fi
    sleep 2
  done
  echo "   BOOT-TIMEOUT (batch not run)" | tee -a "$OUT"   # loud, never silent
  return 1
}

# A staging area (top-apps/, top-games/) holds many apps; one app's split group
# holds one app. test-prebuilts.sh expands a directory internally, so enrolling
# a staging area as a single target hands it the whole directory and defeats the
# batching entirely -- one sweep ran 115 apps in a single emulator while every
# other batch ran 8, and the tail of that run failed healthy apps. Expand
# staging areas one level deep so every app is its own batched target.
#
# Discriminate on "contains subdirectories that themselves hold APKs", never on
# APK count: a split group legitimately holds base.apk plus several config
# splits, and enrolling a bare config split as a target cannot install.
is_staging() {
  local sd
  for sd in "$1"/*/; do
    [ -d "$sd" ] && compgen -G "${sd%/}/*.apk" >/dev/null && return 0
  done
  return 1
}

mapfile -t TARGETS < <( {
  compgen -G "$G/*.apk" || true
  for d in "$G"/*/; do
    d="${d%/}"
    compgen -G "$d/*.apk" >/dev/null || continue
    if is_staging "$d"; then
      compgen -G "$d/*.apk" || true
      for sd in "$d"/*/; do
        sd="${sd%/}"
        compgen -G "$sd/*.apk" >/dev/null && echo "$sd"
      done
    else
      echo "$d"
    fi
  done
} )

n="${START_AT:-0}"; b=$((n / BATCH))
echo "=== fresh-emulator run: targets ${#TARGETS[@]}, starting at $n ===" | tee -a "$OUT"

while [ "$n" -lt "${#TARGETS[@]}" ]; do
  b=$((b + 1))
  rm -rf "$WORK/batch" && mkdir -p "$WORK/batch"
  for i in $(seq 0 $((BATCH - 1))); do
    t="${TARGETS[$((n + i))]:-}"; [ -z "$t" ] && break
    ln -s "$TOP/$t" "$WORK/batch/" 2>/dev/null
  done
  n=$((n + BATCH))
  echo "=== batch $b ($(ls "$WORK/batch" | wc -l) targets) at $(date +%T) ===" | tee -a "$OUT"
  stop_emu
  if start_emu; then
    PREBUILTS_DIR_OVERRIDE="$WORK/batch" \
    PREBUILTS_SCREENSHOTS_DIR="$WORK/batch-shots" \
    SCREENCAP_TIMEOUT=60 \
    PATH="$TOP/out/host/linux-x86/bin:$PATH" ANDROID_SERIAL=emulator-5554 \
      .claude/scripts/test-prebuilts.sh > "$WORK/batch_$b.log" 2>&1
    if [ "$(grep -acE '^ *(PASS|FAIL|SKIP)' "$WORK/batch_$b.log")" = "0" ]; then
      echo "   BATCH $b PRODUCED NO RESULTS -- see $WORK/batch_$b.log" | tee -a "$OUT"
    else
      grep -aE '^ *(PASS|FAIL|SKIP)' "$WORK/batch_$b.log" | sed -E 's/  +/ /g' | tee -a "$OUT"
    fi
  fi
done

echo "=== FRESH-EMULATOR RUN COMPLETE at $(date +%T) ===" | tee -a "$OUT"
echo "PASS $(grep -acE '^ *PASS ' "$OUT")  FAIL $(grep -acE '^ *FAIL ' "$OUT")  SKIP $(grep -acE '^ *SKIP ' "$OUT")" | tee -a "$OUT"
