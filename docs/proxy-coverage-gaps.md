# Proxy-library symbol coverage (`DoBadTrampoline`)

> **No-crash guarantee (2026-07-12, re-verified 2026-07-11 counts).** No app can hit a
> `Bad '<sym>' call` SIGABRT from a remaining `DoBadTrampoline` symbol. Every one is
> **covered** (upstream or Digitalis trampoline), **contract-stubbed** (the three
> reachable NDK-stable terminals: `AIBinder_toPlatformBinder` → null `sp<>`,
> `glGetVkProcAddrNV` → NULL, `ANativeWindow_setPerformInterceptor` → no-op), or caught
> by the loud arm64-only `DoGracefulBadTrampoline` **net** (greppable `BAD-TRAMPOLINE`
> trace + zeroed x0 instead of an abort; riscv64/arm keep the fatal path). Proven by
> `digitalis/scripts/enumerate-proxy-bad-symbols.py`, which fails if any unmangled-C
> symbol is neither covered nor allowlisted (`proxy-bad-symbol-allowlist.txt`); the
> generated audit is `proxy-bad-symbol-audit.md` (currently **0 uncovered**).

A proxy library forwards each guest `lib*.so` symbol to the host. The generated
trampoline tables (`native_bridge_support/.../trampolines_arm64_to_x86_64-inl.h`,
read-only) mark a symbol `DoBadTrampoline` when the auto-generator could not marshal
its signature; calling one aborts with `LOG_ALWAYS_FATAL("Bad '<sym>' call")`.

Digitalis closes gaps **entirely within `binary_translation/`** from
`android_api/digitalis_extra_proxy/`, via three registration mechanisms in the
arm64-only extras support of `proxy_loader/proxy_library_builder.cc`:

1. **`DoBadTrampoline` overrides** (`RegisterExtraTrampolines`) — a symbol the
   upstream table *has* but marked bad. These are the gaps tracked here.
2. **Missing-symbol additions** (same API, primary-table-*miss* path) — a symbol
   the upstream proxy omits entirely. Never aborts; listed in §3 for completeness.
3. **Overrides of a working-but-incomplete primary trampoline**
   (`RegisterExtraTrampolineOverrides`) — the override chains to the upstream
   trampoline and post-processes its result (libEGL `eglGetProcAddress`, §3).

## Scope: remaining arm64 `DoBadTrampoline` gaps

Counts are for the **arm64** table only (`grep -c DoBadTrampoline` per upstream
`trampolines_arm64_to_x86_64-inl.h`).

| Library | upstream arm64 `DoBadTrampoline` | Digitalis covers | remaining | nature of the remaining gap |
|---|---:|---:|---:|---|
| libEGL | 8 | 0 | 8 | internal C++ (`egl_display_t::*`, `egl_get_connection`, `setGlThreadSpecific`) — mangled, unreachable-by-app, net |
| libGLESv2 | 1 | 1 | 0 | contract-stubbed — `glGetVkProcAddrNV` → NULL (GFXStream lacks the NV extension) |
| libGLESv3 | 1 | 1 | 0 | contract-stubbed — `glGetVkProcAddrNV` → NULL (GFXStream lacks the NV extension) |
| libnativewindow | 1 | 1 | 0 | contract-stubbed — `ANativeWindow_setPerformInterceptor` → no-op (va_list callback, private) |
| libandroid | 0 | 0 | 0 | — (public C API fully marshaled upstream) |
| libbinder_ndk | 3 | 3 | 0 | contract-stubbed — `AIBinder_toPlatformBinder` → null `sp<>` (by-value C++ return) |
| libcamera2ndk | 2 | 2 | 0 | covered — shared-camera V2 callback-struct trampolines, host-test-verified |
| libnativehelper | 31 | 13 | 18 | ~15 `JniConstants_*` + `JniInvocation*`/`EnsureInitialized` — internal/launcher, net |
| libwebviewchromium_plat_support | 18 | 17 | 1 | `JNI_OnLoad` — load-time entry, net |
| libandroid_runtime | 1135 | 0 | 1135 | not app-reachable (not public LL-NDK) → mangled/allowlisted net |

Excluding `libandroid_runtime` (not app-reachable; every entry rides the net), the
app-facing libraries carry **65** arm64 `DoBadTrampoline` entries; Digitalis covers
**38**. The **27** remaining (8 libEGL mangled-internal + 18 nativehelper
launcher/cache + 1 webview `JNI_OnLoad`) are not NDK-stable / not app-reachable, so
they ride the loud net rather than aborting — see `proxy-bad-symbol-audit.md`.

## 1. Internal C++ symbols — not NDK-stable, out of scope

Mangled `_ZN7android...` symbols are usually a library's own implementation classes,
called only host-side behind the public C API. (A mangled symbol an app *does* call
directly with a flat C-ABI signature is coverable and not listed here — see the
technique reference.)

- **libEGL (8):** `android::egl_display_t::{makeCurrent,loseCurrent,loseCurrentImpl,addObject,removeObject,getObject}`, `android::egl_get_connection`, `android::setGlThreadSpecific`. The public EGL C API is covered upstream.
- **libnativehelper (~17 of 31):** `JniConstants_*` caches, `JniInvocationCreate/Destroy/Init`, `EnsureInitialized` — runtime-launcher internals, not in `<nativehelper/JNIHelp.h>`, never called by NDK apps.
- **libandroid_runtime (~all 1135):** framework internals; the lone NDK-stable trio `AFileDescriptor_{create,getFd,setFd}` is a red herring — apps resolve it via `libnativehelper.so`, where the **upstream** proxy already covers it, so the `libandroid_runtime` copies are unreachable duplicates.

## 2. Hard — NDK-stable/extension but un-marshalable

Terminal dispositions (the C ABI cannot express a correct forwarder); re-open a
bullet only if its stated blocker changes.

- **libGLESv2/v3 `glGetVkProcAddrNV` (contract-stubbed → NULL):** returns a function
  pointer, but GFXStream does not implement `GL_NV_draw_vulkan_image`, so the host
  returns NULL and there is nothing to wrap; NULL is the documented "unavailable"
  contract. See `DoStub_glGetVkProcAddrNV`.
- **libnativewindow `ANativeWindow_setPerformInterceptor` (contract-stubbed → no-op):**
  the interceptor callback takes an op-dependent `va_list`; correct forwarding needs a
  per-op va_list re-packer. Private debug hook with no known caller; stubbed to
  install nothing.
- **libwebviewchromium_plat_support `JNI_OnLoad`:** the proxy lib's own load-time
  entry with dedicated native-bridge handling; apps call the individual `Register*`
  symbols directly (covered), so this stays deferred.

## 2-covered. What Digitalis covers in-surface

Formerly `DoBadTrampoline`, now forwarded from `digitalis_extra_proxy/`:

- **libbinder_ndk (2):** `AServiceManager_NotificationRegistration_delete` (flat
  pointer pass-through) and `AServiceManager_registerForServiceNotifications` (its
  guest callback wrapped with `WrapGuestFunction`). Regression sample:
  `hello-binder-ndk` calls both.
- **libcamera2ndk (2):** the shared-camera V2 `…startStreaming` pair. Each takes a
  callbacks-struct of one context pointer + seven fixed-signature callbacks; the
  trampolines wrap every field with `WrapGuestFunction` and forward. The API cannot
  run end-to-end on the emulator (system-permission + HAL gates), so the marshalling
  is verified by the host test `Arm64Camera2NdkCaptureCallbacksV2Test` (guest
  "recorder" + sentinel arguments per AAPCS64 slot) and the struct layout is pinned
  with `static_assert` against the NDK header.
- **libnativehelper (13):** the 12 flat `jniThrow*`/`jniCreateString`/`jniGetNioBuffer*`/
  `jniRegisterNativeMethods` helpers (leading `JNIEnv*` translated with
  `ToHostJNIEnv`), plus the varargs `jniThrowExceptionFmt` — formatted host-side by
  walking the guest variadic tail per AAPCS64 (`GuestVAListParams` +
  `FormatBufferImpl`; integer/string specifiers, no floating-point) and thrown via
  the translated env. Regression sample: `hello-jnihelp` drives all 13 against
  ground truth, including an 8-conversion format spanning register- and
  stack-passed varargs.
- **libwebviewchromium_plat_support (17):** the 3 `android::Register*(JNIEnv*)`
  host-side registration entry points (host-env-attach pattern, below),
  `RaiseFileNumberLimit`, and the 13 flat-C-ABI `GraphicBufferImpl::*` methods.
  Unblocks WebView hardware-accelerated drawing under translation. Regression
  sample: `hello-webview-functor` drives all 17.

## 3. Other mechanisms (not `DoBadTrampoline`)

- **libc (32) / libm (15) missing-symbol additions:** fast-path trampolines for
  symbols the upstream proxy omits (`isnan`/`__fpclassify` family, `memrchr`,
  `__memcpy_chk`/`__memset_chk`, the `*64` stat/mmap family, `cospi`/`sinpi`,
  `ldexpf`, the `__*_finite` math entry points). All flat LP64 signatures via
  `GetTrampolineFunc<>`. Regression sample: `hello-libc-libm` value-checks each.
  (`cospif`/`sinpif` are unreachable — the guest `libm.so` does not export them —
  but harmless.)
- **libEGL `eglGetProcAddress` override (~80 ANGLE/CHROMIUM extension procs):** the
  upstream trampoline NULLs the guest return for any proc its generated wrap table
  can't marshal, but ANGLE (the host GLES driver) *advertises* the matching
  extensions — and browser-engine GL bindings gate calls on the extension string,
  not the probed pointer, so an advertised-but-NULLed proc (e.g.
  `glGetIntegervRobustANGLE`) sends the GPU process to guest PC 0 in a crash loop.
  Covered with mechanism 3 (override-with-chaining): the override runs the upstream
  trampoline first (its core-GL wrap table intact), then wraps the procs upstream
  NULLed — the `GL_ANGLE_robust_client_memory` set, `get_tex_level_parameter`,
  `multi_draw`, `polygon_mode`, `request_extension`, `shader_pixel_local_storage`,
  `CHROMIUM_copy_texture`/`bind_uniform_location`, `memory_object_flags`,
  `vulkan_image`, the blob-cache/EGL-debug callback procs (`WrapGuestFunction`),
  and the sync-control queries. Extensions never advertised on Android (D3D, Metal,
  macOS GPU power) deliberately stay NULL. Regression sample: `hello-eglext`
  enforces *advertised-implies-non-NULL* in a real ES2 context and cross-checks the
  wrapped robust getters bit-exact against the core `glGet*` API.
- **Host-call redirect:** `digitalis_host_call_redirect.cc` installs a
  `HandleNoExec` hook so a hardened guest library that branches *directly into a
  host system library's x86_64 code* is redirected to the **guest** copy of the
  same symbol instead of crashing.
- **Guest-library stub:** when a guest library `dlopen`s a whole system library
  Digitalis does not proxy, a minimal guest-only stub (e.g.
  `digitalis_libgui_stub/` → `/system/lib64/arm64/libgui.so`, exporting the
  observed `dlsym` targets as no-ops) keeps the load/present path from faulting.
  New no-op symbols are added on observed need.

## Technique reference — what makes a gap coverable

- **Pointer/int signatures:** `GetTrampolineFunc<…>` with `void*` for pointers
  (valid under LP64 when the pointee layout matches).
- **`JNIEnv*`/`JavaVM*` arguments:** translate with `ToHostJNIEnv`/`ToHostJavaVM` —
  a pass-through is wrong (the guest env holds guest-callable function pointers).
  Reach the host function via the dlsym'd `callee` so no link dependency is added.
- **Fixed-signature callbacks:** wrap with `WrapGuestFunction<Ret, Args…>` — the
  host-callable thunk routes through `RunGuestCall`, which auto-attaches a guest
  thread to any host-spawned callback thread, so async delivery is safe.
- **A struct of fixed-signature callbacks IS coverable:** wrap each field and
  forward. Pin the layout with `static_assert(offsetof/sizeof)` and verify the
  per-field marshalling with a host test (recorder + sentinel args per AAPCS64
  slot) — an API being un-runnable end-to-end on the emulator is a testability
  limit, not an expressibility limit.
- **Mangled C++ is not automatically out of scope:** a mangled symbol with a flat
  C-ABI signature that an app actually calls forwards like any pointer/int symbol.
  The genuinely uncoverable mangled symbols are the non-flat ones (by-value `sp<>`,
  C++ ABI types).
- **Host-side `RegisterNatives` entry points need a *host* env:** fetch it from the
  captured host `JavaVM` (`GetHostJavaVM()` + `GetEnv`, attach/detach as needed) —
  translating the guest env of a never-attached worker thread yields null.
- **Printf-style varargs (`fmt, ...`) ARE coverable when the function consumes its
  own format string:** read the named params, walk the variadic tail with
  `GuestVAListParams`, format host-side (`FormatBufferImpl`; no floating-point
  specifiers), and call the non-varargs sink directly.
- **A healthy-but-incomplete primary trampoline needs an OVERRIDE, not an extra:**
  the plain extras registry only fires on a primary miss or `DoBadTrampoline`.
  `RegisterExtraTrampolineOverrides` hands the override a
  `ChainedTrampoline{primary_marshal, primary_thunk}` callee; run the primary first
  (`chain->marshal_and_call(chain->thunk, state)`), and read any input params
  *before* chaining — x0 doubles as the return register.
- **GetProcAddress-style APIs must keep the advertised-implies-non-NULL contract:**
  returning NULL for a proc whose extension the driver advertises is a landmine —
  string-gated callers jump to it.
- **Not coverable:** variadic *callbacks*, opaque `va_list` re-packs, fn-ptr
  *returns* of unknown signature, unverifiable callback-struct layouts, and
  by-value-`sp<>`/C++-ABI symbols.
