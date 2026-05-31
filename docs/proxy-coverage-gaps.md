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
| libbinder_ndk | 3 | 1 | 2 (both covered) |
| libcamera2ndk | 2 | 0 | 2 (both hard) |
| libnativehelper | 31 | ~17 (JniConstants_*/JniInvocation*) | 13 (11 covered, 2 hard) |
| libwebviewchromium_plat_support | 18 | 17 | 1 (hard/deferred) |
| libandroid_runtime | ~1246 | ~all | n/a (framework-internal) |

**Net actionable result:** every tractable NDK-stable public-C-API
`DoBadTrampoline` symbol is now covered (libnativehelper ×11, libbinder_ndk ×2,
including one host→guest callback). Everything still uncovered is either an
internal C++ implementation symbol (not NDK-stable, not callable across the C
ABI) or a case whose correct marshalling cannot be expressed in a trampoline —
variadic callbacks, fn-ptr returns of unknown signature, struct-of-many-callbacks
that can't be verified, or C++-by-value returns — enumerated below and deferred
until a real app is observed needing it, never covered with guessed marshalling.

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
- **libbinder_ndk — COVERED (2):** `AServiceManager_NotificationRegistration_delete` (opaque host-owned handle; `GetTrampolineFunc<auto(void*)->void>`) and `AServiceManager_registerForServiceNotifications` (custom trampoline). The latter's `onRegister` callback is a fixed-signature guest function the host invokes; it is wrapped with `WrapGuestFunction` (see "host→guest callbacks" below). The `delete` is reached only on a successful registration; both validated by the hello-binder-ndk probe (register dispatches and returns with no "Bad call" abort; it returns null only because the sample's `untrusted_app` uid lacks servicemanager `find` permission). See `digitalis_extra_libbinder_ndk_trampolines.cc`.

**Host→guest callbacks are tractable in-surface.** `WrapGuestFunction<Ret, Args...>(guest_fn, name)` (`guest_abi/guest_function_wrapper.h`) turns a guest function pointer into a host-callable one; it computes the wrapper signature from the C++ types at compile time and routes calls through `RunGuestCall` — no `native_bridge_support` registration. `RunGuestCall`→`GetCurrentGuestThread`→`AttachCurrentThread` auto-attaches a guest thread (with TLS) to any unattached host thread, so callbacks delivered on host-spawned threads (binder/looper/etc.) are safe. This makes any **fixed-signature** callback coverable. It does NOT help variadic callbacks (`va_list`), fn-ptr *returns* of unknown signature, or struct-of-many-callbacks whose layout/signatures can't be verified — those remain below.

### Hard — need marshalling that cannot be expressed correctly in a trampoline
- **libGLESv2 / libGLESv3:** `glGetVkProcAddrNV` — *returns* a function pointer the guest then calls; the returned host pointer would have to be wrapped as a guest-callable thunk of a per-entry-point signature that is unknown at the call site. NVIDIA Vulkan-interop extension, absent on the emulator GPU.
- **libnativewindow:** `ANativeWindow_setPerformInterceptor` — interceptor callback `int(*)(ANativeWindow*, int op, va_list, ...)`; the `va_list` argument's contents depend on `op` and would need per-op interpretation plus arm64→x86_64 va_list re-packing. Debug/interception hook, rare.
- **libcamera2ndk:** `ACameraCaptureSessionShared_startStreaming`, `ACameraCaptureSessionShared_logicalCamera_startStreaming` — take an `ACameraCaptureSession_captureCallbacksV2*` struct holding ~6-8 distinct callbacks; each field needs its own `WrapGuestFunction` plus exact struct-layout/signature verification. Tractable in principle, but a wrong field would silently corrupt, and the shared-camera V2 API cannot be exercised on the emulator to verify — deferred rather than shipped on guesswork.
- **libnativehelper:** `jniThrowExceptionFmt` (varargs — needs `struct __va_list` marshalling), `jniRegisterNativeMethods` (array of `JNINativeMethod` containing guest function pointers — each must be thunked).
- **libwebviewchromium_plat_support:** `JNI_OnLoad(JavaVM*, void*)` — the proxy lib's own load-time entry. `JavaVM*` is translatable in-surface (`ToHostJavaVM`), but it registers host native methods against guest-loaded Java classes and is only reached if this glue lib runs under the bridge; on the x86_64 emulator WebView uses the host (x86_64) stack, so it is unreachable here. Deferred (not implemented to avoid unexercisable, unverifiable marshalling).

## Status

- Enabling override: **done** (`proxy_library_builder.cc`, arm64-guarded).
- libnativehelper: **done** — 11 public `<JNIHelp.h>` C-API symbols covered in
  `digitalis_extra_libnativehelper_trampolines.cc` (JNIEnv translation via
  `ToHostJNIEnv`); validated by the hello-jni `[LIBNH-PROXY:PASS]` probe. Only
  `jniThrowExceptionFmt` (varargs) and `jniRegisterNativeMethods` (guest fn-ptr
  array) remain, both genuinely hard.
- libbinder_ndk: **done** — both public symbols covered in
  `digitalis_extra_libbinder_ndk_trampolines.cc`
  (`AServiceManager_NotificationRegistration_delete` +
  `AServiceManager_registerForServiceNotifications` with a `WrapGuestFunction`
  host→guest callback); validated by the hello-binder-ndk probe.
- libEGL, libGLESv2/v3, libnativewindow, libandroid, libcamera2ndk,
  libwebviewchromium_plat_support: **no further tractable gaps** — their arm64
  `DoBadTrampoline` entries are all internal C++ or hard (variadic callback,
  fn-ptr-return, or unverifiable struct-of-callbacks) cases above. libandroid
  has zero gaps.
- Hard (callback/varargs/fn-ptr) gaps: require host→guest thunk marshalling
  (mirroring `egl_trampolines.cc`'s `DoCustomTrampolineWithThunk`); deferred unless
  a real app is observed calling one. Most are rare extensions or
  rarely-guest-linked.
- Internal C++ and `libandroid_runtime`: out of scope (not NDK-stable).
