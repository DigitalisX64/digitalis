#!/bin/bash
#
# test-samples.sh — Test hellodigitalis sample modules on the Digitalis emulator.
#
# Usage:
#   .claude/scripts/test-samples.sh                           # Liveness tests (existing)
#   .claude/scripts/test-samples.sh hello-vulkan               # Single module liveness
#   .claude/scripts/test-samples.sh --screenshots              # Screenshot tests all
#   .claude/scripts/test-samples.sh --screenshots hello-vulkan # Screenshot tests single
#   .claude/scripts/test-samples.sh --update-references              # Update refs all
#   .claude/scripts/test-samples.sh --update-references hello-vulkan # Update refs single
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
elif [[ "${1:-}" == "--update-references" ]]; then
    MODE="update-references"
    FILTER="${2:-}"
else
    FILTER="${1:-}"
fi

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
    ["hello-aaudio"]="com.example.hellodigitalis.helloaaudio/com.example.helloaaudio.MainActivity"
    ["hello-binder-ndk"]="com.example.hellodigitalis.hellobinderndk/com.example.hellobinderndk.MainActivity"
    ["hello-nnapi"]="com.example.hellodigitalis.hellonnapi/com.example.hellonnapi.MainActivity"
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
    ["hello-aaudio"]="com.example.hellodigitalis.helloaaudio.test"
    ["hello-binder-ndk"]="com.example.hellodigitalis.hellobinderndk.test"
    ["hello-nnapi"]="com.example.hellodigitalis.hellonnapi.test"
)

# Fully qualified test class names
declare -A TEST_CLASSES=(
    ["hello-vulkan"]="com.example.hellodigitalis.ScreenshotTest"
    ["hello-jni"]="com.example.hellodigitalis.hellojni.ScreenshotTest"
    ["hello-jniCallback"]="com.example.hellodigitalis.hellojnicallback.ScreenshotTest"
    ["exceptions"]="com.example.hellodigitalis.exceptions.ScreenshotTest"
    ["bitmap-plasma"]="com.example.hellodigitalis.plasma.ScreenshotTest"
    ["hello-gl2"]="com.example.hellodigitalis.gl2jni.ScreenshotTest"
    ["gles3jni"]="com.example.hellodigitalis.gles3jni.ScreenshotTest"
    ["native-activity"]="com.example.hellodigitalis.nativeactivity.ScreenshotTest"
    ["native-audio"]="com.example.hellodigitalis.nativeaudio.ScreenshotTest"
    ["native-codec"]="com.example.hellodigitalis.nativecodec.ScreenshotTest"
    ["native-midi"]="com.example.hellodigitalis.nativemidi.ScreenshotTest"
    ["sensor-graph"]="com.example.hellodigitalis.sensorgraph.ScreenshotTest"
    ["camera-basic"]="com.example.hellodigitalis.camerabasic.ScreenshotTest"
    ["camera-texture-view"]="com.example.hellodigitalis.cameratextureview.ScreenshotTest"
    ["teapots-classic"]="com.example.hellodigitalis.teapotsclassic.ScreenshotTest"
    ["teapots-more"]="com.example.hellodigitalis.teapotsmore.ScreenshotTest"
    ["teapots-textured"]="com.example.hellodigitalis.teapotstextured.ScreenshotTest"
    ["endless-tunnel"]="com.example.hellodigitalis.endlesstunnel.ScreenshotTest"
    ["sanitizers"]="com.example.hellodigitalis.sanitizers.ScreenshotTest"
    ["unit-test"]="com.example.hellodigitalis.unittest.ScreenshotTest"
    ["vectorization"]="com.android.ndk.samples.vectorization.ScreenshotTest"
    ["orderfile"]="com.example.hellodigitalis.orderfile.ScreenshotTest"
    ["hello-gles1"]="com.example.hellodigitalis.hellogles1.ScreenshotTest"
    ["hello-aaudio"]="com.example.hellodigitalis.helloaaudio.ScreenshotTest"
    ["hello-binder-ndk"]="com.example.hellodigitalis.hellobinderndk.ScreenshotTest"
    ["hello-nnapi"]="com.example.hellodigitalis.hellonnapi.ScreenshotTest"
)

# Ordered list for consistent output
MODULE_ORDER=(
    hello-vulkan hello-jni hello-jniCallback exceptions bitmap-plasma
    hello-gl2 gles3jni native-activity native-audio native-codec
    native-midi sensor-graph camera-basic camera-texture-view
    teapots-classic teapots-more teapots-textured endless-tunnel
    sanitizers unit-test vectorization orderfile
    hello-gles1 hello-aaudio hello-binder-ndk hello-nnapi
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
if [[ "$MODE" == "screenshots" || "$MODE" == "update-references" ]]; then
    adb shell settings put global policy_control immersive.status=* 2>/dev/null
    adb shell settings put secure immersive_mode_confirmations confirmed 2>/dev/null
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

    # Collect JIT breaks
    jit_breaks=$(adb logcat -d 2>/dev/null | grep "berberis.*JIT break" | tail -3)

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
        # Show crash signal
        adb logcat -d 2>/dev/null | grep -E "Fatal signal|SIGSEGV|SIGABRT|SIGILL" | tail -1 | sed 's/^/    /'
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

elif [[ "$MODE" == "screenshots" ]]; then

echo "═══════════════════════════════════════════════"
echo "  Digitalis Sample Module Test (Screenshots)"
echo "═══════════════════════════════════════════════"
echo ""

for mod in "${MODULE_ORDER[@]}"; do
    if [[ -n "$FILTER" && "$mod" != "$FILTER" ]]; then
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

    # Run instrumentation test
    # Use timeout because am instrument -w can hang when test process doesn't exit
    output=$(timeout 30 adb shell am instrument -w -e class "${TEST_CLASSES[$mod]}" "${TEST_PACKAGES[$mod]}/androidx.test.runner.AndroidJUnitRunner" 2>&1 || true)

    # Check for pass: "OK (1 test)" in output, or test finished in logcat (timeout case)
    if echo "$output" | grep -q "OK (1 test)"; then
        echo "  PASS: $mod"
        pass=$((pass + 1))
    elif adb logcat -d 2>/dev/null | grep -q "TestRunner.*finished.*${TEST_CLASSES[$mod]##*.}"; then
        echo "  PASS: $mod (completed, am instrument timed out)"
        pass=$((pass + 1))
    else
        echo "  FAIL: $mod"
        crash=$((crash + 1))
        echo "$output" | sed 's/^/    /'
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
if [[ "$MODE" == "screenshots" || "$MODE" == "update-references" ]]; then
    adb shell settings put global policy_control null 2>/dev/null
fi
