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

# The `native` pseudo-mode times the same workload built for the host ABI, so
# the translated tiers have a denominator that means something: "42x the
# interpreter" says nothing about whether translated code is fast enough to use,
# whereas "% of native" does. It is not a translation mode -- no berberis.mode is
# set, nothing is translated -- so it is handled as a separate arm below.
#
# A native build is a normal `assembleDebug -PnativeBaseline`, which swaps the
# module's abiFilters to x86_64 and installs it under a `.native` application id
# alongside the arm64 build. --build-native does that for the selected modules.
NATIVE_SUFFIX=".native"
BUILD_NATIVE=0

# Modules with no meaningful native baseline, and why. The first three compute
# with ARM64 intrinsics and inline `.inst` encodings: there is no x86_64 build of
# the same work, only a different program, so comparing them would be dishonest
# rather than merely unavailable. The last two carry their natives inside jars
# (a gdx `natives-arm64-v8a` classifier; snappy-java extracting at runtime), so
# an x86_64 build needs a dependency swap that has not been made yet.
NATIVE_EXCLUDE="hello-neon hello-neonmisc hello-bf16 hello-box2d hello-snappy"

while [ $# -gt 0 ]; do
  case "$1" in
    --modes)    MODES="$2"; shift 2 ;;
    --modules)  MODULES="$2"; shift 2 ;;
    --repeats)  REPEATS="$2"; shift 2 ;;
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    --build-native) BUILD_NATIVE=1; shift ;;
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

# Validate --modules up front. Entries are `module:package/activity`; a bare
# module name parses into a package that does not exist, so `am start` simply
# never launches anything and every case burns the full timeout before
# reporting "0 case(s)" — a sweep that looks like a total translator failure
# but is only a typo. Fail immediately instead, and show the expected form.
for entry in $MODULES; do
  case "$entry" in
    *:*/*) ;;
    *)
      echo "bad --modules entry: '$entry'" >&2
      echo "expected 'module:package/activity', for example:" >&2
      (cd "$(dirname "$0")/../.." && discover_modules | sed 's/^/  /') >&2
      exit 2
      ;;
  esac
done

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

if [ "$BUILD_NATIVE" = 1 ]; then
  echo "building native (x86_64) baseline builds"
  native_targets=""
  for entry in $MODULES; do
    module="${entry%%:*}"
    case " $NATIVE_EXCLUDE " in
      *" $module "*) echo "  skip $module (no native baseline defined)"; continue ;;
    esac
    native_targets="$native_targets :$module:assembleDebug"
  done
  if [ -n "$native_targets" ]; then
    # shellcheck disable=SC2086
    (cd sample/hellodigitalis && ./gradlew -PnativeBaseline -q $native_targets) || {
      echo "native build failed" >&2; exit 1; }
    for entry in $MODULES; do
      module="${entry%%:*}"
      case " $NATIVE_EXCLUDE " in *" $module "*) continue ;; esac
      apk="$(ls sample/hellodigitalis/$module/build/outputs/apk/debug/*.apk 2>/dev/null | head -1)"
      [ -n "$apk" ] || { echo "  $module: no APK produced" >&2; continue; }
      # A module whose natives live in a dependency rather than its own
      # CMakeLists can build clean and still contain no host code; installing it
      # would silently measure nothing.
      if ! unzip -l "$apk" 2>/dev/null | grep -q "lib/x86_64/"; then
        echo "  $module: built without x86_64 natives, not installing" >&2
        continue
      fi
      adb install -r -g "$apk" >/dev/null 2>&1 && echo "  installed $module" \
        || echo "  $module: install failed" >&2
    done
  fi
  # Leave the tree building arm64 again, so a later plain assembleDebug does not
  # quietly produce host binaries.
  (cd sample/hellodigitalis && ./gradlew -q $(for e in $MODULES; do printf ':%s:assembleDebug ' "${e%%:*}"; done) >/dev/null 2>&1) || true
fi

fail=0
CLEARED=""
for repeat in $(seq 1 "$REPEATS"); do
  for mode in $MODES; do
    if [ "$mode" = native ]; then
      # Nothing to set: the native build is host code and never reaches the
      # translator. Leaving berberis.mode alone also keeps the arm64 modules in
      # this sweep on whatever mode ran last, which is why native runs last.
      echo "== repeat $repeat/$REPEATS · mode native (no translation) =="
    else
      adb shell setprop berberis.mode "$mode"
      applied="$(adb shell getprop berberis.mode | tr -d '\r')"
      if [ "$applied" != "$mode" ]; then
        echo "  !! could not set berberis.mode=$mode (got '$applied')" >&2
        fail=1
        continue
      fi
      echo "== repeat $repeat/$REPEATS · mode $mode =="
    fi

    for entry in $MODULES; do
      module="${entry%%:*}"
      component="${entry#*:}"
      package="${component%%/*}"

      if [ "$mode" = native ]; then
        case " $NATIVE_EXCLUDE " in
          *" $module "*) continue ;;
        esac
        package="$package$NATIVE_SUFFIX"
        component="$package/${component#*/}"
        if ! adb shell pm list packages 2>/dev/null | grep -Fqx "package:$package"; then
          echo "  $module: no native build installed (--build-native)" >&2
          continue
        fi
      fi

      adb shell am force-stop "$package"
      # Clear app data the first time each module runs in this invocation.
      # Digitalis extracts in-APK guest libraries into app data, and a plain
      # `adb install -r` does NOT invalidate that extract — so after a
      # reinstall the app can silently keep executing the OLD native library.
      # That once produced a convincing but entirely fictitious 7.7x
      # translator regression. The apps hold no state worth keeping; always
      # start each sweep from a fresh extract.
      case " $CLEARED " in
        *" $package "*) ;;
        *)
          adb shell pm clear "$package" >/dev/null
          CLEARED="$CLEARED $package"
          ;;
      esac
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
