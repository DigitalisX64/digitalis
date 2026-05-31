# Proxy-library symbol coverage gaps (`DoBadTrampoline`)

A proxy library forwards each guest `lib*.so` symbol to the host. The trampoline
table (`native_bridge_support/android_api/<lib>/proxy/trampolines_arm64_to_x86_64-inl.h`,
generated, read-only) marks a symbol `DoBadTrampoline` when the auto-generator
deemed its signature incompatible and no upstream custom trampoline exists.
Calling such a symbol aborts with `LOG_ALWAYS_FATAL("Bad '<sym>' call")`.

Digitalis covers these **in-surface** from
`binary_translation/android_api/digitalis_extra_proxy/` via
`ProxyLibraryBuilder::RegisterExtraTrampolines` (the override is enabled by the
arm64-guarded `InterceptSymbol` tweak in `proxy_loader/proxy_library_builder.cc`).

## Accurate scope (arm64 table only)

Earlier headline counts were ~3x inflated because they summed the arm64 + arm +
riscv64 tables. The real **arm64** `DoBadTrampoline` counts, split by whether the
symbol is a public NDK C API or an internal C++ implementation symbol:

| Library | arm64 gaps | internal C++ (skip) | public C API (in scope) |
|---|---|---|---|
| libEGL | 8 | 8 | 0 |
| libGLESv2 | 1 | 0 | 1 |
| libGLESv3 | 1 | 0 | 1 |
| libnativewindow | 1 | 0 | 1 |
| libandroid | 0 | 0 | 0 |
| libbinder_ndk | 3 | 1 | 2 |
| libcamera2ndk | 2 | 0 | 2 |
| libnativehelper | 31 | ~17 (JniConstants_*/JniInvocation*) | 13 (11 covered, 2 hard) |
| libwebviewchromium_plat_support | 18 | 17 | 1 |
| libandroid_runtime | ~1246 | ~all | n/a (framework-internal) |

## 1. Internal C++ symbols — NOT NDK-stable, out of scope (do not cover)

Mangled `_ZN7android...` symbols are libraries' own implementation classes, never
called directly by NDK apps (only by the library's own code, which runs host-side
behind the public C API). Covering them is pointless.
- **libEGL (8):** `android::egl_display_t::{makeCurrent,loseCurrent,loseCurrentImpl,addObject,removeObject,getObject}`, `android::egl_get_connection`, `android::setGlThreadSpecific`. The public EGL C API (`eglMakeCurrent`, …) is already covered.
- **libwebviewchromium_plat_support (17):** internal `android::` GraphicBuffer/AwDrawGLFunctor glue.
- **libbinder_ndk (1):** one internal `android::` symbol.
- **libnativehelper (~17):** `JniConstants_*` (class/field-id caches for FileDescriptor/NIOAccess/NioBuffer), `JniInvocationCreate/Destroy/Init` (JNI-invocation interface for runtime launchers like `app_process`, not NDK apps), `EnsureInitialized`. These are exported but not in `<nativehelper/JNIHelp.h>`; NDK apps never call them directly.
- **libandroid_runtime (~all):** framework runtime internals; not NDK-stable.

## 2. Public C API gaps — in scope

### Tractable (JNIEnv* translation + pointer/int pass-through)
- **libnativehelper — COVERED (11):** `jniThrowException`, `jniThrowNullPointerException`, `jniThrowRuntimeException`, `jniThrowIOException`, `jniThrowErrnoException`, `jniLogException`, `jniCreateString`, `jniGetNioBufferFields`, `jniGetNioBufferPointer`, `jniGetNioBufferBaseArray`, `jniGetNioBufferBaseArrayOffset` — the public `<nativehelper/JNIHelp.h>` C API. Each takes a `JNIEnv*` first argument, which is NOT a plain pointer pass-through (the guest `JNIEnv` holds guest-callable function pointers); the custom trampolines in `digitalis_extra_proxy/digitalis_extra_libnativehelper_trampolines.cc` translate it with `ToHostJNIEnv` and forward the remaining flat args (`jclass`/`jobject`/`const char*`/`jint*` pass through verbatim under LP64). They appeared incompatible only because the API analysis didn't resolve the JNI types. The host function is reached via the dlsym'd `callee`, so libberberis_arm64.so gains no libnativehelper link dependency. Validated end-to-end by the hello-jni `[LIBNH-PROXY:PASS]` probe.
- **libbinder_ndk:** `AServiceManager_NotificationRegistration_delete` (opaque handle pointer).

### Hard — need a host→guest thunk or special marshalling (callback / varargs / fn-ptr return)
- **libGLESv2 / libGLESv3:** `glGetVkProcAddrNV` — returns a function pointer the guest then calls; the returned host pointer must be wrapped as a guest-callable trampoline. NVIDIA Vulkan-interop extension, rarely used.
- **libnativewindow:** `ANativeWindow_setPerformInterceptor` — takes an interceptor callback the host invokes; needs a thunk. Debug/interception hook, rare.
- **libbinder_ndk:** `AServiceManager_registerForServiceNotifications` — takes a notification callback; needs a thunk.
- **libcamera2ndk:** `ACameraCaptureSessionShared_startStreaming`, `ACameraCaptureSessionShared_logicalCamera_startStreaming` — callback/struct-by-value; need marshalling. Newer shared-camera API.
- **libnativehelper:** `jniThrowExceptionFmt` (varargs — needs `struct __va_list` marshalling), `jniRegisterNativeMethods` (array of `JNINativeMethod` containing guest function pointers — each must be thunked).

## Status

- Enabling override: **done** (`proxy_library_builder.cc`, arm64-guarded).
- libnativehelper: **done** — 11 public `<JNIHelp.h>` C-API symbols covered in
  `digitalis_extra_libnativehelper_trampolines.cc` (JNIEnv translation via
  `ToHostJNIEnv`); validated by the hello-jni `[LIBNH-PROXY:PASS]` probe. Only
  `jniThrowExceptionFmt` (varargs) and `jniRegisterNativeMethods` (guest fn-ptr
  array) remain, both genuinely hard.
- Other tractable public-C-API gaps: covered in `digitalis_extra_proxy/` per library (see commits).
- Hard (callback/varargs/fn-ptr) gaps: require host→guest thunk marshalling
  (mirroring `egl_trampolines.cc`'s `DoCustomTrampolineWithThunk`); deferred unless
  a real app is observed calling one. Most are rare extensions or
  rarely-guest-linked.
- Internal C++ and `libandroid_runtime`: out of scope (not NDK-stable).
