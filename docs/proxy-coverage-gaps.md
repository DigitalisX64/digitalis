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
| libcamera2ndk | 2 | 2 | 0 | covered — shared-camera V2 `…startStreaming` callback-struct trampolines; per-field `WrapGuestFunction` marshalling verified against the NDK header by a host test (end-to-end is untestable on the emulator, but that is not required to verify the marshalling) |
| libnativehelper | 31 | 13 | 18 | ~15 `JniConstants_*` + `JniInvocation*`/`EnsureInitialized` |
| libwebviewchromium_plat_support | 18 | 17 | 1 | hard/deferred — `JNI_OnLoad` |
| libandroid_runtime | 1135 | 0 | 1135 | ~all framework-internal (not NDK-stable) |

Excluding `libandroid_runtime` (entirely framework-internal C++), the app-facing
libraries above carry **65** arm64 `DoBadTrampoline` entries; Digitalis covers
**34** of them (2 binder_ndk + 2 camera2ndk + 13 nativehelper + 17 webview), and
the **31** remaining are each either not NDK-stable or un-marshalable (below).

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
`va_list` callback, or a by-value C++ `sp<>` return. These are terminal
dispositions, not "covered when an app needs it": the C ABI cannot express them
correctly, so a future app needing one would still hit the same wall. Re-open a
bullet only if its stated blocker changes.

(The libcamera2ndk shared-camera V2 `…startStreaming` pair used to live here as
"untestable on the emulator". It has moved to §2-covered: a struct of
fixed-signature callbacks is not un-marshalable — each callback is
`WrapGuestFunction`-able and the per-field marshalling is verifiable against the
NDK header by a host test, without needing to open a shared session on the
emulator. Being un-runnable end-to-end on the emulator is a *testability* limit
on the API, not an *expressibility* limit on the trampoline.)
- **libGLESv2 / libGLESv3:** `glGetVkProcAddrNV` — *returns* a function pointer the guest then calls; the returned host pointer would have to be wrapped as a guest-callable thunk of a per-entry-point signature unknown at the call site. NVIDIA Vulkan-interop extension, absent on the emulator GPU.
- **libnativewindow:** `ANativeWindow_setPerformInterceptor` — interceptor callback `int(*)(ANativeWindow*, int op, va_list, ...)`; the `va_list` contents depend on `op` and need per-op interpretation plus arm64→x86_64 va_list re-packing. Private (system) debug/interception hook.
- **libwebviewchromium_plat_support:** `JNI_OnLoad(JavaVM*, void*)` — the proxy lib's own load-time entry, with dedicated native-bridge handling. `JavaVM*` is translatable in-surface (`ToHostJavaVM`), but as the standard JNI load-time entry point it is the special native-bridge case rather than an app-called symbol; the observed path is apps calling the individual `Register*` symbols directly (now covered, see below), so this one is left deferred. The other 17 of this library's 18 symbols are covered in `digitalis_extra_libwebviewchromium_plat_support_trampolines.cc`.

## 2-covered. What Digitalis already covers in-surface

These were `DoBadTrampoline` upstream and are now forwarded correctly from
`digitalis_extra_proxy/`. Listed so the gap accounting above is auditable.

- **libbinder_ndk (2):** `AServiceManager_NotificationRegistration_delete` (flat `void(void*)` pointer pass-through) and `AServiceManager_registerForServiceNotifications` (its `OnRegister` guest callback is wrapped with `WrapGuestFunction`, so the host can invoke it back through the translator on any host-spawned thread). See `digitalis_extra_libbinder_ndk_trampolines.cc`. **Regression sample:** `hello-binder-ndk`'s `ProbeServiceNotifications()` `dlopen`s `libbinder_ndk.so` and calls both — `register…ForServiceNotifications(instance, OnServiceRegister, nullptr)` (driving the `WrapGuestFunction` callback path) followed by `NotificationRegistration_delete(reg)`; either lost trampoline aborts with `Bad '<sym>' call`.
- **libcamera2ndk (2):** `ACameraCaptureSessionShared_startStreaming` and `ACameraCaptureSessionShared_logicalCamera_startStreaming`. Each takes a callbacks-struct of one `void* context` + seven distinct fixed-signature callback function pointers (`ACameraCaptureSession_captureCallbacksV2` / `…_logicalCamera_captureCallbacksV2`, `NdkCameraCaptureSession.h:863`/`:914`). The trampolines (`digitalis_extra_libcamera2ndk_trampolines.cc`) extract the params with `GuestParamsValues`, build a host callbacks-struct by wrapping every callback with `WrapGuestFunction` (per `camera2ndk_shared_capture_callbacks.h`'s `Marshal{,LogicalCamera}CaptureCallbacksV2`), and forward to the dlsym'd host symbol; the remaining params (`int numOutputWindows`, `ANativeWindow** windows`, `int* captureSequenceId`) are flat LP64 pass-throughs. **Verification (the only risky part is the per-field callback marshalling):** the shared-camera API itself cannot be opened on the Digitalis emulator — `ACameraManager_openSharedCamera` needs `SYSTEM_CAMERA` (`system|signature|role`, ungrantable to an `adb install` sample) **and** an AIDL HAL with shared-session support (the emulator's HIDL `device@1.1` camera reports `isCameraDeviceSharingSupported == false`), so no sample can fire the callbacks end-to-end. But end-to-end exercise is *not* required to verify the marshalling: the host test `camera2ndk_shared_capture_callbacks_test.cc` (`Arm64Camera2NdkCaptureCallbacksV2Test`, 12 cases, in `berberis_arm64_host_tests`) builds a guest "recorder" function, points each callback field at it, marshals, then fires every wrapped host thunk with distinct sentinel arguments and confirms the guest received each in the right AAPCS64 register with the right width/order — checking the exact signatures from `NdkCameraCaptureSession.h` (including the 7-argument `onLogicalCameraCaptureCompleted` and the 32-bit `int sequenceId` truncation). The struct layout is pinned by `static_assert` on `offsetof`/`sizeof` in the header. This is ground-truth verification against the NDK header — not the forbidden blind/guessed marshalling, which is what a forwarding-only null-session smoke test would have been. A regressed/unregistered trampoline aborts with `Bad '<sym>' call`; a wrong field would land a sentinel in the wrong slot and fail the host test.
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
- **A struct of fixed-signature callbacks IS coverable** — wrap each field as above into a host callbacks-struct and forward (`libcamera2ndk`'s `…Shared_startStreaming` pair, `camera2ndk_shared_capture_callbacks.h`). Two correctness obligations: (1) **layout** — pin it with `static_assert(offsetof/sizeof)` against the NDK header (a flat array of 8-byte pointers under LP64 makes this trivial); (2) **per-callback signatures** — get them exactly right, since a wrong arg type/order silently mis-delivers a value rather than crashing. **Verify the marshalling with a host test even when the API can't run end-to-end on the emulator:** assemble a guest "recorder" that stores its argument registers, point each callback at it, marshal, fire every wrapped thunk with sentinel args, and confirm the guest saw each in the right AAPCS64 slot/width. Being un-runnable end-to-end (a permission or HAL gate on the *API*) is a testability limit on the API, not an expressibility limit on the trampoline — it does not justify deferring, and a forwarding-only null-session smoke test would verify *nothing* about the per-field marshalling (that is the forbidden blind path).
- **Mangled C++ is not automatically out of scope.** "Internal `_ZN7android…` C++" is a *heuristic* for "NDK apps never call it," not a hard rule. When such a symbol has a **flat C-ABI signature** (int / long / void* / void** / an enum, all LP64-identical between guest and host) and an app actually calls it, it forwards directly through `GetTrampolineFunc` like any pointer/int symbol — the mangling is irrelevant to marshalling. `libwebviewchromium_plat_support`'s `GraphicBufferImpl::*` static/instance methods (`Create`/`Release`/`MapStatic`/…) are exactly this: mangled, but flat, and covered. The genuinely-uncoverable mangled symbols are the ones that aren't flat — by-value `sp<>` returns, C++ ABI types — not all mangled symbols.
- **A host-registration entry point taking `JNIEnv*` needs a *host* env, not a translated guest one.** `ToHostJNIEnv` is for forwarding a call the guest makes *with its own env*; a symbol that runs `jniRegisterNativeMethods` on the **host** VM (e.g. `android::Register{DrawFunctor,DrawGLFunctor,GraphicsUtils}(JNIEnv*)`) needs a valid host env for the current thread. These are called from guest-spawned worker threads never attached to the host VM, so translating the guest env yields a null host env and the host function SIGSEGVs on its first `*env`. The trampoline instead fetches a host env from the captured host `JavaVM` (`GetHostJavaVM()` + `GetEnv`, attaching the thread if detached and detaching afterwards) and forwards. This is the reusable pattern for any JNIEnv-taking host-side `RegisterNatives` symbol.
- **Printf-style varargs (`fmt, ...`) ARE coverable when the function consumes its own format string.** A true-varargs forwarder cannot rebuild a host `va_list`, but a printf-family symbol does not need one: read the named params with `GuestParamsValues<Ret(Named..., ...)>`, then walk the variadic tail per AAPCS64 with `GuestVAListParams` (constructed from those named params — it tracks the int/SIMD/stack cursor and handles register→stack overflow), feeding each argument to `FormatBufferImpl` via a small adapter (mirror `guest_loader.cc`'s `FormatBufferGuestParamsArgs`). Format host-side into a fixed buffer and call the non-varargs sink yourself. `libnativehelper`'s `jniThrowExceptionFmt` is covered this way (format → `JNIEnv::FindClass`+`ThrowNew`). Caveat: `FormatBufferImpl` handles integer/string/pointer specifiers but **not** floating-point (`%f`/`%g`/`%e`) — fine for error-message formatters, but verify the symbol's callers don't rely on float conversions before covering it this way.
- **Not coverable:** variadic *callbacks* (the guest is the callee and we don't control a format string), an opaque `va_list` re-pack into a host varargs call, fn-ptr *returns* of unknown signature, struct-of-many-callbacks that can't be layout/signature-verified, and C++-mangled / by-value-`sp<>` symbols (not the C ABI, not NDK-stable). (A printf-style `fmt, ...` symbol whose format string IS the spec is coverable — see the bullet above.)
