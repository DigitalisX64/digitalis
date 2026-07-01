<!-- Copyright (C) 2026 utzcoz. Licensed under the Apache License, Version 2.0. -->

# Diagnosing a Digitalis crash on a virtio-x86_64 build

If a build that integrates the Digitalis ARM64→x86_64 native bridge still
crashes an app (e.g. Helium/Chromium) after applying the translation-cache
patch, run the collector below and send back the resulting tarball. It gathers
exactly the fields needed to tell the candidate causes apart, and prints a
summary that interprets them.

## Run it

```bash
# from a host with `adb`, one device/emulator connected:
digitalis/scripts/collect-digitalis-crash.sh io.github.jqssun.helium
#   arg 1 = package to reproduce (default Helium)
#   arg 2 = optional explicit "pkg/activity" to launch
```

It launches the app, samples live processes while it runs, then collects
tombstones, logcat, `dmesg`, the resource ceilings, and a full `adb bugreport`
(the bugreport is the fallback that works even on `user` builds where
`/data/tombstones` can't be pulled directly). Output: `digitalis-crash-<ts>.tar.gz`
plus a printed `SUMMARY.txt` that interprets the fields. **Send the tarball.**

## What the crash actually is, and the three things that decide the fix

The reference failure is the translator's own `mmap()` returning `ENOMEM`, which
`MmapImplOrDie` turns into a fatal abort. The tombstone shows it as:

```
Abort message: 'frameworks/libs/binary_translation/base/mmap_posix.cc:128:
  CHECK failed: 0xffffffffffffffff != 0xffffffffffffffff'
```

`mmap()` returns `ENOMEM` for three different reasons, and **each needs a
different fix**, so the summary compares:

| Candidate cause | Evidence to compare | If it matches |
|---|---|---|
| **VMA count ceiling** (`vm.max_map_count`) | tombstone's `memory map (N entries)` **vs** `vm.max_map_count` | Raise `vm.max_map_count`. The 64 MB memfd-region patch also cuts this structure's VMAs ~4×. |
| **Address-space ceiling** (`RLIMIT_AS`) | a live process's `VmPeak` **vs** its `Max address space` limit | The 64 MB patch does **not** help. Needs a larger `RLIMIT_AS` for the app's child processes, or the structural table redesign. |
| **Strict overcommit** (`vm.overcommit_memory=2`) | `Committed_AS` **vs** `CommitLimit` in `/proc/meminfo` | Raise `CommitLimit`/`overcommit_ratio` or add swap. Not a translator bug. |

**Important reading of the reference data:** the crashing process had only
`memory map (4701 entries)` — far below the default `vm.max_map_count` of 65530,
and even below a *healthy* emulator run of the same app (5468 VMAs, where it does
not crash). So on that capture the VMA ceiling was **not** the trigger, and the
patch alone likely won't fix it. The emulator where Helium works reports
`RLIMIT_AS = unlimited` and `vm.overcommit_memory = 1`; if your virtio build
differs on either of those, that difference is the cause. The summary is built to
expose exactly this: if your `memory map (N entries)` is similarly ~5000 while
`vm.max_map_count` is ~65530, the cause is one of the other two rows — report
`RLIMIT_AS` and the overcommit fields so the real fix can be chosen.

A **different** abort message means a **different** bug — in that case the
tombstone backtrace + logcat localize it; add the translator trace (step 5).

## Two independent problems

1. **The `mmap` ENOMEM abort** above (kills the GPU/renderer child).
2. **No GPU driver** — on the reference build, `SurfaceFlinger` itself aborts at
   boot with *"couldn't find an OpenGL ES implementation"*. Even with (1) fixed,
   Chromium's GPU process then times out (`Timed out waiting for GPU channel`).
   This is a product-integration gap (needs a GLES/Vulkan driver, e.g.
   gfxstream/ANGLE), **not** a translator bug. `collect-digitalis-crash.sh`
   captures both; check `logcat.txt` for the SurfaceFlinger/EGL line.

## Step 5 (optional) — translator trace for a *different* crash

Only needed when the abort message is **not** the `mmap` CHECK (a wrong-output
or a different SIG*). Requires root:

```bash
adb root && adb shell setenforce 0                    # Permissive: needed to set the prop
adb shell setprop berberis.tracing '<pkg>=digitalis-trace.log'
adb shell am force-stop <pkg>; adb shell monkey -p <pkg> -c android.intent.category.LAUNCHER 1
sleep 20
adb shell "chmod 644 /data/user/0/<pkg>/digitalis-trace.log"
adb pull /data/user/0/<pkg>/digitalis-trace.log
adb shell setenforce 1                                 # RESTORE Enforcing when done
```

The trace's `trans#N pc=… JIT|INTERP` and `interp #N pc=…` lines, cross-referenced
against the `link_map[i]: <base> <lib>` lines, point at the offending guest PC.
Send `digitalis-trace.log` alongside the tarball.
