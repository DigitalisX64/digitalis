# Proxy-library symbol coverage gaps (`DoBadTrampoline`)

A proxy library forwards each guest `lib*.so` symbol to the host. The trampoline
table (`native_bridge_support/android_api/<lib>/proxy/trampolines_arm64_to_x86_64-inl.h`,
generated, read-only) marks a symbol `DoBadTrampoline` when the auto-generator
deemed its signature incompatible and no upstream custom trampoline exists.
Calling such a symbol aborts with `LOG_ALWAYS_FATAL("Bad '<sym>' call")`.

Digitalis covers tractable symbols **in-surface** from
`binary_translation/android_api/digitalis_extra_proxy/` via
`ProxyLibraryBuilder::RegisterExtraTrampolines` (enabled by the arm64-guarded
`InterceptSymbol` tweak in `proxy_loader/proxy_library_builder.cc`). Every
NDK-stable public-C-API symbol for which a *correct* trampoline can be expressed
is already covered there (see the `digitalis_extra_*_trampolines.cc` files and
their commits); this document tracks only what remains **uncovered** and why.

## Scope: remaining arm64 `DoBadTrampoline` gaps

Counts are for the **arm64** table only (earlier headline numbers were ~3x
inflated by summing the arm64 + arm + riscv64 tables). Of the 64 arm64
`DoBadTrampoline` entries across these libraries, the tractable NDK-stable ones
are covered; the rest break down as below.

| Library | arm64 gaps | remaining-gap kind |
|---|---|---|
| libEGL | 8 | 8 internal C++ |
| libGLESv2 | 1 | 1 hard (fn-ptr return) |
| libGLESv3 | 1 | 1 hard (fn-ptr return) |
| libnativewindow | 1 | 1 hard (va_list callback, private) |
| libandroid | 0 | — |
| libbinder_ndk | 3 | 1 internal C++ (rest covered) |
| libcamera2ndk | 2 | 2 hard (callback-struct, trunk API) |
| libnativehelper | 31 | ~17 internal + 1 hard (rest covered) |
| libwebviewchromium_plat_support | 18 | 17 internal C++ + 1 hard/deferred |
| libandroid_runtime | ~1246 | ~all framework-internal |

Each uncovered symbol is either **not NDK-stable** (an internal C++ /
launcher / loader symbol, never reached from guest app code) or **NDK-stable but
un-marshalable** (its correct marshalling cannot be expressed in a trampoline
without guessed or unverifiable behavior). None are covered with guessed
marshalling.

## 1. Internal C++ symbols — NOT NDK-stable, out of scope (do not cover)

Mangled `_ZN7android...` symbols are libraries' own implementation classes, never
called directly by NDK apps (only by the library's own code, which runs host-side
behind the public C API). Covering them is pointless.
- **libEGL (8):** `android::egl_display_t::{makeCurrent,loseCurrent,loseCurrentImpl,addObject,removeObject,getObject}`, `android::egl_get_connection`, `android::setGlThreadSpecific`. The public EGL C API (`eglMakeCurrent`, …) is already covered upstream.
- **libwebviewchromium_plat_support (17):** internal `android::` GraphicBuffer/AwDrawGLFunctor glue (`GraphicBufferImpl::*`, `RegisterDrawFunctor`, `RegisterDrawGLFunctor`, `RegisterGraphicsUtils`, `RaiseFileNumberLimit`).
- **libbinder_ndk (1):** `_Z25AIBinder_toPlatformBinderP8AIBinder` — `AIBinder_toPlatformBinder(AIBinder*)` returns a C++ `android::sp<IBinder>` by value (no resolvable NDK-stable C signature); NDK↔platform-binder interop, not plain NDK.
- **libnativehelper (~17):** `JniConstants_*` (class/field-id caches for FileDescriptor/NIOAccess/NioBuffer), `JniInvocationCreate/Destroy/Init` (JNI-invocation interface for runtime launchers like `app_process`, not NDK apps), `EnsureInitialized`. Exported but not in `<nativehelper/JNIHelp.h>`; NDK apps never call them directly.
- **libandroid_runtime (~all):** framework runtime internals; not NDK-stable.

## 2. Hard — NDK-stable/extension but un-marshalable in a trampoline

These cannot be forwarded correctly without guessed or unverifiable marshalling,
so they are deferred until a real app is observed needing one.
- **libGLESv2 / libGLESv3:** `glGetVkProcAddrNV` — *returns* a function pointer the guest then calls; the returned host pointer would have to be wrapped as a guest-callable thunk of a per-entry-point signature unknown at the call site. NVIDIA Vulkan-interop extension, absent on the emulator GPU.
- **libnativewindow:** `ANativeWindow_setPerformInterceptor` — interceptor callback `int(*)(ANativeWindow*, int op, va_list, ...)`; the `va_list` contents depend on `op` and need per-op interpretation plus arm64→x86_64 va_list re-packing. Private (system) debug/interception hook.
- **libcamera2ndk:** `ACameraCaptureSessionShared_startStreaming`, `ACameraCaptureSessionShared_logicalCamera_startStreaming` — take an `ACameraCaptureSession_captureCallbacksV2*` struct of ~7 distinct callbacks; each field needs its own `WrapGuestFunction` plus exact struct-layout/signature verification. A wrong field would silently corrupt, and this shared-camera (trunk/system) API cannot be exercised on the emulator to verify.
- **libnativehelper:** `jniThrowExceptionFmt` (true varargs — needs format-string-driven arm64→x86_64 `va_list` re-packing).
- **libwebviewchromium_plat_support:** `JNI_OnLoad(JavaVM*, void*)` — the proxy lib's own load-time entry. `JavaVM*` is translatable in-surface (`ToHostJavaVM`), but it registers host native methods against guest-loaded Java classes and is only reached if this glue lib runs under the bridge; on the x86_64 emulator WebView uses the host stack, so it is unreachable here.

## Technique reference — what makes a gap coverable

When deciding whether a future `DoBadTrampoline` symbol can be covered in-surface:
- **Pointer/int signatures:** `GetTrampolineFunc<…>()` with `void*` for pointers (valid under LP64 when the pointee layout is identical).
- **`JNIEnv*` / `JavaVM*` arguments:** translate with `ToHostJNIEnv` / `ToHostJavaVM` (a plain `void*` pass-through is WRONG — the guest env holds guest-callable function pointers). Reach the host function via the dlsym'd `callee` so no extra link dependency is added.
- **Fixed-signature callbacks:** wrap the guest function with `WrapGuestFunction<Ret, Args…>(guest_fn, name)` (`guest_abi/guest_function_wrapper.h`). It builds a host-callable thunk routed through `RunGuestCall`, whose `GetCurrentGuestThread`→`AttachCurrentThread` auto-attaches a guest thread (with TLS) to any host-spawned callback thread (binder/looper/etc.), so async delivery is safe.
- **Not coverable:** variadic callbacks / varargs (`va_list`), fn-ptr *returns* of unknown signature, struct-of-many-callbacks that can't be layout/signature-verified, and C++-mangled / by-value-`sp<>` symbols (not the C ABI, not NDK-stable).
