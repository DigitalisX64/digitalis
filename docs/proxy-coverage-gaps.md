# Proxy-library symbol coverage gaps (`DoBadTrampoline`)

A proxy library forwards each guest `lib*.so` symbol to the host. The trampoline
table (`native_bridge_support/android_api/<lib>/proxy/trampolines_arm64_to_x86_64-inl.h`,
generated, read-only) marks a symbol `DoBadTrampoline` when the auto-generator
deemed its signature incompatible and no upstream custom trampoline exists.
Calling such a symbol aborts with `LOG_ALWAYS_FATAL("Bad '<sym>' call")`
(`proxy_loader/proxy_library_builder.cc`, `DoBadTrampoline`).

Digitalis covers tractable symbols **in-surface** from
`binary_translation/android_api/digitalis_extra_proxy/` via
`ProxyLibraryBuilder::RegisterExtraTrampolines` (enabled by the arm64-guarded
`InterceptSymbol` tweak in `proxy_loader/proxy_library_builder.cc`, which lets an
extra trampoline beat the primary `DoBadTrampoline` for a symbol). Every
NDK-stable public-C-API symbol for which a *correct* trampoline can be expressed
is already covered there (see the `digitalis_extra_*_trampolines.cc` files and
their commits); this document tracks only what remains **uncovered** and why.

> Two registration mechanisms live side-by-side in `digitalis_extra_proxy/`, and
> only the first is a `DoBadTrampoline` story:
> 1. **`DoBadTrampoline` overrides** — a symbol the upstream proxy *has* but
>    marked bad. These are the gaps tracked here.
> 2. **Missing-symbol additions** — a symbol the upstream proxy *omits entirely*
>    (`libc`/`libm` fast-path helpers). The `InterceptSymbol` "primary table
>    miss" path lets an extra trampoline supply it. These never produce a `Bad
>    '<sym>' call`; they are listed in §3 for completeness, not as gaps.

## Scope: remaining arm64 `DoBadTrampoline` gaps

Counts are for the **arm64** table only (earlier headline numbers were ~3x
inflated by summing the arm64 + arm + riscv64 tables). The per-library breakdown
below is from `grep -c DoBadTrampoline` on each upstream
`trampolines_arm64_to_x86_64-inl.h`.

| Library | upstream arm64 `DoBadTrampoline` | Digitalis covers | remaining | nature of the remaining gap |
|---|---:|---:|---:|---|
| libEGL | 8 | 0 | 8 | internal C++ (`egl_display_t::*`, `egl_get_connection`, `setGlThreadSpecific`) |
| libGLESv2 | 1 | 0 | 1 | hard — `glGetVkProcAddrNV` (fn-ptr return) |
| libGLESv3 | 1 | 0 | 1 | hard — `glGetVkProcAddrNV` (fn-ptr return) |
| libnativewindow | 1 | 0 | 1 | hard — `ANativeWindow_setPerformInterceptor` (va_list callback, private) |
| libandroid | 0 | 0 | 0 | — (public C API fully marshaled upstream) |
| libbinder_ndk | 3 | 2 | 1 | hard — `AIBinder_toPlatformBinder` (by-value `sp<>`) |
| libcamera2ndk | 2 | 0 | 2 | permanently-deferred — shared-camera callback-struct, untestable on the emulator (SYSTEM_CAMERA + no HAL shared-session support) |
| libnativehelper | 31 | 13 | 18 | ~15 `JniConstants_*` + `JniInvocation*`/`EnsureInitialized` |
| libwebviewchromium_plat_support | 18 | 17 | 1 | hard/deferred — `JNI_OnLoad` |
| libandroid_runtime | 1135 | 0 | 1135 | ~all framework-internal (not NDK-stable) |

Excluding `libandroid_runtime` (entirely framework-internal C++), the app-facing
libraries above carry **65** arm64 `DoBadTrampoline` entries; Digitalis covers
**32** of them (2 binder_ndk + 13 nativehelper + 17 webview), and the **33**
remaining are each either not NDK-stable or un-marshalable (below).

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
- **libbinder_ndk (1 of 3):** `_Z25AIBinder_toPlatformBinderP8AIBinder` — `AIBinder_toPlatformBinder(AIBinder*)` returns a C++ `android::sp<IBinder>` by value (no resolvable NDK-stable C signature); NDK↔platform-binder interop, not plain NDK. The other 2 (`AServiceManager_NotificationRegistration_delete`, `AServiceManager_registerForServiceNotifications`) are **covered** — see §2-covered below.
- **libnativehelper (~17 of 31):** `JniConstants_*` (the ~15 class/field-id caches for FileDescriptor/NIOAccess/NioBuffer), `JniInvocationCreate/Destroy/Init` (JNI-invocation interface for runtime launchers like `app_process`, not NDK apps), `EnsureInitialized`. Exported but not in `<nativehelper/JNIHelp.h>`; NDK apps never call them directly.
- **libandroid_runtime (~all 1135):** framework runtime internals; not NDK-stable.

## 2. Hard — NDK-stable/extension but un-marshalable in a trampoline

These cannot be forwarded correctly without guessed or unverifiable marshalling.
Each is **permanently excluded** for the precise reason stated in its bullet —
a function-pointer *return* of per-entrypoint-unknown signature, an op-dependent
`va_list` callback, a by-value C++ `sp<>` return, or a callback-struct that is
untestable on the emulator (so its marshalling can never be verified). These are
terminal dispositions, not "covered when an app needs it": the C ABI cannot
express them correctly, so a future app needing one would still hit the same
wall. Re-open a bullet only if its stated blocker changes (e.g. the emulator
gains an AIDL camera HAL with shared-session support).
- **libGLESv2 / libGLESv3:** `glGetVkProcAddrNV` — *returns* a function pointer the guest then calls; the returned host pointer would have to be wrapped as a guest-callable thunk of a per-entry-point signature unknown at the call site. NVIDIA Vulkan-interop extension, absent on the emulator GPU.
- **libnativewindow:** `ANativeWindow_setPerformInterceptor` — interceptor callback `int(*)(ANativeWindow*, int op, va_list, ...)`; the `va_list` contents depend on `op` and need per-op interpretation plus arm64→x86_64 va_list re-packing. Private (system) debug/interception hook.
- **libcamera2ndk (PERMANENTLY-DEFERRED — verified untestable on the Digitalis emulator):** `ACameraCaptureSessionShared_startStreaming` (guest export @ off 0x4100) and `ACameraCaptureSessionShared_logicalCamera_startStreaming` (@ off 0x4080) each take a callbacks-struct of 1 `context` + 7 distinct function-pointer callbacks (`ACameraCaptureSession_captureCallbacksV2` / `…_logicalCamera_captureCallbacksV2`, `NdkCameraCaptureSession.h:863`/`:914`); covering them means a per-field `WrapGuestFunction` over every callback **plus** exact struct-layout/signature verification, and a wrong field silently corrupts capture results rather than crashing. Verifying that marshalling requires the host camera service to actually *fire* each callback through a live shared session — which the Digitalis emulator cannot provide, for **two independent, on-device-confirmed reasons** (either alone is sufficient):
  1. **Permission gate.** The only entry to a shared session is `ACameraManager_openSharedCamera` (`NdkCameraManager.h:345`), which **requires `android.permission.SYSTEM_CAMERA` in addition to `CAMERA`** (`NdkCameraManager.h:317-319`). `SYSTEM_CAMERA` is `protectionLevel="system|signature|role"` and `@hide` (`frameworks/base/core/res/AndroidManifest.xml:1800-1806`; on-device `dumpsys package` reports `prot=signature|privileged|role`). The `test-samples.sh` harness installs debug-signed sample APKs via `adb install` — neither platform-signed, nor a privileged priv-app with an allowlist entry, nor a role holder — so a sample can never legitimately hold it; `adb shell pm grant <pkg> android.permission.SYSTEM_CAMERA` silently no-ops (RC=0 but the package never holds it, since it is not a runtime/dangerous permission the app can request). `openSharedCamera` therefore returns `ACAMERA_ERROR_PERMISSION_DENIED`.
  2. **HAL gate (permission-independent, decisive).** Shared/multi-client camera sessions are an Android-16/API-36 (`__INTRODUCED_IN(36)`) AIDL camera2 feature. The emulator's camera is the legacy HIDL `device@1.1` (v1.3) provider (`dumpsys media.camera`: `Camera Provider HAL …/internal/0-0 (v2.0, remote)`, devices `device@1.1/internal/{0,1}`), which does not implement multi-client shared sessions, so `ACameraManager_isCameraDeviceSharingSupported` returns false and `openSharedCamera` fails regardless of permission.

  With no shared `ACameraCaptureSession` obtainable, neither `…Shared_startStreaming` can be invoked on a real session and the host never fires the callbacks. A forwarding-only smoke test (passing a null/fake session → the API returns `ACAMERA_ERROR_INVALID_OPERATION` without touching any callback field) proves only that a trampoline forwards — it exercises **none** of the per-field callback marshalling, so it cannot verify the struct layout. Covering on that basis is exactly the forbidden blind/guessed marshalling. **Disposition: permanently-deferred (untestable on the emulator).** Re-evaluate only if a future Digitalis emulator ships an AIDL camera HAL with shared-session support *and* a sample can be granted `SYSTEM_CAMERA` (e.g. a platform-signed priv-app sample) so the callbacks can be fired and the struct layout verified against ground truth.
- **libwebviewchromium_plat_support:** `JNI_OnLoad(JavaVM*, void*)` — the proxy lib's own load-time entry, with dedicated native-bridge handling. `JavaVM*` is translatable in-surface (`ToHostJavaVM`), but as the standard JNI load-time entry point it is the special native-bridge case rather than an app-called symbol; the observed path is apps calling the individual `Register*` symbols directly (now covered, see below), so this one is left deferred. The other 17 of this library's 18 symbols are covered in `digitalis_extra_libwebviewchromium_plat_support_trampolines.cc`.

## 2-covered. What Digitalis already covers in-surface

These were `DoBadTrampoline` upstream and are now forwarded correctly from
`digitalis_extra_proxy/`. Listed so the gap accounting above is auditable.

- **libbinder_ndk (2):** `AServiceManager_NotificationRegistration_delete` (flat `void(void*)` pointer pass-through) and `AServiceManager_registerForServiceNotifications` (its `OnRegister` guest callback is wrapped with `WrapGuestFunction`, so the host can invoke it back through the translator on any host-spawned thread). See `digitalis_extra_libbinder_ndk_trampolines.cc`. **Regression sample:** `hello-binder-ndk`'s `ProbeServiceNotifications()` `dlopen`s `libbinder_ndk.so` and calls both — `register…ForServiceNotifications(instance, OnServiceRegister, nullptr)` (driving the `WrapGuestFunction` callback path) followed by `NotificationRegistration_delete(reg)`; either lost trampoline aborts with `Bad '<sym>' call`.
- **libnativehelper (13):** the 12 flat helpers `jniThrowException`, `jniThrowNullPointerException`, `jniThrowRuntimeException`, `jniThrowIOException`, `jniThrowErrnoException`, `jniLogException`, `jniCreateString`, `jniGetNioBufferFields`, `jniGetNioBufferPointer`, `jniGetNioBufferBaseArray`, `jniGetNioBufferBaseArrayOffset`, `jniRegisterNativeMethods` — each a custom trampoline that translates the leading `JNIEnv*` with `ToHostJNIEnv` before forwarding — **plus the one varargs helper `jniThrowExceptionFmt`**. The varargs helper cannot be forwarded as a host varargs call (a host `va_list` cannot be reconstructed from a dynamic argument list portably), but its documented semantics are exactly `vsnprintf(msgBuf, 512, fmt, args); jniThrowException(env, className, msgBuf)`, so it is covered in-surface: the trampoline walks the guest variadic tail per AAPCS64 with `GuestVAListParams` (the same path `guest_loader.cc`'s `TraceCallback` uses for guest tracing), formats host-side with `FormatBufferImpl` into a fixed 512-byte buffer, then throws on the host VM via the translated `JNIEnv` (`FindClass` + `ThrowNew`) — no host libnativehelper symbol is needed (the host inlines `jniThrowExceptionFmt` as a `static` header function). **Specifier limitation:** `FormatBufferImpl` supports `%s %d %u %x %c %p`, the `l`/`ll` integer-length forms, and `%z` size_t — but **not** floating-point (`%f`/`%g`/`%e`), exactly like the shared guest-trace formatter. libnativehelper's exception callers use integer/string formats; a `%f` would stop formatting at that point with the preceding text preserved (no crash, no wrong throw). See `digitalis_extra_libnativehelper_trampolines.cc`. **Regression sample:** `hello-jnihelp` `dlopen`s `libnativehelper.so`, calls all 13 and self-checks against ground truth (throw-family leaves a pending exception; `jniCreateString` length; `jniGetNioBuffer{Pointer,Fields}` return the controlled `NewDirectByteBuffer` base/position/limit/shift; `jniRegisterNativeMethods` returns `JNI_OK`; **`jniThrowExceptionFmt` is driven with 8 conversions spanning register- and stack-passed varargs and the resulting `getMessage()` is compared to the host-side-formatted string `s=abc d=-7 u=42 x=0xbeef c=Z p=0x1234 ld=-100000 zu=65536`** — proving each argument was read from the right AAPCS64 slot). A regressed/unregistered trampoline would abort with `Bad '<sym>' call`; a wrong value logs `FAIL`.
- **libwebviewchromium_plat_support (17):** the 3 `android::Register{DrawFunctor,DrawGLFunctor,GraphicsUtils}(JNIEnv*)` host-side registration entry points (host-env-attach pattern, below), `android::RaiseFileNumberLimit()`, and the 13 flat-C-ABI `android::GraphicBufferImpl::*` static/instance methods (`Create`/`Release`/`MapStatic`/`UnmapStatic`/`GetNativeBufferStatic`/`GetStrideStatic`/`Map`/`Unmap`/`GetNativeBuffer`/`GetStride`/`InitCheck`/`C2` ctor/`D2` dtor). Unblocks WebView hardware-accel draw under translation (Douyin's Lynx UI). See `digitalis_extra_libwebviewchromium_plat_support_trampolines.cc`. **Regression sample:** `hello-webview-functor` `dlopen`s the lib and drives **all 17** — the 3 `Register*` entry points (each returns -1 from a non-host-VM worker thread, proving the trampoline forwarded rather than aborting), `RaiseFileNumberLimit`, the full static buffer-id path (`Create`→valid id, `GetStrideStatic`==256, `GetNativeBufferStatic`, `MapStatic`==0, `UnmapStatic`, `Release`), and the full instance path (`C2` ctor → `InitCheck`==0, `GetStride`, `GetNativeBuffer`, `Map`, `Unmap`, `D2` dtor). Any lost trampoline aborts with `Bad '<sym>' call`; a wrong value logs `FAIL`.

## 3. Missing-symbol additions (NOT `DoBadTrampoline` — different mechanism)

These symbols are absent from the upstream proxy table entirely; the
`InterceptSymbol` primary-table-**miss** path lets a Digitalis extra trampoline
supply them. They never abort with `Bad '<sym>' call`; included so the full
`digitalis_extra_proxy/` surface is documented in one place.

- **libc (32 fast-path symbols):** `isnan`/`isinf`/`isfinite`/`isnormal`/`__fpclassify` (and `f` variants), `memrchr`, `__memcpy_chk`/`__memset_chk`, `strchrnul`, `stpcpy`, `ftell`, `lockf`, `prlimit`, `pselect`, the `*64` stat/statfs/statvfs/truncate/rlimit/sendfile/creat/alphasort/`mmap64` family. All flat LP64-identical signatures via `GetTrampolineFunc<>`. See `digitalis_extra_libc_trampolines.cc`. **Regression sample:** `hello-libc-libm` exercises every one of these against ground truth (`PASS N/N probes`), including `__memcpy_chk`/`__memset_chk` (return-pointer + resulting-bytes checks). All 32 are exported by the guest `libc.so` (the `_chk` pair carry a `@@LIBC` symbol-version suffix, which the proxy matches by base name).
- **libm (15 symbols):** `cospi`/`sinpi` (+`f`), `ldexpf`, and the `__{exp,exp2,log,log2,pow}_finite` (+`f`) internal-but-referenced fast-math entry points. See `digitalis_extra_libm_trampolines.cc`. **Regression sample:** `hello-libc-libm` `dlsym`s and value-checks `cospi`, `sinpi`, `ldexpf`, and all ten `*_finite` thunks. **Note — `cospif`/`sinpif` are unreachable:** the guest `libm.so` exports `cospi`/`sinpi` but **not** the `f` variants (confirmed via `readelf --dyn-syms` on `/system/lib64/arm64/libm.so`), so no guest can resolve `cospif`/`sinpif` and their trampolines are never hit. They are harmless (a missing-symbol add never aborts) but cannot be driven by any sample; left registered for forward-compat if a future bionic adds the exports.
- **Host-call redirect (not a trampoline at all):** `digitalis_host_call_redirect.cc` installs a `HandleNoExec` hook (`SetHandleNoExecHook`) so that when a hardened guest library hand-resolves and branches *directly into a host system library's x86_64 code* (e.g. AliExpress's `libsgmainso` jumping into host `libsqlite.so`), the resulting no-exec fault is redirected to the **guest** copy of that symbol (resolved via `GuestLoader` from `/system/lib64/arm64/`) instead of crashing.
- **Guest-library stub (sibling mechanism, not in `digitalis_extra_proxy/`):** when a guest library `dlopen`s a *whole* system library Digitalis does not proxy, the missing `.so` makes the guest jump to a host address (`berberis_HandleNoExec` SIGSEGV) — a missing-*library* gap, not a missing/bad *symbol*. The fix is a minimal **guest-only stub library** under `binary_translation/android_api/digitalis_libgui_stub/` (built as a `native_bridge_stub_library_defaults` `cc_library`, installed to `/system/lib64/arm64/libgui.so`). Google Filament `dlopen`s `libgui.so` on its on-screen SwapChain present path and `dlsym`s `android::Surface::hook_perform`; the stub exports that as a no-op (the real surface/buffer work is host-proxied, so a full guest libgui is both unnecessary and at odds with the proxied path) so the `dlopen`/`dlsym` succeed and the present path no longer faults. New no-op symbols are added to `libgui_stub.cc` on observed need, the same demand-driven way trampolines are.

## Technique reference — what makes a gap coverable

When deciding whether a future `DoBadTrampoline` symbol can be covered in-surface:
- **Pointer/int signatures:** `GetTrampolineFunc<…>()` with `void*` for pointers (valid under LP64 when the pointee layout is identical).
- **`JNIEnv*` / `JavaVM*` arguments:** translate with `ToHostJNIEnv` / `ToHostJavaVM` (a plain `void*` pass-through is WRONG — the guest env's `JNINativeInterface` vtable holds guest-callable function pointers, so a host deref of it faults in `berberis_HandleNoExec`). Reach the host function via the dlsym'd `callee` so no extra link dependency is added.
- **Fixed-signature callbacks:** wrap the guest function with `WrapGuestFunction<Ret, Args…>(guest_fn, name)` (`guest_abi/guest_function_wrapper.h`). It builds a host-callable thunk routed through `RunGuestCall`, whose `GetCurrentGuestThread`→`AttachCurrentThread` auto-attaches a guest thread (with TLS) to any host-spawned callback thread (binder/looper/etc.), so async delivery is safe.
- **Mangled C++ is not automatically out of scope.** "Internal `_ZN7android…` C++" is a *heuristic* for "NDK apps never call it," not a hard rule. When such a symbol has a **flat C-ABI signature** (int / long / void* / void** / an enum, all LP64-identical between guest and host) and an app actually calls it, it forwards directly through `GetTrampolineFunc` like any pointer/int symbol — the mangling is irrelevant to marshalling. `libwebviewchromium_plat_support`'s `GraphicBufferImpl::*` static/instance methods (`Create`/`Release`/`MapStatic`/…) are exactly this: mangled, but flat, and covered. The genuinely-uncoverable mangled symbols are the ones that aren't flat — by-value `sp<>` returns, C++ ABI types — not all mangled symbols.
- **A host-registration entry point taking `JNIEnv*` needs a *host* env, not a translated guest one.** `ToHostJNIEnv` is for forwarding a call the guest makes *with its own env*; a symbol that runs `jniRegisterNativeMethods` on the **host** VM (e.g. `android::Register{DrawFunctor,DrawGLFunctor,GraphicsUtils}(JNIEnv*)`) needs a valid host env for the current thread. These are called from guest-spawned worker threads never attached to the host VM, so translating the guest env yields a null host env and the host function SIGSEGVs on its first `*env`. The trampoline instead fetches a host env from the captured host `JavaVM` (`GetHostJavaVM()` + `GetEnv`, attaching the thread if detached and detaching afterwards) and forwards. This is the reusable pattern for any JNIEnv-taking host-side `RegisterNatives` symbol.
- **Printf-style varargs (`fmt, ...`) ARE coverable when the function consumes its own format string.** A true-varargs forwarder cannot rebuild a host `va_list`, but a printf-family symbol does not need one: read the named params with `GuestParamsValues<Ret(Named..., ...)>`, then walk the variadic tail per AAPCS64 with `GuestVAListParams` (constructed from those named params — it tracks the int/SIMD/stack cursor and handles register→stack overflow), feeding each argument to `FormatBufferImpl` via a small adapter (mirror `guest_loader.cc`'s `FormatBufferGuestParamsArgs`). Format host-side into a fixed buffer and call the non-varargs sink yourself. `libnativehelper`'s `jniThrowExceptionFmt` is covered this way (format → `JNIEnv::FindClass`+`ThrowNew`). Caveat: `FormatBufferImpl` handles integer/string/pointer specifiers but **not** floating-point (`%f`/`%g`/`%e`) — fine for error-message formatters, but verify the symbol's callers don't rely on float conversions before covering it this way.
- **Not coverable:** variadic *callbacks* (the guest is the callee and we don't control a format string), an opaque `va_list` re-pack into a host varargs call, fn-ptr *returns* of unknown signature, struct-of-many-callbacks that can't be layout/signature-verified, and C++-mangled / by-value-`sp<>` symbols (not the C ABI, not NDK-stable). (A printf-style `fmt, ...` symbol whose format string IS the spec is coverable — see the bullet above.)
