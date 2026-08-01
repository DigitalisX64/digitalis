#!/usr/bin/env python3
"""Summarise benchmark records produced by run-benchmarks.sh.

    digitalis/scripts/summarize-benchmarks.py digitalis/out/bench/<stamp>.ndjson
    digitalis/scripts/summarize-benchmarks.py <stamp>.ndjson --markdown docs/benchmark-results.md

With --markdown, also (re)writes the committed results page from this run. The
markdown carries the product name but never the full build fingerprint — the
fingerprint embeds the local build user, and the results page is committed.

Reports, per benchmark case and translation mode, the median with its spread
and the speedup over the interpreter baseline. Spread is reported as the
interquartile range relative to the median: on an emulator this is the number
that says whether a difference is real. A relative IQR above ~10% means the
measurement is too noisy to draw conclusions from, and the run should be
repeated with more iterations or a quieter host.
"""

import json
import statistics
import sys
from collections import defaultdict

BASELINE = "interpret-only"


def load(path):
    records = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    return records


def main(argv):
    args = list(argv[1:])
    md_path = None
    if "--markdown" in args:
        i = args.index("--markdown")
        try:
            md_path = args[i + 1]
        except IndexError:
            sys.exit("--markdown needs a path")
        del args[i:i + 2]
    if len(args) != 1:
        sys.exit(__doc__)

    records = load(args[0])
    if not records:
        sys.exit("no records")

    # (module, case) -> mode -> all per-iteration samples across repeats
    grouped = defaultdict(lambda: defaultdict(list))
    for record in records:
        grouped[(record["module"], record["case"])][record["mode"]].extend(record["ns"])

    modes_seen = sorted({r["mode"] for r in records})
    print(f"{len(records)} record(s), {len(grouped)} case(s), modes: {', '.join(modes_seen)}")
    print(f"device: {records[0].get('device', '?')}\n")

    header = f"{'case':<34}{'mode':<30}{'median':>12}{'rel IQR':>10}{'vs base':>10}"
    print(header)
    print("-" * len(header))

    for (module, case), by_mode in sorted(grouped.items()):
        base = by_mode.get(BASELINE)
        base_median = statistics.median(base) if base else None

        for mode in modes_seen:
            samples = by_mode.get(mode)
            if not samples:
                continue
            median = statistics.median(samples)
            spread = ""
            if len(samples) >= 4:
                quartiles = statistics.quantiles(samples, n=4)
                iqr = quartiles[2] - quartiles[0]
                spread = f"{iqr / median * 100:.1f}%" if median else ""
            speedup = f"{base_median / median:.2f}x" if base_median and median else "—"
            label = f"{module}/{case}"
            print(f"{label:<34}{mode:<30}{fmt(median):>12}{spread:>10}{speedup:>10}")
        print()

    noisy = []
    for (module, case), by_mode in grouped.items():
        for mode, samples in by_mode.items():
            if len(samples) >= 4:
                quartiles = statistics.quantiles(samples, n=4)
                median = statistics.median(samples)
                if median and (quartiles[2] - quartiles[0]) / median > 0.10:
                    noisy.append(f"{module}/{case} [{mode}]")
    if noisy:
        print("Relative IQR above 10% — treat these as unreliable:")
        for item in sorted(noisy):
            print(f"  {item}")
    else:
        print("All cases within a 10% relative IQR.")

    if md_path:
        write_markdown(md_path, args[0], records, grouped, modes_seen)
        print(f"\nwrote {md_path}")
    return 0


BASELINE_LABEL = {"interpret-only": "interpret",
                  "lite-translate-or-interpret": "lite",
                  "two-gear": "two-gear"}


def write_markdown(path, source, records, grouped, modes_seen):
    """One row per workload: median per mode, best tier bolded, and a
    best-vs-interpret column. Noisy cells are marked, never hidden."""
    import os

    stamp = os.path.basename(source).replace(".ndjson", "")
    # Product only: the full fingerprint embeds the local build user.
    fingerprint = records[0].get("device", "")
    product = fingerprint.split("/")[1] if fingerprint.count("/") >= 2 else "unknown"

    jit_modes = [m for m in modes_seen if m != BASELINE]

    def stats_for(samples):
        if not samples:
            return None, False
        median = statistics.median(samples)
        noisy = False
        if len(samples) >= 4 and median:
            quartiles = statistics.quantiles(samples, n=4)
            noisy = (quartiles[2] - quartiles[0]) / median > 0.10
        return median, noisy

    rows = []
    for (module, case), by_mode in grouped.items():
        base_median, base_noisy = stats_for(by_mode.get(BASELINE))
        jit = {m: stats_for(by_mode.get(m)) for m in jit_modes}
        reliable = {m: v for m, (v, noisy) in jit.items() if v and not noisy}
        best_mode = min(reliable, key=reliable.get) if reliable else None

        cells = []
        if base_median:
            cells.append(("⚠ " if base_noisy else "") + fmt(base_median))
        else:
            cells.append("—")
        for mode in jit_modes:
            median, noisy = jit[mode]
            if median is None:
                cells.append("—")
                continue
            text = fmt(median)
            if mode == best_mode:
                text = f"**{text}**"
            if noisy:
                text = "⚠ " + text
            cells.append(text)

        speed = 0.0
        if best_mode and base_median:
            speed = base_median / reliable[best_mode]
            best = f"{speed:.1f}×"
            if base_noisy:
                best = f"~{best} (base noisy)"
            elif len(reliable) < len(jit_modes):
                best += f" ({BASELINE_LABEL.get(best_mode, best_mode)})"
        else:
            best = "—"

        label = f"**{module.removeprefix('hello-')}** {case}"
        rows.append((speed, label, cells, best))

    rows.sort(key=lambda r: (-r[0], r[1]))

    header = ["module / workload"] + [BASELINE_LABEL.get(m, m) for m in modes_seen] + ["best vs interp"]
    lines = [
        "# Benchmark Results",
        "",
        f"Run `{stamp}` on `{product}` — {len(records)} records, "
        f"{len(grouped)} workloads, modes: {', '.join(BASELINE_LABEL.get(m, m) for m in modes_seen)}.",
        "",
        "Generated by `digitalis/scripts/summarize-benchmarks.py --markdown`; do not",
        "edit by hand. Regenerate after a sweep:",
        "",
        "```bash",
        "digitalis/scripts/run-benchmarks.sh --repeats 2",
        "digitalis/scripts/summarize-benchmarks.py digitalis/out/bench/<stamp>.ndjson \\",
        "    --markdown digitalis/docs/benchmark-results.md",
        "```",
        "",
        "The fastest reliable JIT tier per row is **bold**. Cells marked ⚠ exceeded a",
        "10% relative interquartile range and must not be quoted; the best-vs-interp",
        "column uses only reliable cells (falling back to the reliable tier when the",
        "faster one is noisy). See `docs/benchmarking.md` for the methodology.",
        "",
        "| " + " | ".join(header) + " |",
        "|---|" + "---|" * (len(header) - 1),
    ]
    for _, label, cells, best in rows:
        lines.append("| " + " | ".join([label] + cells + [best]) + " |")
    lines.append("")

    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))
    return 0


def fmt(ns):
    if ns >= 1e9:
        return f"{ns / 1e9:.3f}s"
    if ns >= 1e6:
        return f"{ns / 1e6:.2f}ms"
    if ns >= 1e3:
        return f"{ns / 1e3:.1f}us"
    return f"{ns:.0f}ns"


if __name__ == "__main__":
    sys.exit(main(sys.argv))
