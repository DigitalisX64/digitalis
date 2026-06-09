#!/bin/bash
#
# test-samples.sh — Test hellodigitalis sample modules on the Digitalis emulator.
#
# Usage:
#   .claude/scripts/test-samples.sh                           # Liveness tests (existing)
#   .claude/scripts/test-samples.sh hello-vulkan               # Single module liveness
#   .claude/scripts/test-samples.sh --screenshots             # Screenshot tests (rendering)
#   .claude/scripts/test-samples.sh --screenshots hello-vulkan # Single rendering module
#   .claude/scripts/test-samples.sh --status                  # Status tests (non-rendering)
#   .claude/scripts/test-samples.sh --status hello-neon        # Single status module
#   .claude/scripts/test-samples.sh --update-references              # Update refs all
#   .claude/scripts/test-samples.sh --update-references hello-vulkan # Update refs single
#
# Two separate instrumentation modes, by sample kind:
#   --screenshots → rendering modules only (ScreenshotTest): pixel-compare the
#                   captured screen against a committed reference image.
#   --status      → non-rendering modules only (StatusTest): launch the app and
#                   assert it ran with no crash or self-reported failure marker
#                   in logcat (compute / status / callback samples have no
#                   meaningful visual output to compare).
# Each module is selected by exactly one of the two modes (per its TEST_CLASSES
# entry). --update-references applies only to the rendering modules.
#
# Requires: emulator booted, adb root, adb remount done.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}" && while [[ "$PWD" != "/" ]]; do
    if [[ -f "$PWD/build/envsetup.sh" ]]; then echo "$PWD"; exit 0; fi
    cd ..
done
echo "${SCRIPT_DIR}/../.." )"
SAMPLE_DIR="${WORK_DIR}/sample/hellodigitalis"

# Argument parsing: first arg may be a mode flag, second (or first) may be a module filter
MODE="liveness"
FILTER=""
if [[ "${1:-}" == "--screenshots" ]]; then
    MODE="screenshots"
    FILTER="${2:-}"
elif [[ "${1:-}" == "--status" ]]; then
    MODE="status"
    FILTER="${2:-}"
elif [[ "${1:-}" == "--update-references" ]]; then
    MODE="update-references"
    FILTER="${2:-}"
else
    FILTER="${1:-}"
fi

# The instrumentation modes target different test classes:
#   --screenshots → rendering modules only      (com…ScreenshotTest, pixel compare)
#   --status      → non-rendering modules only  (com…StatusTest, run-clean check)
# A module is selected by a mode only if its TEST_CLASSES entry matches the
# corresponding suffix; this is enforced in the instrumentation loop below.
case "$MODE" in
    screenshots) TEST_SUFFIX=".ScreenshotTest" ;;
    status)      TEST_SUFFIX=".StatusTest" ;;
    *)           TEST_SUFFIX="" ;;
esac

WAIT_SECS=5

# Modules that need runtime permissions granted after install
declare -A MODULE_PERMISSIONS=(
    ["camera-basic"]="android.permission.CAMERA"
    ["camera-texture-view"]="android.permission.CAMERA"
)

# Grant runtime permissions for a module after install
grant_permissions() {
    local mod=$1
    local pkg=$2
    if [[ -n "${MODULE_PERMISSIONS[$mod]:-}" ]]; then
        for perm in ${MODULE_PERMISSIONS[$mod]}; do
            adb shell pm grant "$pkg" "$perm" 2>/dev/null || true
        done
    fi
}

# region digitalis
# Reset the foreground before each per-module screenshot test.
# Prevents the stale-foreground capture flake: if any other
# activity (a previously-tested sample, OR a prebuilt APK like
# VkCapsViewer that lingers in the foreground) is still on top when the
# next test's instrumented Intent fires, the screenshot can capture the
# wrong UI. Two-stage reset:
#   1. send HOME so the launcher takes focus (this kicks any prebuilt
#      foreground out — sample force-stops alone can't touch packages
#      not listed in MODULE_ORDER)
#   2. force-stop every sample package except the one under test, so
#      the recents stack is clean and stale activities can't re-enter
#      a render loop in the background
# Sample force-stops are chained into a single adb shell call to avoid
# paying ~30 adb round-trips (~1 ms in-shell vs ~50 ms over adb).
force_stop_other_samples() {
    local current_pkg="$1"
    adb shell input keyevent KEYCODE_HOME 2>/dev/null || true
    local cmd=""
    local other_comp other_pkg other_mod
    for other_mod in "${MODULE_ORDER[@]}"; do
        other_comp="${MODULES[$other_mod]}"
        other_pkg="${other_comp%%/*}"
        if [[ "$other_pkg" != "$current_pkg" ]]; then
            if [[ -z "$cmd" ]]; then
                cmd="am force-stop $other_pkg"
            else
                cmd="$cmd; am force-stop $other_pkg"
            fi
        fi
    done
    if [[ -n "$cmd" ]]; then
        adb shell "$cmd" 2>/dev/null || true
    fi
}
# endregion

# Module -> component mapping (package/activity)
declare -A MODULES=(
    ["hello-vulkan"]="com.example.hellodigitalis/android.app.NativeActivity"
    ["hello-jni"]="com.example.hellodigitalis.hellojni/com.example.hellojni.HelloJni"
    ["hello-jniCallback"]="com.example.hellodigitalis.hellojnicallback/com.example.hellojnicallback.MainActivity"
    ["exceptions"]="com.example.hellodigitalis.exceptions/com.example.exceptions.MainActivity"
    ["bitmap-plasma"]="com.example.hellodigitalis.plasma/com.example.plasma.Plasma"
    ["hello-gl2"]="com.example.hellodigitalis.gl2jni/com.android.gl2jni.GL2JNIActivity"
    ["gles3jni"]="com.example.hellodigitalis.gles3jni/com.android.gles3jni.GLES3JNIActivity"
    ["native-activity"]="com.example.hellodigitalis.nativeactivity/android.app.NativeActivity"
    ["native-audio"]="com.example.hellodigitalis.nativeaudio/com.example.nativeaudio.NativeAudio"
    ["native-codec"]="com.example.hellodigitalis.nativecodec/com.example.nativecodec.NativeCodec"
    ["native-midi"]="com.example.hellodigitalis.nativemidi/com.example.nativemidi.MainActivity"
    ["sensor-graph"]="com.example.hellodigitalis.sensorgraph/com.example.hellodigitalis.sensorgraph.AccelerometerGraphActivity"
    ["camera-basic"]="com.example.hellodigitalis.camerabasic/com.example.hellodigitalis.camerabasic.CameraActivity"
    ["camera-texture-view"]="com.example.hellodigitalis.cameratextureview/com.example.hellodigitalis.cameratextureview.ViewActivity"
    ["teapots-classic"]="com.example.hellodigitalis.teapotsclassic/com.sample.teapot.TeapotNativeActivity"
    ["teapots-more"]="com.example.hellodigitalis.teapotsmore/com.sample.moreteapots.MoreTeapotsNativeActivity"
    ["teapots-textured"]="com.example.hellodigitalis.teapotstextured/com.sample.texturedteapot.TeapotNativeActivity"
    ["endless-tunnel"]="com.example.hellodigitalis.endlesstunnel/android.app.NativeActivity"
    ["sanitizers"]="com.example.hellodigitalis.sanitizers/com.example.hellodigitalis.sanitizers.MainActivity"
    ["unit-test"]="com.example.hellodigitalis.unittest/com.example.hellodigitalis.unittest.MainActivity"
    ["vectorization"]="com.android.ndk.samples.vectorization/com.android.ndk.samples.vectorization.VectorizationActivity"
    ["orderfile"]="com.example.hellodigitalis.orderfile/com.example.hellodigitalis.orderfile.MainActivity"
    ["hello-gles1"]="com.example.hellodigitalis.hellogles1/com.example.hellogles1.MainActivity"
    ["hello-gles3"]="com.example.hellodigitalis.hellogles3/com.example.hellogles3.MainActivity"
    ["hello-msaa"]="com.example.hellodigitalis.hellomsaa/com.example.hellomsaa.MainActivity"
    ["hello-ijkplayer"]="com.example.hellodigitalis.helloijkplayer/com.example.helloijkplayer.MainActivity"
    ["hello-opencv"]="com.example.hellodigitalis.helloopencv/com.example.helloopencv.MainActivity"
    ["hello-sqlcipher"]="com.example.hellodigitalis.hellosqlcipher/com.example.hellosqlcipher.MainActivity"
    ["hello-conscrypt"]="com.example.hellodigitalis.helloconscrypt/com.example.helloconscrypt.MainActivity"
    ["hello-graphics-path"]="com.example.hellodigitalis.hellographicspath/com.example.hellographicspath.MainActivity"
    ["hello-gif"]="com.example.hellodigitalis.hellogif/com.example.hellogif.MainActivity"
    ["hello-zxing"]="com.example.hellodigitalis.hellozxing/com.example.hellozxing.MainActivity"
    ["hello-quickjs"]="com.example.hellodigitalis.helloquickjs/com.example.helloquickjs.MainActivity"
    ["hello-lynx"]="com.example.hellodigitalis.hellolynx/com.example.hellolynx.MainActivity"
    ["hello-mmkv"]="com.example.hellodigitalis.hellommkv/com.example.hellommkv.MainActivity"
    ["hello-aaudio"]="com.example.hellodigitalis.helloaaudio/com.example.helloaaudio.MainActivity"
    ["hello-binder-ndk"]="com.example.hellodigitalis.hellobinderndk/com.example.hellobinderndk.MainActivity"
    ["hello-nnapi"]="com.example.hellodigitalis.hellonnapi/com.example.hellonnapi.MainActivity"
    ["hello-fp-vector"]="com.example.hellodigitalis.hellofpvector/com.example.hellofpvector.MainActivity"
    ["hello-widemul"]="com.example.hellodigitalis.hellowidemul/com.example.hellowidemul.MainActivity"
    ["hello-pac-ret"]="com.example.hellodigitalis.hellopacret/com.example.hellopacret.MainActivity"
    ["hello-lse"]="com.example.hellodigitalis.hellolse/com.example.hellolse.MainActivity"
    ["hello-libc-libm"]="com.example.hellodigitalis.hellolibclibm/com.example.hellolibclibm.MainActivity"
    ["hello-lrcpc"]="com.example.hellodigitalis.hellolrcpc/com.example.hellolrcpc.MainActivity"
    ["hello-jscvt"]="com.example.hellodigitalis.hellojscvt/com.example.hellojscvt.MainActivity"
    ["hello-fp16"]="com.example.hellodigitalis.hellofp16/com.example.hellofp16.MainActivity"
    ["hello-dotprod"]="com.example.hellodigitalis.hellodotprod/com.example.hellodotprod.MainActivity"
    ["hello-complex"]="com.example.hellodigitalis.hellocomplex/com.example.hellocomplex.MainActivity"
    ["hello-bti"]="com.example.hellodigitalis.hellobti/com.example.hellobti.MainActivity"
    ["hello-bf16"]="com.example.hellodigitalis.hellobf16/com.example.hellobf16.MainActivity"
    ["hello-barriers"]="com.example.hellodigitalis.hellobarriers/com.example.hellobarriers.MainActivity"
    ["hello-neon"]="com.example.hellodigitalis.helloneon/com.example.helloneon.MainActivity"
    ["hello-sha-crypto"]="com.example.hellodigitalis.hellosha/com.example.hellosha.MainActivity"
    ["hello-ld-interleave"]="com.example.hellodigitalis.helloldinterleave/com.example.helloldinterleave.MainActivity"
    ["hello-superpack-regress"]="com.example.hellodigitalis.hellosuperpackregress/com.example.hellosuperpackregress.MainActivity"
    ["hello-reactnative"]="com.example.hellodigitalis.helloreactnative/com.example.helloreactnative.MainActivity"
    ["hello-qt"]="com.example.hellodigitalis.helloqt/org.qtproject.qt.android.bindings.QtActivity"
)

# Test package names (applicationId + ".test")
declare -A TEST_PACKAGES=(
    ["hello-vulkan"]="com.example.hellodigitalis.test"
    ["hello-jni"]="com.example.hellodigitalis.hellojni.test"
    ["hello-jniCallback"]="com.example.hellodigitalis.hellojnicallback.test"
    ["exceptions"]="com.example.hellodigitalis.exceptions.test"
    ["bitmap-plasma"]="com.example.hellodigitalis.plasma.test"
    ["hello-gl2"]="com.example.hellodigitalis.gl2jni.test"
    ["gles3jni"]="com.example.hellodigitalis.gles3jni.test"
    ["native-activity"]="com.example.hellodigitalis.nativeactivity.test"
    ["native-audio"]="com.example.hellodigitalis.nativeaudio.test"
    ["native-codec"]="com.example.hellodigitalis.nativecodec.test"
    ["native-midi"]="com.example.hellodigitalis.nativemidi.test"
    ["sensor-graph"]="com.example.hellodigitalis.sensorgraph.test"
    ["camera-basic"]="com.example.hellodigitalis.camerabasic.test"
    ["camera-texture-view"]="com.example.hellodigitalis.cameratextureview.test"
    ["teapots-classic"]="com.example.hellodigitalis.teapotsclassic.test"
    ["teapots-more"]="com.example.hellodigitalis.teapotsmore.test"
    ["teapots-textured"]="com.example.hellodigitalis.teapotstextured.test"
    ["endless-tunnel"]="com.example.hellodigitalis.endlesstunnel.test"
    ["sanitizers"]="com.example.hellodigitalis.sanitizers.test"
    ["unit-test"]="com.example.hellodigitalis.unittest.test"
    ["vectorization"]="com.android.ndk.samples.vectorization.test"
    ["orderfile"]="com.example.hellodigitalis.orderfile.test"
    ["hello-gles1"]="com.example.hellodigitalis.hellogles1.test"
    ["hello-gles3"]="com.example.hellodigitalis.hellogles3.test"
    ["hello-msaa"]="com.example.hellodigitalis.hellomsaa.test"
    ["hello-ijkplayer"]="com.example.hellodigitalis.helloijkplayer.test"
    ["hello-opencv"]="com.example.hellodigitalis.helloopencv.test"
    ["hello-sqlcipher"]="com.example.hellodigitalis.hellosqlcipher.test"
    ["hello-conscrypt"]="com.example.hellodigitalis.helloconscrypt.test"
    ["hello-graphics-path"]="com.example.hellodigitalis.hellographicspath.test"
    ["hello-gif"]="com.example.hellodigitalis.hellogif.test"
    ["hello-zxing"]="com.example.hellodigitalis.hellozxing.test"
    ["hello-quickjs"]="com.example.hellodigitalis.helloquickjs.test"
    ["hello-lynx"]="com.example.hellodigitalis.hellolynx.test"
    ["hello-mmkv"]="com.example.hellodigitalis.hellommkv.test"
    ["hello-aaudio"]="com.example.hellodigitalis.helloaaudio.test"
    ["hello-binder-ndk"]="com.example.hellodigitalis.hellobinderndk.test"
    ["hello-nnapi"]="com.example.hellodigitalis.hellonnapi.test"
    ["hello-fp-vector"]="com.example.hellodigitalis.hellofpvector.test"
    ["hello-widemul"]="com.example.hellodigitalis.hellowidemul.test"
    ["hello-pac-ret"]="com.example.hellodigitalis.hellopacret.test"
    ["hello-lse"]="com.example.hellodigitalis.hellolse.test"
    ["hello-libc-libm"]="com.example.hellodigitalis.hellolibclibm.test"
    ["hello-lrcpc"]="com.example.hellodigitalis.hellolrcpc.test"
    ["hello-jscvt"]="com.example.hellodigitalis.hellojscvt.test"
    ["hello-fp16"]="com.example.hellodigitalis.hellofp16.test"
    ["hello-dotprod"]="com.example.hellodigitalis.hellodotprod.test"
    ["hello-complex"]="com.example.hellodigitalis.hellocomplex.test"
    ["hello-bti"]="com.example.hellodigitalis.hellobti.test"
    ["hello-bf16"]="com.example.hellodigitalis.hellobf16.test"
    ["hello-barriers"]="com.example.hellodigitalis.hellobarriers.test"
    ["hello-neon"]="com.example.hellodigitalis.helloneon.test"
    ["hello-sha-crypto"]="com.example.hellodigitalis.hellosha.test"
    ["hello-ld-interleave"]="com.example.hellodigitalis.helloldinterleave.test"
    ["hello-superpack-regress"]="com.example.hellodigitalis.hellosuperpackregress.test"
    ["hello-reactnative"]="com.example.hellodigitalis.helloreactnative.test"
)

# Fully qualified test class names
declare -A TEST_CLASSES=(
    ["hello-vulkan"]="com.example.hellodigitalis.ScreenshotTest"
    ["hello-jni"]="com.example.hellodigitalis.hellojni.StatusTest"
    ["hello-jniCallback"]="com.example.hellodigitalis.hellojnicallback.StatusTest"
    ["exceptions"]="com.example.hellodigitalis.exceptions.StatusTest"
    ["bitmap-plasma"]="com.example.hellodigitalis.plasma.StatusTest"
    ["hello-gl2"]="com.example.hellodigitalis.gl2jni.ScreenshotTest"
    ["gles3jni"]="com.example.hellodigitalis.gles3jni.ScreenshotTest"
    ["native-activity"]="com.example.hellodigitalis.nativeactivity.ScreenshotTest"
    ["native-audio"]="com.example.hellodigitalis.nativeaudio.StatusTest"
    ["native-codec"]="com.example.hellodigitalis.nativecodec.StatusTest"
    ["native-midi"]="com.example.hellodigitalis.nativemidi.StatusTest"
    ["sensor-graph"]="com.example.hellodigitalis.sensorgraph.StatusTest"
    ["camera-basic"]="com.example.hellodigitalis.camerabasic.StatusTest"
    ["camera-texture-view"]="com.example.hellodigitalis.cameratextureview.StatusTest"
    ["teapots-classic"]="com.example.hellodigitalis.teapotsclassic.ScreenshotTest"
    ["teapots-more"]="com.example.hellodigitalis.teapotsmore.ScreenshotTest"
    ["teapots-textured"]="com.example.hellodigitalis.teapotstextured.ScreenshotTest"
    ["endless-tunnel"]="com.example.hellodigitalis.endlesstunnel.ScreenshotTest"
    ["sanitizers"]="com.example.hellodigitalis.sanitizers.StatusTest"
    ["unit-test"]="com.example.hellodigitalis.unittest.StatusTest"
    ["vectorization"]="com.android.ndk.samples.vectorization.StatusTest"
    ["orderfile"]="com.example.hellodigitalis.orderfile.StatusTest"
    ["hello-gles1"]="com.example.hellodigitalis.hellogles1.ScreenshotTest"
    ["hello-gles3"]="com.example.hellodigitalis.hellogles3.ScreenshotTest"
    ["hello-msaa"]="com.example.hellodigitalis.hellomsaa.ScreenshotTest"
    ["hello-ijkplayer"]="com.example.hellodigitalis.helloijkplayer.StatusTest"
    ["hello-opencv"]="com.example.hellodigitalis.helloopencv.StatusTest"
    ["hello-sqlcipher"]="com.example.hellodigitalis.hellosqlcipher.StatusTest"
    ["hello-conscrypt"]="com.example.hellodigitalis.helloconscrypt.StatusTest"
    ["hello-graphics-path"]="com.example.hellodigitalis.hellographicspath.StatusTest"
    ["hello-gif"]="com.example.hellodigitalis.hellogif.StatusTest"
    ["hello-zxing"]="com.example.hellodigitalis.hellozxing.StatusTest"
    ["hello-quickjs"]="com.example.hellodigitalis.helloquickjs.StatusTest"
    ["hello-lynx"]="com.example.hellodigitalis.hellolynx.ScreenshotTest"
    ["hello-mmkv"]="com.example.hellodigitalis.hellommkv.StatusTest"
    ["hello-aaudio"]="com.example.hellodigitalis.helloaaudio.StatusTest"
    ["hello-binder-ndk"]="com.example.hellodigitalis.hellobinderndk.StatusTest"
    ["hello-nnapi"]="com.example.hellodigitalis.hellonnapi.StatusTest"
    ["hello-fp-vector"]="com.example.hellodigitalis.hellofpvector.StatusTest"
    ["hello-widemul"]="com.example.hellodigitalis.hellowidemul.StatusTest"
    ["hello-pac-ret"]="com.example.hellodigitalis.hellopacret.StatusTest"
    ["hello-lse"]="com.example.hellodigitalis.hellolse.StatusTest"
    ["hello-libc-libm"]="com.example.hellodigitalis.hellolibclibm.StatusTest"
    ["hello-lrcpc"]="com.example.hellodigitalis.hellolrcpc.StatusTest"
    ["hello-jscvt"]="com.example.hellodigitalis.hellojscvt.StatusTest"
    ["hello-fp16"]="com.example.hellodigitalis.hellofp16.StatusTest"
    ["hello-dotprod"]="com.example.hellodigitalis.hellodotprod.StatusTest"
    ["hello-complex"]="com.example.hellodigitalis.hellocomplex.StatusTest"
    ["hello-bti"]="com.example.hellodigitalis.hellobti.StatusTest"
    ["hello-bf16"]="com.example.hellodigitalis.hellobf16.StatusTest"
    ["hello-barriers"]="com.example.hellodigitalis.hellobarriers.StatusTest"
    ["hello-neon"]="com.example.hellodigitalis.helloneon.StatusTest"
    ["hello-sha-crypto"]="com.example.hellodigitalis.hellosha.StatusTest"
    ["hello-ld-interleave"]="com.example.hellodigitalis.helloldinterleave.StatusTest"
    ["hello-superpack-regress"]="com.example.hellodigitalis.hellosuperpackregress.StatusTest"
    ["hello-reactnative"]="com.example.hellodigitalis.helloreactnative.ScreenshotTest"
)

# Ordered list for consistent output
MODULE_ORDER=(
    hello-vulkan hello-jni hello-jniCallback exceptions bitmap-plasma
    hello-gl2 gles3jni native-activity native-audio native-codec
    native-midi sensor-graph camera-basic camera-texture-view
    teapots-classic teapots-more teapots-textured endless-tunnel
    sanitizers unit-test vectorization orderfile
    hello-gles1 hello-gles3 hello-msaa hello-ijkplayer hello-opencv hello-sqlcipher hello-conscrypt hello-graphics-path hello-gif hello-zxing hello-quickjs hello-lynx hello-aaudio hello-binder-ndk hello-nnapi
    hello-fp-vector hello-neon hello-sha-crypto hello-ld-interleave hello-superpack-regress
    hello-barriers hello-bf16 hello-bti hello-complex hello-dotprod
    hello-fp16 hello-jscvt hello-libc-libm hello-mmkv hello-lrcpc hello-lse hello-pac-ret hello-widemul
    hello-reactnative hello-qt
)

# Check emulator
if ! adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | grep -q "1"; then
    echo "ERROR: Emulator not booted. Boot it first."
    exit 1
fi

pass=0
crash=0
total=0

# For screenshot/update-references modes:
# - Hide status bar to avoid clock/battery changes
# - Suppress "Viewing full screen" confirmation dialog (steals focus from NativeActivity apps)
if [[ "$MODE" == "screenshots" || "$MODE" == "status" || "$MODE" == "update-references" ]]; then
    adb shell settings put global policy_control immersive.status=* 2>/dev/null
    adb shell settings put secure immersive_mode_confirmations confirmed 2>/dev/null

    # region digitalis - auto-build missing androidTest APKs.
    # The instrumentation modes require per-module androidTest APKs; without
    # them the per-module loop just SKIPs the module ("no test APK"). Scan the
    # mode-relevant, filter-selected module set up-front, collect any missing
    # androidTest APKs, and build them in one batched gradlew invocation. This
    # lets a fresh checkout / clean build tree run end-to-end without a manual
    # gradle step.
    missing_test_tasks=()
    for mod in "${MODULE_ORDER[@]}"; do
        if [[ -n "$FILTER" && "$mod" != "$FILTER" ]]; then continue; fi
        # Only consider modules whose test class matches the current mode.
        # `:-` tolerates modules in MODULE_ORDER with no TEST_CLASSES entry (e.g.
        # hello-qt, which is liveness-only / built standalone) under `set -u`.
        if [[ -n "$TEST_SUFFIX" && "${TEST_CLASSES[$mod]:-}" != *"$TEST_SUFFIX" ]]; then continue; fi
        test_apk="${SAMPLE_DIR}/${mod}/build/outputs/apk/androidTest/debug/${mod}-debug-androidTest.apk"
        if [[ ! -f "$test_apk" ]]; then
            missing_test_tasks+=(":${mod}:assembleAndroidTest")
        fi
    done
    if [[ ${#missing_test_tasks[@]} -gt 0 ]]; then
        echo "  Building ${#missing_test_tasks[@]} missing androidTest APK(s) via gradle..."
        if ! (cd "${SAMPLE_DIR}" && ./gradlew "${missing_test_tasks[@]}" >/tmp/test-samples-gradle.log 2>&1); then
            echo "  WARN: gradle androidTest build failed (see /tmp/test-samples-gradle.log); per-module SKIPs may still occur"
        fi
    fi
    # endregion
fi

if [[ "$MODE" == "liveness" ]]; then

echo "═══════════════════════════════════════════════"
echo "  Digitalis Sample Module Test (Liveness)"
echo "═══════════════════════════════════════════════"
echo ""

for mod in "${MODULE_ORDER[@]}"; do
    # Filter to single module if specified
    if [[ -n "$FILTER" && "$mod" != "$FILTER" ]]; then
        continue
    fi

    comp="${MODULES[$mod]}"
    pkg="${comp%%/*}"
    total=$((total + 1))

    # Install APK
    apk="${SAMPLE_DIR}/${mod}/build/outputs/apk/debug/${mod}-debug.apk"
    # Fallback: Qt-built samples (hello-qt) ship a prebuilt APK in the module
    # root instead of the gradle outputs tree.
    if [[ ! -f "$apk" && -f "${SAMPLE_DIR}/${mod}/${mod}-debug.apk" ]]; then
        apk="${SAMPLE_DIR}/${mod}/${mod}-debug.apk"
    fi
    if [[ ! -f "$apk" ]]; then
        echo "  SKIP: $mod (no APK — run ./gradlew :${mod}:assembleDebug first)"
        continue
    fi

    install_result=$(adb install -r "$apk" 2>&1)
    if ! echo "$install_result" | grep -q "Success"; then
        echo "  FAIL_INSTALL: $mod — $install_result"
        crash=$((crash + 1))
        continue
    fi

    # Grant runtime permissions if needed
    grant_permissions "$mod" "$pkg"

    # Clear logcat, launch, wait
    adb logcat -c 2>/dev/null
    adb shell am start -n "$comp" 2>/dev/null
    sleep "$WAIT_SECS"

    # Check process alive
    pid=$(adb shell pidof "$pkg" 2>/dev/null | tr -d '\r' || true)

    # Check for fatal signals
    crash_lines=$(adb logcat -d 2>/dev/null | grep -c "SIGSEGV\|SIGABRT\|SIGILL\|Fatal signal" || true)

    # Collect JIT breaks (|| true: grep returns 1 when a module emits no JIT-break
    # lines, e.g. pure-Java/EGL samples, which under set -o pipefail would abort).
    jit_breaks=$(adb logcat -d 2>/dev/null | { grep "berberis.*JIT break" || true; } | tail -3)

    if [[ -n "$pid" && "$crash_lines" -eq 0 ]]; then
        echo "  PASS: $mod (pid=$pid)"
        pass=$((pass + 1))
    elif [[ -n "$pid" && "$crash_lines" -gt 0 ]]; then
        echo "  WARN: $mod (pid=$pid but $crash_lines crash signals)"
        crash=$((crash + 1))
        if [[ -n "$jit_breaks" ]]; then
            echo "$jit_breaks" | sed 's/^/    /'
        fi
    else
        echo "  CRASH: $mod"
        crash=$((crash + 1))
        # Show crash signal (|| true: grep returns 1 if no match, which under
        # set -o pipefail would abort the script when logcat got pruned).
        adb logcat -d 2>/dev/null | { grep -E "Fatal signal|SIGSEGV|SIGABRT|SIGILL" || true; } | tail -1 | sed 's/^/    /'
        # Show JIT breaks
        if [[ -n "$jit_breaks" ]]; then
            echo "$jit_breaks" | sed 's/^/    /'
        fi
    fi

    # Stop app
    adb shell am force-stop "$pkg" 2>/dev/null
    sleep 1
done

echo ""
echo "═══════════════════════════════════════════════"
echo "  Results: $pass PASS / $crash CRASH / $total total"
echo "═══════════════════════════════════════════════"

elif [[ "$MODE" == "screenshots" || "$MODE" == "status" ]]; then

if [[ "$MODE" == "screenshots" ]]; then MODE_LABEL="Screenshots (rendering modules)"; else MODE_LABEL="Status (non-rendering modules)"; fi
echo "═══════════════════════════════════════════════"
echo "  Digitalis Sample Module Test (${MODE_LABEL})"
echo "═══════════════════════════════════════════════"
echo ""

for mod in "${MODULE_ORDER[@]}"; do
    if [[ -n "$FILTER" && "$mod" != "$FILTER" ]]; then
        continue
    fi

    # Only run modules whose test class matches this mode (ScreenshotTest for
    # --screenshots, StatusTest for --status). Don't count skipped modules.
    # `:-` tolerates MODULE_ORDER modules with no TEST_CLASSES entry (liveness-only).
    if [[ "${TEST_CLASSES[$mod]:-}" != *"$TEST_SUFFIX" ]]; then
        continue
    fi

    total=$((total + 1))

    # Install app APK
    apk="${SAMPLE_DIR}/${mod}/build/outputs/apk/debug/${mod}-debug.apk"
    if [[ ! -f "$apk" ]]; then
        echo "  SKIP: $mod (no APK — run ./gradlew :${mod}:assembleDebug first)"
        continue
    fi

    install_result=$(adb install -r "$apk" 2>&1)
    if ! echo "$install_result" | grep -q "Success"; then
        echo "  FAIL_INSTALL: $mod — $install_result"
        crash=$((crash + 1))
        continue
    fi

    # Grant runtime permissions if needed
    comp="${MODULES[$mod]}"
    pkg="${comp%%/*}"
    grant_permissions "$mod" "$pkg"

    # Install test APK
    test_apk="${SAMPLE_DIR}/${mod}/build/outputs/apk/androidTest/debug/${mod}-debug-androidTest.apk"
    if [[ ! -f "$test_apk" ]]; then
        echo "  SKIP: $mod (no test APK — run ./gradlew :${mod}:assembleAndroidTest first)"
        continue
    fi

    test_install_result=$(adb install -r "$test_apk" 2>&1)
    if ! echo "$test_install_result" | grep -q "Success"; then
        echo "  FAIL_INSTALL_TEST: $mod — $test_install_result"
        crash=$((crash + 1))
        continue
    fi

    # region digitalis
    # Force-stop all other sample packages so the previous module's UI can't
    # leak into this module's `actual.png` (stale-foreground flake).
    force_stop_other_samples "$pkg"
    # endregion

    # Run instrumentation test
    # Use timeout because am instrument -w can hang when test process doesn't exit.
    # Clear logcat first so the timeout-fallback grep only matches this run's result, not a prior module's.
    adb logcat -c 2>/dev/null || true
    output=$(timeout 30 adb shell am instrument -w -e class "${TEST_CLASSES[$mod]}" "${TEST_PACKAGES[$mod]}/androidx.test.runner.AndroidJUnitRunner" 2>&1 || true)

    # Check for pass: "OK (1 test)" in output, or "run finished: 1 tests, 0 failed" in logcat (timeout case).
    # The per-test "finished:" line is logged regardless of pass/fail — only the "run finished:" summary
    # contains the actual failure count, so it's the only safe signal for the timeout fallback path.
    if echo "$output" | grep -q "OK (1 test)"; then
        echo "  PASS: $mod"
        pass=$((pass + 1))
    elif adb logcat -d 2>/dev/null | grep -q "TestRunner: run finished: 1 tests, 0 failed"; then
        echo "  PASS: $mod (completed, am instrument timed out)"
        pass=$((pass + 1))
    else
        echo "  FAIL: $mod"
        crash=$((crash + 1))
        # Surface the actual assertion failure if logcat has it
        fail_msg=$(adb logcat -d 2>/dev/null | grep -E "AssertionError|Screenshot mismatch|run finished:" | tail -3)
        if [[ -n "$fail_msg" ]]; then
            echo "$fail_msg" | sed 's/^/    /'
        else
            echo "$output" | sed 's/^/    /'
        fi
    fi

    # Cleanup between modules
    adb shell am force-stop "$pkg" 2>/dev/null || true
    sleep 1
done

echo ""
echo "═══════════════════════════════════════════════"
echo "  Results: $pass PASS / $crash FAIL / $total total"
echo "═══════════════════════════════════════════════"

elif [[ "$MODE" == "update-references" ]]; then

echo "═══════════════════════════════════════════════"
echo "  Digitalis Sample Module Test (Update References)"
echo "═══════════════════════════════════════════════"
echo ""

for mod in "${MODULE_ORDER[@]}"; do
    if [[ -n "$FILTER" && "$mod" != "$FILTER" ]]; then
        continue
    fi

    # Status-test modules (non-rendering: compute/status/callback) have no
    # screenshot reference image, so there's nothing to update for them.
    if [[ "${TEST_CLASSES[$mod]}" == *.StatusTest ]]; then
        echo "  SKIP: $mod (status test — no screenshot reference)"
        continue
    fi

    total=$((total + 1))

    # Install app APK
    apk="${SAMPLE_DIR}/${mod}/build/outputs/apk/debug/${mod}-debug.apk"
    if [[ ! -f "$apk" ]]; then
        echo "  SKIP: $mod (no APK — run ./gradlew :${mod}:assembleDebug first)"
        continue
    fi

    install_result=$(adb install -r "$apk" 2>&1)
    if ! echo "$install_result" | grep -q "Success"; then
        echo "  FAIL_INSTALL: $mod — $install_result"
        crash=$((crash + 1))
        continue
    fi

    # Grant runtime permissions if needed
    comp="${MODULES[$mod]}"
    pkg="${comp%%/*}"
    grant_permissions "$mod" "$pkg"

    # Install test APK
    test_apk="${SAMPLE_DIR}/${mod}/build/outputs/apk/androidTest/debug/${mod}-debug-androidTest.apk"
    if [[ ! -f "$test_apk" ]]; then
        echo "  SKIP: $mod (no test APK — run ./gradlew :${mod}:assembleAndroidTest first)"
        continue
    fi

    test_install_result=$(adb install -r "$test_apk" 2>&1)
    if ! echo "$test_install_result" | grep -q "Success"; then
        echo "  FAIL_INSTALL_TEST: $mod — $test_install_result"
        crash=$((crash + 1))
        continue
    fi

    # region digitalis
    # Force-stop all other sample packages so the previous module's UI can't
    # leak into this module's reference capture (stale-foreground flake).
    force_stop_other_samples "$pkg"
    # endregion

    # Run instrumentation test with updateReferences=true
    # Use timeout because am instrument -w can hang when test process doesn't exit
    output=$(timeout 30 adb shell am instrument -w -e updateReferences true -e class "${TEST_CLASSES[$mod]}" "${TEST_PACKAGES[$mod]}/androidx.test.runner.AndroidJUnitRunner" 2>&1 || true)

    # Pull reference image from the app's data dir (adb root required)
    dest_dir="${SAMPLE_DIR}/${mod}/src/androidTest/assets/reference"
    mkdir -p "$dest_dir"
    pull_result=$(adb pull "/data/data/${pkg}/files/references/screenshot_default.png" "${dest_dir}/screenshot_default.png" 2>&1)

    if echo "$pull_result" | grep -q "pulled\|bytes\|file pulled"; then
        echo "  UPDATED: $mod"
        pass=$((pass + 1))
    else
        echo "  FAIL: $mod — $pull_result"
        crash=$((crash + 1))
    fi

    # Cleanup between modules
    adb shell am force-stop "$pkg" 2>/dev/null || true
    sleep 1
done

echo ""
echo "═══════════════════════════════════════════════"
echo "  Results: $pass updated / $crash failed / $total total"
echo "═══════════════════════════════════════════════"
echo ""
echo "Reference images updated. Review and commit with git add."

fi

# Restore status bar if we hid it
if [[ "$MODE" == "screenshots" || "$MODE" == "status" || "$MODE" == "update-references" ]]; then
    adb shell settings put global policy_control null 2>/dev/null
fi
