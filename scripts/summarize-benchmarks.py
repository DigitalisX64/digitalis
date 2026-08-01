#!/usr/bin/env python3
"""Summarise benchmark records produced by run-benchmarks.sh.

    digitalis/scripts/summarize-benchmarks.py digitalis/out/bench/<stamp>.ndjson

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
    if len(argv) != 2:
        sys.exit(__doc__)

    records = load(argv[1])
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
