# Benchmarking Digitalis

How translation performance is measured in this tree: the harness, the runner,
the methodology rules, and the traps that have already produced wrong numbers
once. Read this before quoting any figure.

## Architecture

Three pieces, all in-tree:

1. **`sample/hellodigitalis/bench-lib/`** — a small timing library. A sample
   calls `Bench.run(module, case, warmup, iters) { body }` for each workload
   and `Bench.done(module)` when finished. Every case emits one
   machine-readable logcat line under the `DigitalisBench` tag:

   ```
   BENCH {"schema":1,"module":"hello-zstd","case":"compress-1MB-level3",
          "warmup":5,"iters":30,"min_ns":...,"median_ns":...,"ns":[...]}
   ```

   The raw per-iteration array `ns` is always included: variance is analysed
   on the host, never averaged away on the device. Failures emit `BENCH_FAIL`
   so a broken workload cannot masquerade as a missing row.

2. **`digitalis/scripts/run-benchmarks.sh`** — sweeps translation modes
   (`interpret-only`, `lite-translate-or-interpret`, `two-gear`), launching
   each benchmark module per mode and collecting the `BENCH` lines into
   newline-delimited JSON under `digitalis/out/bench/<stamp>.ndjson` (ignored
   by git; runs are machine-specific point-in-time data). Modules enrol
   themselves: any sample whose `build.gradle.kts` depends on
   `project(":bench-lib")` is discovered automatically — adding a benchmark
   needs no runner edit.

3. **`digitalis/scripts/summarize-benchmarks.py`** — per case and mode:
   median, relative interquartile range, and speedup against the
   `interpret-only` baseline. Any case above **10% relative IQR is flagged
   unreliable** and must not be quoted.

## Running

```bash
# emulator up, then:
digitalis/scripts/run-benchmarks.sh                    # all modes, all modules
digitalis/scripts/run-benchmarks.sh --modes two-gear   # one mode
digitalis/scripts/run-benchmarks.sh --repeats 3
digitalis/scripts/summarize-benchmarks.py digitalis/out/bench/<stamp>.ndjson
```

Requirements the runner enforces rather than assumes:

- **`adb root`** — `berberis.mode` is not writable by the shell user. The
  runner fails loudly instead of silently measuring the default mode.
- **Force-stop between runs** — the translation mode is read once at
  translator init; changing the property under a live process measures the
  previous mode.
- **`pm clear` once per module per sweep** — see the first trap below.

## Methodology rules

These are load-bearing; each exists because its absence produced a wrong
number.

1. **Size iterations into the millisecond range.** Below ~1 ms per iteration,
   emulator scheduling jitter dominates: an early 280 µs SGEMM case measured
   890% relative IQR. Batch small operations (`repeat(20) { sign() }`) rather
   than shrinking the work.
2. **Hoist setup out of the timed body — especially code generation.** A
   benchmark that recompiles a PCRE2 pattern per call re-emits guest code
   every iteration; each regeneration IC-IVAU-flushes the old translations
   and forces the translator to re-translate (and, in two-gear, re-profile
   and re-gear-up) every cycle. That measures regeneration churn, not
   matching.
3. **Warmup covers translation *and* gear-up.** The first pass through a
   region is translation; the second gear engages only after a region crosses
   the hotness threshold (1000 entries). Warmup iterations must run the hot
   loop past that threshold or two-gear numbers include promotion cost.
4. **Report per-workload, never a headline speedup.** Measured JIT-vs-
   interpreter gains in this suite span 4× (memory-bound zstd decompression)
   to 44× (compute-bound bcrypt). A single average of those is meaningless.
5. **Respect the noise flag.** Rows the summariser marks above 10% relative
   IQR are re-run or resized, not quoted with a caveat.
6. **Keep the correctness probe.** Every benchmark module retains its
   original golden self-check (`ZSTD OK`, `PCRE2 OK`, …); a run whose probe
   fails is discarded regardless of its timings.

## Traps that have already burned a cycle

- **The stale-extract trap.** Digitalis extracts in-APK guest `.so` files
  into app data, and `adb install -r` does **not** invalidate the extract:
  after a reinstall, the app can silently keep executing the old native
  library. This once manufactured a fictitious 7.7× translator regression —
  the "slow" runs were executing a pre-fix benchmark binary while the fixed
  APK sat installed. The runner now `pm clear`s each module per sweep; when a
  result looks impossible anyway, verify *which binary ran* (fresh
  `pm clear`, or check `/proc/<pid>/maps`) before theorising.
- **Guest-JIT workloads interact with tiering.** Code that an app generates
  at runtime (sljit, JS engines) is translated like any other guest code, but
  if the app *regenerates* it frequently, two-gear re-pays heavy translation
  plus warm-up per regeneration cycle where lite pays only a cheap re-lite.
  Steady-state guest-JIT code shows no such penalty (two-gear ties or wins).
  Distinguish the two cases before attributing a slowdown to the translator.
- **Sampled diagnostics lie by omission.** Logging `n <= 5 || n % 10000 == 0`
  once made "attempt#5" read as "only 5 attempts" when the true count was
  anywhere below 10000. Instrument with cumulative counters.

## Distance to native

`benchmarks/standalone/` builds the bcrypt workload as static binaries for
arm64 and x86_64 from the sample's vendored sources (same NDK compiler, same
flags, same bionic), so the x86_64 binary runs natively inside the emulator
and the arm64 binary runs under Digitalis via binfmt_misc — same kernel,
libc, compiler and machine, isolating translation as the only variable:

```bash
digitalis/benchmarks/standalone/build.sh
adb push digitalis/out/bench-bin/bench_bcrypt.* /data/local/tmp/
adb shell /data/local/tmp/bench_bcrypt.x86_64   # native baseline
adb shell /data/local/tmp/bench_bcrypt.arm64    # translated (berberis.mode applies)
```

Measured 2026-08-02: two-gear runs bcrypt at 1.53× native x86_64 time (~65%
of native speed), lite at 1.71×; the arm64 binary agrees with the in-app
harness within 4%. Known issue: the standalone binary crashes under
`berberis.mode=interpret-only` (tracked; the JIT tiers and all APK modes are
unaffected).

## What the numbers currently look like

Current results live in [`benchmark-results.md`](benchmark-results.md) — a
generated page, one row per workload with the fastest reliable tier bolded and
noisy cells marked. Refresh it after any sweep:

```bash
digitalis/scripts/run-benchmarks.sh --repeats 2
digitalis/scripts/summarize-benchmarks.py digitalis/out/bench/<stamp>.ndjson \
    --markdown digitalis/docs/benchmark-results.md
```

The page is committed so results travel with the tree and changes show up in
`git diff`; the raw NDJSON stays untracked (it embeds the machine-specific
build fingerprint). The shape to notice across runs so far: translation payoff
tracks workload character — ~9× on entropy-coded compression up to ~43× on
compute-bound crypto — and the second gear's win concentrates where register
and vector pressure is highest (2.3× over lite on saxpy, nil on copy-dominated
codecs).
