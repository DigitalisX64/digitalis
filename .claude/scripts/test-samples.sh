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
    ["hello-sqlite-bundled"]="com.example.hellodigitalis.hellosqlitebundled/com.example.hellosqlitebundled.MainActivity"
    ["hello-tflite"]="com.example.hellodigitalis.hellotflite/com.example.hellotflite.MainActivity"
    ["hello-litert-llm"]="com.example.hellodigitalis.hellolitertllm/com.example.hellolitertllm.MainActivity"
    ["hello-libpag"]="com.example.hellodigitalis.hellolibpag/com.example.hellolibpag.MainActivity"
    ["hello-zstd"]="com.example.hellodigitalis.hellozstd/com.example.hellozstd.MainActivity"
    ["hello-libvlc"]="com.example.hellodigitalis.hellolibvlc/com.example.hellolibvlc.MainActivity"
    ["hello-ink"]="com.example.hellodigitalis.helloink/com.example.helloink.MainActivity"
    ["hello-appsearch"]="com.example.hellodigitalis.helloappsearch/com.example.helloappsearch.MainActivity"
    ["hello-libsignal"]="com.example.hellodigitalis.hellolibsignal/com.example.hellolibsignal.MainActivity"
    ["hello-fresco"]="com.example.hellodigitalis.hellofresco/com.example.hellofresco.MainActivity"
    ["hello-objectbox"]="com.example.hellodigitalis.helloobjectbox/com.example.helloobjectbox.MainActivity"
    ["hello-pdfium"]="com.example.hellodigitalis.hellopdfium/com.example.hellopdfium.MainActivity"
    ["hello-tracing-perfetto"]="com.example.hellodigitalis.hellotracingperfetto/com.example.hellotracingperfetto.MainActivity"
    ["hello-renderscript-toolkit"]="com.example.hellodigitalis.hellorenderscripttoolkit/com.example.hellorenderscripttoolkit.MainActivity"
    ["hello-pytorch"]="com.example.hellodigitalis.hellopytorch/com.example.hellopytorch.MainActivity"
    ["hello-gpuimage"]="com.example.hellodigitalis.hellogpuimage/com.example.hellogpuimage.MainActivity"
    ["hello-camera-core"]="com.example.hellodigitalis.hellocameracore/com.example.hellocameracore.MainActivity"
    ["hello-tesseract"]="com.example.hellodigitalis.hellotesseract/com.example.hellotesseract.MainActivity"
    ["hello-oboe"]="com.example.hellodigitalis.hellooboe/com.example.hellooboe.MainActivity"
    ["hello-ffmpeg-kit"]="com.example.hellodigitalis.helloffmpegkit/com.example.helloffmpegkit.MainActivity"
    ["hello-ncnn"]="com.example.hellodigitalis.helloncnn/com.example.helloncnn.MainActivity"
    ["hello-aes"]="com.example.hellodigitalis.helloaes/com.example.helloaes.MainActivity"
    ["hello-eglext"]="com.example.hellodigitalis.helloeglext/com.example.helloeglext.MainActivity"
    ["hello-fcsel"]="com.example.hellodigitalis.hellofcsel/com.example.hellofcsel.MainActivity"
    ["hello-fp16arith"]="com.example.hellodigitalis.hellofp16arith/com.example.hellofp16arith.MainActivity"
    ["hello-i8mm-bf16"]="com.example.hellodigitalis.helloi8mmbf16/com.example.helloi8mmbf16.MainActivity"
    ["hello-lsepair"]="com.example.hellodigitalis.hellolsepair/com.example.hellolsepair.MainActivity"
    ["hello-neonmisc"]="com.example.hellodigitalis.helloneonmisc/com.example.helloneonmisc.MainActivity"
    ["hello-fcma"]="com.example.hellodigitalis.hellofcma/com.example.hellofcma.MainActivity"
    ["hello-lseatomics"]="com.example.hellodigitalis.hellolseatomics/com.example.hellolseatomics.MainActivity"
    ["hello-fdsweep"]="com.example.hellodigitalis.hellofdsweep/com.example.hellofdsweep.MainActivity"
    ["hello-nativewindow"]="com.example.hellodigitalis.hellonativewindow/com.example.hellonativewindow.MainActivity"
    ["hello-vktexture"]="com.example.hellodigitalis.hellovktexture/com.example.hellovktexture.MainActivity"
    ["hello-cntvct"]="com.example.hellodigitalis.hellocntvct/com.example.hellocntvct.MainActivity"
    ["hello-cronet"]="com.example.hellodigitalis.hellocronet/com.example.hellocronet.MainActivity"
    ["hello-ldxp"]="com.example.hellodigitalis.helloldxp/com.example.helloldxp.MainActivity"
    ["hello-sigaction"]="com.example.hellodigitalis.hellosigaction/com.example.hellosigaction.MainActivity"
    ["hello-seccomp"]="com.example.hellodigitalis.helloseccomp/com.example.helloseccomp.MainActivity"
    ["hello-lynx"]="com.example.hellodigitalis.hellolynx/com.example.hellolynx.MainActivity"
    ["hello-mmkv"]="com.example.hellodigitalis.hellommkv/com.example.hellommkv.MainActivity"
    ["hello-aaudio"]="com.example.hellodigitalis.helloaaudio/com.example.helloaaudio.MainActivity"
    ["hello-binder-ndk"]="com.example.hellodigitalis.hellobinderndk/com.example.hellobinderndk.MainActivity"
    ["hello-jnihelp"]="com.example.hellodigitalis.hellojnihelp/com.example.hellojnihelp.MainActivity"
    ["hello-webview-functor"]="com.example.hellodigitalis.hellowebviewfunctor/com.example.hellowebviewfunctor.MainActivity"
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
    ["hello-glyphblit"]="com.example.hellodigitalis.helloglyphblit/com.example.helloglyphblit.MainActivity"
    ["hello-sha-crypto"]="com.example.hellodigitalis.hellosha/com.example.hellosha.MainActivity"
    ["hello-ld-interleave"]="com.example.hellodigitalis.helloldinterleave/com.example.helloldinterleave.MainActivity"
    ["hello-superpack-regress"]="com.example.hellodigitalis.hellosuperpackregress/com.example.hellosuperpackregress.MainActivity"
    ["hello-reactnative"]="com.example.hellodigitalis.helloreactnative/com.example.helloreactnative.MainActivity"
    ["hello-qt"]="com.example.hellodigitalis.helloqt/org.qtproject.qt.android.bindings.QtActivity"
    ["hello-onnxruntime"]="com.example.hellodigitalis.helloonnxruntime/com.example.helloonnxruntime.MainActivity"
    ["hello-jna"]="com.example.hellodigitalis.hellojna/com.example.hellojna.MainActivity"
    ["hello-libsodium"]="com.example.hellodigitalis.hellolibsodium/com.example.hellolibsodium.MainActivity"
    ["hello-j2v8"]="com.example.hellodigitalis.helloj2v8/com.example.helloj2v8.MainActivity"
    ["hello-couchbase"]="com.example.hellodigitalis.hellocouchbase/com.example.hellocouchbase.MainActivity"
    ["hello-avif"]="com.example.hellodigitalis.helloavif/com.example.helloavif.MainActivity"
    ["hello-themis"]="com.example.hellodigitalis.hellothemis/com.example.hellothemis.MainActivity"
    ["hello-wcdb"]="com.example.hellodigitalis.hellowcdb/com.example.hellowcdb.MainActivity"
    ["hello-vosk"]="com.example.hellodigitalis.hellovosk/com.example.hellovosk.MainActivity"
    ["hello-mediapipe"]="com.example.hellodigitalis.hellomediapipe/com.example.hellomediapipe.MainActivity"
    ["hello-rive"]="com.example.hellodigitalis.hellorive/com.example.hellorive.MainActivity"
    ["hello-argon2"]="com.example.hellodigitalis.helloargon2/com.example.helloargon2.MainActivity"
    ["hello-webrtc"]="com.example.hellodigitalis.hellowebrtc/com.example.hellowebrtc.MainActivity"
    ["hello-duktape"]="com.example.hellodigitalis.helloduktape/com.example.helloduktape.MainActivity"
    ["hello-wireguard"]="com.example.hellodigitalis.hellowireguard/com.example.hellowireguard.MainActivity"
    ["hello-fbjni"]="com.example.hellodigitalis.hellofbjni/com.example.hellofbjni.MainActivity"
    ["hello-libtorrent4j"]="com.example.hellodigitalis.hellolibtorrent4j/com.example.hellolibtorrent4j.MainActivity"
    ["hello-javacpp"]="com.example.hellodigitalis.hellojavacpp/com.example.hellojavacpp.MainActivity"
    ["hello-javet"]="com.example.hellodigitalis.hellojavet/com.example.hellojavet.MainActivity"
    ["hello-maplibre"]="com.example.hellodigitalis.hellomaplibre/com.example.hellomaplibre.MainActivity"
    ["hello-snappy"]="com.example.hellodigitalis.hellosnappy/com.example.hellosnappy.MainActivity"
    ["hello-libyuv"]="com.example.hellodigitalis.hellolibyuv/com.example.hellolibyuv.MainActivity"
    ["hello-secp256k1"]="com.example.hellodigitalis.hellosecp256k1/com.example.hellosecp256k1.MainActivity"
    ["hello-filament"]="com.example.hellodigitalis.hellofilament/com.example.hellofilament.MainActivity"
    ["hello-gltfio"]="com.example.hellodigitalis.hellogltfio/com.example.hellogltfio.MainActivity"
    ["hello-openblas"]="com.example.hellodigitalis.helloopenblas/com.example.helloopenblas.MainActivity"
    ["hello-fftw"]="com.example.hellodigitalis.hellofftw/com.example.hellofftw.MainActivity"
    ["hello-gsl"]="com.example.hellodigitalis.hellogsl/com.example.hellogsl.MainActivity"
    ["hello-leptonica"]="com.example.hellodigitalis.helloleptonica/com.example.helloleptonica.MainActivity"
    ["hello-box2d"]="com.example.hellodigitalis.hellobox2d/com.example.hellobox2d.MainActivity"
    ["hello-filament-render"]="com.example.hellodigitalis.hellofilamentrender/com.example.hellofilamentrender.MainActivity"
    ["hello-lua"]="com.example.hellodigitalis.hellolua/com.example.hellolua.MainActivity"
    ["hello-mupdf"]="com.example.hellodigitalis.hellomupdf/com.example.hellomupdf.MainActivity"
    ["hello-sentry-ndk"]="com.example.hellodigitalis.hellosentryndk/com.example.hellosentryndk.MainActivity"
    ["hello-bullet"]="com.example.hellodigitalis.hellobullet/com.example.hellobullet.MainActivity"
    ["hello-libwebp"]="com.example.hellodigitalis.hellolibwebp/com.example.hellolibwebp.MainActivity"
    ["hello-libarchive"]="com.example.hellodigitalis.hellolibarchive/com.example.hellolibarchive.MainActivity"
    ["hello-opus"]="com.example.hellodigitalis.helloopus/com.example.helloopus.MainActivity"
    ["hello-leveldb"]="com.example.hellodigitalis.helloleveldb/com.example.helloleveldb.MainActivity"
    ["hello-pcre2"]="com.example.hellodigitalis.hellopcre2/com.example.hellopcre2.MainActivity"
    ["hello-libxml2"]="com.example.hellodigitalis.hellolibxml2/com.example.hellolibxml2.MainActivity"
    ["hello-blowfish"]="com.example.hellodigitalis.helloblowfish/com.example.helloblowfish.MainActivity"
    ["hello-bcrypt"]="com.example.hellodigitalis.hellobcrypt/com.example.hellobcrypt.MainActivity"
    ["hello-hardwarebuffer"]="com.example.hellodigitalis.hellohardwarebuffer/com.example.hellohardwarebuffer.MainActivity"
    ["hello-imagedecoder"]="com.example.hellodigitalis.helloimagedecoder/com.example.helloimagedecoder.MainActivity"
    ["hello-mediandk-source"]="com.example.hellodigitalis.hellomediandksource/com.example.hellomediandksource.MainActivity"
    ["hello-adpf"]="com.example.hellodigitalis.helloadpf/com.example.helloadpf.MainActivity"
    ["hello-sharedmem"]="com.example.hellodigitalis.hellosharedmem/com.example.hellosharedmem.MainActivity"
    ["hello-fonts"]="com.example.hellodigitalis.hellofonts/com.example.hellofonts.MainActivity"
    ["hello-openmaxal"]="com.example.hellodigitalis.helloopenmaxal/com.example.helloopenmaxal.MainActivity"
    ["hello-opensles"]="com.example.hellodigitalis.helloopensles/com.example.helloopensles.MainActivity"
    ["hello-realm"]="com.example.hellodigitalis.hellorealm/com.example.hellorealm.MainActivity"
)

# Instrumentation targets are derived from MODULES: every module's test APK is
# <component package>.test and its test class is <component package>.StatusTest,
# except the rendering modules below (ScreenshotTest, pixel-compared against a
# committed reference image) and the standalone modules with no instrumentation
# (hello-qt builds outside the suite, so it has no status-test-lib test APK).
# Registering a new module therefore takes only a MODULES entry + MODULE_ORDER
# entry (+ a SCREENSHOT_MODULES entry if it renders).
SCREENSHOT_MODULES=(
    hello-vulkan hello-gl2 gles3jni native-activity
    teapots-classic teapots-more teapots-textured endless-tunnel
    hello-gles1 hello-gles3 hello-msaa hello-lynx hello-reactnative
    hello-filament-render
)
NO_INSTRUMENTATION_MODULES=(
    hello-qt
    hello-realm
)

declare -A TEST_PACKAGES TEST_CLASSES
for _mod in "${!MODULES[@]}"; do
    _pkg="${MODULES[$_mod]%%/*}"
    _skip=""
    for _m in "${NO_INSTRUMENTATION_MODULES[@]}"; do
        [[ "$_m" == "$_mod" ]] && _skip=1
    done
    [[ -n "$_skip" ]] && continue
    TEST_PACKAGES[$_mod]="${_pkg}.test"
    TEST_CLASSES[$_mod]="${_pkg}.StatusTest"
done
for _mod in "${SCREENSHOT_MODULES[@]}"; do
    _pkg="${MODULES[$_mod]%%/*}"
    TEST_CLASSES[$_mod]="${_pkg}.ScreenshotTest"
done
unset _mod _pkg _skip _m

# Ordered list for consistent output
MODULE_ORDER=(
    hello-vulkan hello-jni hello-jniCallback exceptions bitmap-plasma
    hello-gl2 gles3jni native-activity native-audio native-codec
    native-midi sensor-graph camera-basic camera-texture-view
    teapots-classic teapots-more teapots-textured endless-tunnel
    sanitizers unit-test vectorization orderfile
    hello-gles1 hello-gles3 hello-msaa hello-vktexture hello-ijkplayer hello-opencv hello-sqlcipher hello-conscrypt hello-graphics-path hello-gif hello-zxing hello-quickjs hello-sqlite-bundled hello-tflite hello-litert-llm hello-libpag hello-zstd hello-libvlc hello-ink hello-appsearch hello-libsignal hello-fresco hello-objectbox hello-pdfium hello-tracing-perfetto hello-renderscript-toolkit hello-pytorch hello-gpuimage hello-camera-core hello-tesseract hello-oboe hello-ffmpeg-kit hello-ncnn hello-lynx hello-aaudio hello-binder-ndk hello-jnihelp hello-webview-functor hello-nnapi
    hello-fp-vector hello-neon hello-glyphblit hello-sha-crypto hello-ld-interleave hello-superpack-regress
    hello-barriers hello-bf16 hello-bti hello-complex hello-dotprod
    hello-fp16 hello-jscvt hello-libc-libm hello-mmkv hello-lrcpc hello-lse hello-pac-ret hello-widemul hello-aes hello-eglext hello-fcma hello-fcsel hello-fp16arith hello-i8mm-bf16 hello-lseatomics hello-lsepair hello-neonmisc hello-cronet hello-ldxp hello-cntvct hello-sigaction hello-seccomp hello-fdsweep hello-nativewindow
    hello-onnxruntime hello-jna hello-libsodium hello-j2v8 hello-couchbase hello-avif hello-themis hello-wcdb hello-vosk hello-mediapipe hello-rive hello-argon2 hello-webrtc hello-duktape hello-wireguard hello-fbjni hello-libtorrent4j hello-javacpp hello-javet hello-maplibre hello-snappy
    hello-libyuv hello-secp256k1 hello-filament hello-gltfio hello-openblas hello-fftw hello-gsl hello-leptonica hello-box2d hello-filament-render
    hello-lua hello-mupdf hello-sentry-ndk hello-bullet
    hello-libwebp hello-libarchive hello-opus hello-leveldb hello-pcre2 hello-libxml2
    hello-blowfish hello-bcrypt
    hello-hardwarebuffer hello-imagedecoder hello-mediandk-source hello-adpf
    hello-sharedmem hello-fonts hello-openmaxal hello-opensles hello-realm
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
    # Standalone modules (their own settings.gradle.kts, outside the suite
    # build — e.g. a pinned-toolchain project) carry a build-apk.sh; build on
    # demand so a fresh tree still runs end-to-end.
    if [[ ! -f "$apk" && -x "${SAMPLE_DIR}/${mod}/build-apk.sh" ]]; then
        echo "  Building $mod standalone via build-apk.sh..."
        if ! "${SAMPLE_DIR}/${mod}/build-apk.sh" >/tmp/test-samples-${mod}-build.log 2>&1; then
            echo "  WARN: $mod standalone build failed (see /tmp/test-samples-${mod}-build.log)"
        fi
    fi
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

    # Check for fatal signals. Exclude the benign "libsigchain: Setting SIGSEGV
    # to SIG_DFL" line: the translator's fork-child signal reset emits it in any
    # app that forks (e.g. hello-fdsweep's pre-exec sweep child) while the app
    # stays alive — matching its "SIGSEGV" substring is a false positive.
    crash_lines=$(adb logcat -d 2>/dev/null | grep -v "libsigchain: Setting SIGSEGV to SIG_DFL" | grep -c "SIGSEGV\|SIGABRT\|SIGILL\|Fatal signal" || true)

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
        adb logcat -d 2>/dev/null | grep -v "libsigchain: Setting SIGSEGV to SIG_DFL" | { grep -E "Fatal signal|SIGSEGV|SIGABRT|SIGILL" || true; } | tail -1 | sed 's/^/    /'
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
