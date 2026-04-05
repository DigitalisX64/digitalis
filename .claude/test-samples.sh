#!/bin/bash
#
# test-samples.sh — Test hellodigitalis sample modules on the Digitalis emulator.
#
# Usage:
#   .claude/test-samples.sh              # Test all modules
#   .claude/test-samples.sh hello-vulkan  # Test a single module
#
# Requires: emulator booted, adb root, adb remount done.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SAMPLE_DIR="${WORK_DIR}/sample/hellodigitalis"

FILTER="${1:-}"
WAIT_SECS=5

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
    ["sensor-graph"]="com.example.hellodigitalis.sensorgraph/com.android.accelerometergraph.AccelerometerGraphActivity"
    ["camera-basic"]="com.example.hellodigitalis.camerabasic/com.sample.camera.basic.CameraActivity"
    ["camera-texture-view"]="com.example.hellodigitalis.cameratextureview/com.sample.textureview.ViewActivity"
    ["teapots-classic"]="com.example.hellodigitalis.teapotsclassic/android.app.NativeActivity"
    ["teapots-more"]="com.example.hellodigitalis.teapotsmore/android.app.NativeActivity"
    ["teapots-textured"]="com.example.hellodigitalis.teapotstextured/android.app.NativeActivity"
    ["endless-tunnel"]="com.example.hellodigitalis.endlesstunnel/android.app.NativeActivity"
    ["sanitizers"]="com.example.hellodigitalis.sanitizers/com.example.sanitizers.MainActivity"
    ["unit-test"]="com.example.hellodigitalis.unittest/com.example.unittest.MainActivity"
    ["vectorization"]="com.android.ndk.samples.vectorization/com.android.ndk.samples.vectorization.VectorizationActivity"
    ["orderfile"]="com.example.hellodigitalis.orderfile/com.example.orderfiledemo.MainActivity"
)

# Ordered list for consistent output
MODULE_ORDER=(
    hello-vulkan hello-jni hello-jniCallback exceptions bitmap-plasma
    hello-gl2 gles3jni native-activity native-audio native-codec
    native-midi sensor-graph camera-basic camera-texture-view
    teapots-classic teapots-more teapots-textured endless-tunnel
    sanitizers unit-test vectorization orderfile
)

# Check emulator
if ! adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | grep -q "1"; then
    echo "ERROR: Emulator not booted. Boot it first."
    exit 1
fi

pass=0
crash=0
total=0

echo "═══════════════════════════════════════════════"
echo "  Digitalis Sample Module Test"
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
