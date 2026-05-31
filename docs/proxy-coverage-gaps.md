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
| libbinder_ndk | 3 | 1 | 2 (1 covered, 1 hard) |
| libcamera2ndk | 2 | 0 | 2 (both hard) |
| libnativehelper | 31 | ~17 (JniConstants_*/JniInvocation*) | 13 (11 covered, 2 hard) |
| libwebviewchromium_plat_support | 18 | 17 | 1 (hard/deferred) |
| libandroid_runtime | ~1246 | ~all | n/a (framework-internal) |

**Net actionable result:** every tractable NDK-stable public-C-API
`DoBadTrampoline` symbol is now covered (libnativehelper ×11, libbinder_ndk ×1).
Everything still uncovered is either an internal C++ implementation symbol (not
NDK-stable) or a genuinely hard callback / varargs / fn-ptr-return / C++-return
case enumerated below, deferred until a real app is observed needing it — never
covered with guessed marshalling.

## 1. Internal C++ symbols — NOT NDK-stable, out of scope (do not cover)

Mangled `_ZN7android...` symbols are libraries' own implementation classes, never
called directly by NDK apps (only by the library's own code, which runs host-side
behind the public C API). Covering them is pointless.
- **libEGL (8):** `android::egl_display_t::{makeCurrent,loseCurrent,loseCurrentImpl,addObject,removeObject,getObject}`, `android::egl_get_connection`, `android::setGlThreadSpecific`. The public EGL C API (`eglMakeCurrent`, …) is already covered.
- **libwebviewchromium_plat_support (17):** internal `android::` GraphicBuffer/AwDrawGLFunctor glue (`GraphicBufferImpl::*`, `RegisterDrawFunctor`, `RegisterDrawGLFunctor`, `RegisterGraphicsUtils`, `RaiseFileNumberLimit`).
- **libbinder_ndk (1):** `_Z25AIBinder_toPlatformBinderP8AIBinder` — `AIBinder_toPlatformBinder(AIBinder*)` returns a C++ `android::sp<IBinder>` by value (no resolvable NDK-stable C signature); NDK↔platform-binder interop, not plain NDK.
- **libnativehelper (~17):** `JniConstants_*` (class/field-id caches for FileDescriptor/NIOAccess/NioBuffer), `JniInvocationCreate/Destroy/Init` (JNI-invocation interface for runtime launchers like `app_process`, not NDK apps), `EnsureInitialized`. These are exported but not in `<nativehelper/JNIHelp.h>`; NDK apps never call them directly.
- **libandroid_runtime (~all):** framework runtime internals; not NDK-stable.

## 2. Public C API gaps — in scope

### Tractable (JNIEnv* translation + pointer/int pass-through)
- **libnativehelper — COVERED (11):** `jniThrowException`, `jniThrowNullPointerException`, `jniThrowRuntimeException`, `jniThrowIOException`, `jniThrowErrnoException`, `jniLogException`, `jniCreateString`, `jniGetNioBufferFields`, `jniGetNioBufferPointer`, `jniGetNioBufferBaseArray`, `jniGetNioBufferBaseArrayOffset` — the public `<nativehelper/JNIHelp.h>` C API. Each takes a `JNIEnv*` first argument, which is NOT a plain pointer pass-through (the guest `JNIEnv` holds guest-callable function pointers); the custom trampolines in `digitalis_extra_proxy/digitalis_extra_libnativehelper_trampolines.cc` translate it with `ToHostJNIEnv` and forward the remaining flat args (`jclass`/`jobject`/`const char*`/`jint*` pass through verbatim under LP64). They appeared incompatible only because the API analysis didn't resolve the JNI types. The host function is reached via the dlsym'd `callee`, so libberberis_arm64.so gains no libnativehelper link dependency. Validated end-to-end by the hello-jni `[LIBNH-PROXY:PASS]` probe.
- **libbinder_ndk — COVERED (1):** `AServiceManager_NotificationRegistration_delete` (opaque host-owned handle pointer; `GetTrampolineFunc<auto(void*)->void>`). Registration/build-verified only — the sole producer of the handle (`AServiceManager_registerForServiceNotifications`) is an uncovered callback symbol, so it is not yet exercisable end-to-end. See `digitalis_extra_libbinder_ndk_trampolines.cc`.

### Hard — need a host→guest thunk or special marshalling (callback / varargs / fn-ptr return)
- **libGLESv2 / libGLESv3:** `glGetVkProcAddrNV` — returns a function pointer the guest then calls; the returned host pointer must be wrapped as a guest-callable trampoline of unknown (per-entry) signature. NVIDIA Vulkan-interop extension, absent on the emulator GPU.
- **libnativewindow:** `ANativeWindow_setPerformInterceptor` — takes an interceptor callback `int(*)(ANativeWindow*, int, va_list, ...)` the host invokes; needs a host→guest thunk plus va_list marshalling. Debug/interception hook, rare.
- **libbinder_ndk:** `AServiceManager_registerForServiceNotifications` — takes an `AServiceManager_onRegister` callback the host invokes; needs a host→guest thunk.
- **libcamera2ndk:** `ACameraCaptureSessionShared_startStreaming`, `ACameraCaptureSessionShared_logicalCamera_startStreaming` — callback/struct-by-value; need marshalling. Newer shared-camera API.
- **libnativehelper:** `jniThrowExceptionFmt` (varargs — needs `struct __va_list` marshalling), `jniRegisterNativeMethods` (array of `JNINativeMethod` containing guest function pointers — each must be thunked).
- **libwebviewchromium_plat_support:** `JNI_OnLoad(JavaVM*, void*)` — the proxy lib's own load-time entry. `JavaVM*` is translatable in-surface (`ToHostJavaVM`), but it registers host native methods against guest-loaded Java classes and is only reached if this glue lib runs under the bridge; on the x86_64 emulator WebView uses the host (x86_64) stack, so it is unreachable here. Deferred (not implemented to avoid unexercisable, unverifiable marshalling).

## Status

- Enabling override: **done** (`proxy_library_builder.cc`, arm64-guarded).
- libnativehelper: **done** — 11 public `<JNIHelp.h>` C-API symbols covered in
  `digitalis_extra_libnativehelper_trampolines.cc` (JNIEnv translation via
  `ToHostJNIEnv`); validated by the hello-jni `[LIBNH-PROXY:PASS]` probe. Only
  `jniThrowExceptionFmt` (varargs) and `jniRegisterNativeMethods` (guest fn-ptr
  array) remain, both genuinely hard.
- libbinder_ndk: **done** — `AServiceManager_NotificationRegistration_delete` covered
  in `digitalis_extra_libbinder_ndk_trampolines.cc` (registration/build-verified).
- libEGL, libGLESv2/v3, libnativewindow, libandroid, libcamera2ndk,
  libwebviewchromium_plat_support: **no tractable gaps** — their arm64
  `DoBadTrampoline` entries are all internal C++ or hard callback/varargs/fn-ptr
  cases (above). libandroid has zero gaps.
- Hard (callback/varargs/fn-ptr) gaps: require host→guest thunk marshalling
  (mirroring `egl_trampolines.cc`'s `DoCustomTrampolineWithThunk`); deferred unless
  a real app is observed calling one. Most are rare extensions or
  rarely-guest-linked.
- Internal C++ and `libandroid_runtime`: out of scope (not NDK-stable).
