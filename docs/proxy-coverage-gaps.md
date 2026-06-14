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
| libwebviewchromium_plat_support | 18 | 17 covered; 1 hard/deferred (JNI_OnLoad) |
| libandroid_runtime | ~1246 | ~all framework-internal |

Each uncovered symbol is either **not NDK-stable** (an internal C++ /
launcher / loader symbol, never reached from guest app code) or **NDK-stable but
un-marshalable** (its correct marshalling cannot be expressed in a trampoline
without guessed or unverifiable behavior). None are covered with guessed
marshalling.

## 1. Internal C++ symbols — NOT NDK-stable, out of scope (do not cover)

Mangled `_ZN7android...` symbols are usually libraries' own implementation
classes, called only by the library's own code (which runs host-side behind the
public C API), so covering them is normally pointless. The exception is a mangled
symbol an app *does* call directly with a flat C-ABI signature — those are
coverable and are not listed here (e.g. `libwebviewchromium_plat_support`'s
`GraphicBufferImpl::*`, now covered; see the technique reference below). The
entries below are the ones that remain genuinely out of scope.
- **libEGL (8):** `android::egl_display_t::{makeCurrent,loseCurrent,loseCurrentImpl,addObject,removeObject,getObject}`, `android::egl_get_connection`, `android::setGlThreadSpecific`. The public EGL C API (`eglMakeCurrent`, …) is already covered upstream.
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
- **libwebviewchromium_plat_support:** `JNI_OnLoad(JavaVM*, void*)` — the proxy lib's own load-time entry, with dedicated native-bridge handling. `JavaVM*` is translatable in-surface (`ToHostJavaVM`), but as the standard JNI load-time entry point it is the special native-bridge case rather than an app-called symbol; the observed path is apps calling the individual `Register*` symbols directly (now covered, see below), so this one is left deferred. The other 17 of this library's 18 symbols are covered in `digitalis_extra_libwebviewchromium_plat_support_trampolines.cc`.

## Technique reference — what makes a gap coverable

When deciding whether a future `DoBadTrampoline` symbol can be covered in-surface:
- **Pointer/int signatures:** `GetTrampolineFunc<…>()` with `void*` for pointers (valid under LP64 when the pointee layout is identical).
- **`JNIEnv*` / `JavaVM*` arguments:** translate with `ToHostJNIEnv` / `ToHostJavaVM` (a plain `void*` pass-through is WRONG — the guest env holds guest-callable function pointers). Reach the host function via the dlsym'd `callee` so no extra link dependency is added.
- **Fixed-signature callbacks:** wrap the guest function with `WrapGuestFunction<Ret, Args…>(guest_fn, name)` (`guest_abi/guest_function_wrapper.h`). It builds a host-callable thunk routed through `RunGuestCall`, whose `GetCurrentGuestThread`→`AttachCurrentThread` auto-attaches a guest thread (with TLS) to any host-spawned callback thread (binder/looper/etc.), so async delivery is safe.
- **Mangled C++ is not automatically out of scope.** "Internal `_ZN7android…` C++" is a *heuristic* for "NDK apps never call it," not a hard rule. When such a symbol has a **flat C-ABI signature** (int / long / void* / void** / an enum, all LP64-identical between guest and host) and an app actually calls it, it forwards directly through `GetTrampolineFunc` like any pointer/int symbol — the mangling is irrelevant to marshalling. `libwebviewchromium_plat_support`'s `GraphicBufferImpl::*` static/instance methods (`Create`/`Release`/`MapStatic`/…) are exactly this: mangled, but flat, and covered. The genuinely-uncoverable mangled symbols are the ones that aren't flat — by-value `sp<>` returns, C++ ABI types — not all mangled symbols.
- **A host-registration entry point taking `JNIEnv*` needs a *host* env, not a translated guest one.** `ToHostJNIEnv` is for forwarding a call the guest makes *with its own env*; a symbol that runs `jniRegisterNativeMethods` on the **host** VM (e.g. `android::Register{DrawFunctor,DrawGLFunctor,GraphicsUtils}(JNIEnv*)`) needs a valid host env for the current thread. These are called from guest-spawned worker threads never attached to the host VM, so translating the guest env yields a null host env and the host function SIGSEGVs on its first `*env`. The trampoline instead fetches a host env from the captured host `JavaVM` (`GetHostJavaVM()` + `GetEnv`, attaching the thread if detached and detaching afterwards) and forwards. This is the reusable pattern for any JNIEnv-taking host-side `RegisterNatives` symbol.
- **Not coverable:** variadic callbacks / varargs (`va_list`), fn-ptr *returns* of unknown signature, struct-of-many-callbacks that can't be layout/signature-verified, and C++-mangled / by-value-`sp<>` symbols (not the C ABI, not NDK-stable).
