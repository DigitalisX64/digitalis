#!/usr/bin/env bash
#
# Runs the benchmark samples across translation modes and collects raw timings.
#
#   digitalis/scripts/run-benchmarks.sh                       # all modes, all modules
#   digitalis/scripts/run-benchmarks.sh --modes two-gear      # one mode
#   digitalis/scripts/run-benchmarks.sh --repeats 3           # repeat each run
#
# Output is newline-delimited JSON, one object per benchmark case per run, at
# digitalis/out/bench/<timestamp>.ndjson. Each record carries the translation
# mode, the repeat index, and every per-iteration timing, so variance analysis
# happens on the host — nothing is averaged away on the device.
#
# The translation mode is read once when the translator initialises, so each
# run force-stops the app first: setting the property under a live process
# would silently measure the previous mode.
set -uo pipefail

MODES="interpret-only lite-translate-or-interpret two-gear"
MODULES=""
REPEATS=1
TIMEOUT=180

while [ $# -gt 0 ]; do
  case "$1" in
    --modes)    MODES="$2"; shift 2 ;;
    --modules)  MODULES="$2"; shift 2 ;;
    --repeats)  REPEATS="$2"; shift 2 ;;
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Modules enrol themselves: any sample whose build.gradle.kts depends on
# bench-lib is a benchmark module, so adding one needs no edit here. The
# component name is read from its applicationId and MainActivity package.
discover_modules() {
  for gradle in sample/hellodigitalis/*/build.gradle.kts; do
    grep -q 'project(":bench-lib")' "$gradle" || continue
    dir="$(dirname "$gradle")"
    activity="$(find "$dir/src/main/java" -name MainActivity.kt 2>/dev/null | head -1)"
    [ -n "$activity" ] || continue
    app="$(sed -n 's/.*applicationId = "\([^"]*\)".*/\1/p' "$gradle" | head -1)"
    pkg="$(sed -n 's/^package \([A-Za-z0-9_.]*\).*/\1/p' "$activity" | head -1)"
    [ -n "$app" ] && [ -n "$pkg" ] || continue
    echo "$(basename "$dir"):$app/$pkg.MainActivity"
  done
}

[ -n "$MODULES" ] || MODULES="$(cd "$(dirname "$0")/../.." && discover_modules)"

cd "$(dirname "$0")/../.."
OUT_DIR="digitalis/out/bench"
mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUT_DIR/$STAMP.ndjson"
touch "$OUT"

command -v adb >/dev/null || { echo "adb not found" >&2; exit 1; }
adb get-state >/dev/null 2>&1 || { echo "no device: start the emulator first" >&2; exit 1; }

# berberis.mode is not writable by the shell user: adbd has to be root for
# setprop to be permitted, otherwise every run would silently measure the
# default mode.
if [ "$(adb shell whoami | tr -d '\r')" != "root" ]; then
  adb root >/dev/null 2>&1 || true
  adb wait-for-device
  if [ "$(adb shell whoami | tr -d '\r')" != "root" ]; then
    echo "adb root unavailable: cannot switch translation modes" >&2
    exit 1
  fi
fi

DEVICE_FINGERPRINT="$(adb shell getprop ro.build.fingerprint | tr -d '\r')"
echo "device:  $DEVICE_FINGERPRINT"
echo "output:  $OUT"

fail=0
for repeat in $(seq 1 "$REPEATS"); do
  for mode in $MODES; do
    adb shell setprop berberis.mode "$mode"
    applied="$(adb shell getprop berberis.mode | tr -d '\r')"
    if [ "$applied" != "$mode" ]; then
      echo "  !! could not set berberis.mode=$mode (got '$applied')" >&2
      fail=1
      continue
    fi
    echo "== repeat $repeat/$REPEATS · mode $mode =="

    for entry in $MODULES; do
      module="${entry%%:*}"
      component="${entry#*:}"
      package="${component%%/*}"

      adb shell am force-stop "$package"
      adb logcat -c
      adb shell am start -n "$component" >/dev/null 2>&1

      # Wait for the module to report it is finished, or give up.
      waited=0
      while [ "$waited" -lt "$TIMEOUT" ]; do
        if adb logcat -d -s DigitalisBench 2>/dev/null | grep -q "BENCH_DONE $module"; then
          break
        fi
        sleep 2
        waited=$((waited + 2))
      done

      lines="$(adb logcat -d -s DigitalisBench 2>/dev/null)"
      if ! printf '%s' "$lines" | grep -q "BENCH_DONE $module"; then
        echo "  $module: TIMEOUT after ${TIMEOUT}s" >&2
        fail=1
      fi
      printf '%s' "$lines" | grep -o 'BENCH_FAIL .*' | sed 's/^/  /' >&2

      cases=0
      while IFS= read -r json; do
        [ -n "$json" ] || continue
        python3 - "$json" "$mode" "$repeat" "$DEVICE_FINGERPRINT" >> "$OUT" <<'PY'
import json, sys
record = json.loads(sys.argv[1])
record["mode"] = sys.argv[2]
record["repeat"] = int(sys.argv[3])
record["device"] = sys.argv[4]
print(json.dumps(record, separators=(",", ":")))
PY
        cases=$((cases + 1))
      done < <(printf '%s' "$lines" | grep -o 'BENCH {.*}' | sed 's/^BENCH //')

      echo "  $module: $cases case(s)"
      adb shell am force-stop "$package"
    done
  done
done

# Leave the device on the default mode rather than whatever ran last.
adb shell setprop berberis.mode two-gear

echo
echo "wrote $(wc -l < "$OUT") record(s) to $OUT"
echo "summarise with: digitalis/scripts/summarize-benchmarks.py $OUT"
exit "$fail"
