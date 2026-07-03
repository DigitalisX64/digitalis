# Emulator-exhaustion flaky SIGSEGV — signature, mechanism, mitigation

After a long test session (many install/launch/uninstall cycles, especially
after a heavy game has aborted the emulator's GPU state), the prebuilt-APK gate
starts failing — but a **different app fails each run**, all with the same
signature:

```
Fatal signal 11 (SIGSEGV), code 2 (SEGV_ACCERR), fault addr 0x76d6b82..fff0
```

Each app **passes in isolation**. `adb reboot` (data persists) restores a clean
baseline. It has polluted several gate runs in one day (VkCaps, amap, Kuaishou).

This note disentangles the two distinct resource concerns that get conflated
under "exhaustion", records why the *specific* flake above is host-side
(emulator/gfxstream) rather than a Berberis bug, and documents the repro tooling
and the mitigation.

## The tell: it is a *constant HIGH host address*, not a translator fault

The faulting address is **`0x76…fff0`**:

- **High 64-bit address** (`0x76xxxxxxxxxx`), not the low-2 GB `MAP_32BIT`
  range (`0x52…`) where Berberis puts its executable code. So it is **not** a
  jump into a Berberis JIT region and **not** the exec-region leak below.
- **Same address region every run, across different apps.** A per-app
  translator bug (bad decode/codegen) would fault at *app-specific* guest/host
  addresses, not a single constant one shared by unrelated apps. A constant
  address that appears identically in every guest process is a mapping
  established the same way at process / graphics init — i.e. a host-side shared
  mapping (gfxstream ring/command buffer, a proxied host library, or a
  host-emulator structure), not app code.
- **`SEGV_ACCERR`, not `SEGV_MAPERR`.** The page *is* mapped; the access was
  permission-denied (e.g. write to a now-read-only page, or execute of a
  now-non-exec page). Consistent with a shared host buffer whose backing was
  torn down / re-protected host-side while a guest still holds the mapping.
- **`…fff0`**: 16 bytes before a page boundary — the tail of a mapping.
- **`adb reboot` clears it.** A host-side resource that resets with the
  emulator, not persisted guest state.

Taken together (constant high host address + different app each run + ACCERR +
reboot-clears) this is an **environmental host-side resource exhaustion in the
prebuilt emulator / gfxstream**, outside both Berberis and the Digitalis
modification surface — the same class as the GFXStream `VK_EXT_memory_budget`
abort documented in the 2026-06 prebuilt triage. It is **not** a decoder /
interpreter / lite / heavy translator bug.

## The separate, in-surface concern: the CodePool exec-region leak (b/232598137)

While chasing the flake we quantified a *real* monotonic leak that is often
lumped in with it but is a **different address range and a different mechanism**:

- Berberis executable code lives in `ExecRegion`s (`code_pool.h`,
  `exec_region_anonymous.cc`). Each region is **two mappings of one memfd**: a
  `PROT_READ|PROT_EXEC` alias in `MAP_32BIT` (low 2 GB, `0x52…`) and a
  `PROT_READ|PROT_WRITE` alias in normal 64-bit space (`0x74…`).
- When a region fills, `CodePool::Add` calls `ResetExecRegion` →
  `ExecRegion::Detach()`, which **munmaps only the writable alias**. The
  **executable alias is never unmapped** (old translations may still be running
  from it): `Free()` — which would unmap both — is never called by `CodePool`.
  `detached_size_` just accumulates. This is the standing
  `TODO(b/232598137): Consider freeing allocated regions.`

Measured directly on a booted device (2026-07-04):

| Process | Age | memfd:exec VMAs | low-2 GB exec-alias KB | writable-alias VMAs |
|---------|-----|-----------------|------------------------|---------------------|
| `com.autonavi.minimap` (amap) | ~1.5 h | 32 (r-xs, all 4 MB, contiguous `0x52001000`→`0x59d9a000`) | **127 488 KB (~124 MB)** | 2 (correctly freed) |
| `com.facebook.katana` | ~1.5 h | 10 | ~33 MB | — |

Even a *fresh cold launch* already burns 45–66 MB of exec aliases
(coolapk 14 regions, netease 19, wechat 17) because `ResetExecRegion` fires many
times during startup. The writable alias is correctly reclaimed (only 1–2 remain
per process); the executable alias grows monotonically for the life of the
process.

**Is this the flake?** No — the leak lives in low-2 GB (`0x52…`); the flake
faults in high memory (`0x76…`). And exhausting the 2 GB `MAP_32BIT` arena would
require ~500 × 4 MB regions in a *single* process; when it *did* run out it would
`FATAL`/abort inside `MmapImplOrDie` (now self-diagnosing — it prints
`prot=…flags=…: <errno>`), i.e. a SIGABRT with a clear message, not a
`SEGV_ACCERR` at a high address. So the leak is a genuine long-run risk (memory
bloat, and an eventual abort for a very long-lived heavy translator process) but
is a **distinct issue from the reported flake**.

Fixing the leak in-surface means a real exec-region GC: you cannot unmap a
region while any thread may still execute code inside it, so it needs
epoch/refcount tracking of live regions across all guest threads — a
non-trivial, multi-cycle change, deferred here. It is filed as the lever if the
low-2 GB pressure ever becomes the observed failure (it is not today).

## Repro + instrumentation: `digitalis/scripts/soak-prebuilts.sh`

The driver loops the prebuilt launch cycle on an already-booted emulator while
sampling, per guest app process and for the host, into a CSV:

- total VMA count, `memfd:exec` region count + KB,
- **low-2 GB exec-alias KB** (the b/232598137 leak metric),
- host emulator (`qemu-system-x86_64`) RSS,

and scans logcat + the emulator log each round for the `SEGV_ACCERR` /
gfxstream-abort signatures, appending the first hit (with faulting address and
the live app maps) to `flakes.log` so a soak that finally trips is
self-documenting.

```bash
# Churn mode (default): force-stop + relaunch every app each round (fresh pid).
# Reproduces the per-launch flake; tracks per-cold-launch footprint + host RSS.
ROUNDS=40 SOAK_WATCH_SECONDS=12 digitalis/scripts/soak-prebuilts.sh

# Persist mode: launch each app once, keep it alive across rounds, re-sample the
# SAME pids — watch the exec-region leak grow within a long-lived process.
SOAK_PERSIST=1 ROUNDS=40 digitalis/scripts/soak-prebuilts.sh
```

Output: `/tmp/soak-prebuilts/samples.csv` (per-round samples) and
`/tmp/soak-prebuilts/flakes.log` (caught signatures). To decode a caught fault,
read the address printed in `flakes.log` and cross-reference it against the
faulting process's `/proc/<pid>/maps` (also captured) — a high `0x76…` address
in an `r--`/`---` region confirms the host-side hypothesis; a low `0x52…`
address in a `memfd:exec` region would instead implicate the JIT.

The direct one-shot leak measurement (no soak needed) is:

```bash
adb shell "grep memfd:exec /proc/<pid>/maps" | awk '{split($1,a,"-");
  s=strtonum("0x"a[1]); e=strtonum("0x"a[2]);
  if (s<2147483648) k+=(e-s)/1024} END{printf "low-2GB exec-alias: %d KB\n", k}'
```

## Mitigation (current)

1. **Scheduled `adb reboot` between long gate sessions.** Data persists across a
   reboot, so the prebuilt set stays installed; the reboot clears the host-side
   exhaustion and restores a clean baseline. Do this after any session that ran
   heavy games (which abort the emulator's GPU state) or many launch cycles.
2. **Test heavy games one at a time and reboot between batches** — a GPU/OOM
   abort cascades into false "process died" for every app tested after it.
3. **A different-app-each-run failure at a constant high host address
   (`0x76…fff0`, `SEGV_ACCERR`) is the environmental tell** — do not chase it as
   a translator regression. Confirm by re-running the failing app in isolation
   (it passes) and grepping the trace for `Guest signal`/`Undefined arm64`
   (absent). Reboot and re-gate.
4. **Watch the leak metric** with the soak driver's persist mode on genuinely
   long-lived processes; if low-2 GB exec-alias KB approaches the 2 GB ceiling in
   a real workload, escalate the b/232598137 exec-region GC.

## Status

Environmental host-side exhaustion — **documented signature + mitigation
(this note)**; no in-surface translator fix warranted for the flake itself. The
CodePool exec-region leak is a separate, genuine long-run concern with a known
(hard) lever (b/232598137 GC), deferred until it is the observed failure.
