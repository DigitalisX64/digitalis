#!/usr/bin/env python3
# Copyright (C) 2026 utzcoz
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
"""
Decide whether a captured screenshot shows meaningful application content
(a real UI) or is stuck on a splash / blank screen.

Heuristic: divide the screenshot into a coarse grid and count cells whose
pixel-color variance exceeds a threshold. A blank or near-blank screen has
~1-2 dominant colors per cell (variance near zero). A stuck-on-splash screen
has a small number of "interesting" cells (where the logo sits) and many
uniform background cells. A real loaded UI has interesting content spread
across most of the grid (text, buttons, separators, icons, list rows).

A 30% threshold cleanly separates "stuck/blank" from "real UI" across all
three. Threshold can be tuned via --threshold for stricter / looser checks.

Usage:
    screenshot_content_check.py /path/to/shot.png
    screenshot_content_check.py --threshold 25 /path/to/shot.png

Exit code 0 if the screenshot passes the content check, 1 if it doesn't,
2 on argument/IO errors. The single-line summary on stdout has the form:
    content_cells=N/M (P%) PASS|FAIL  <path>
"""

import argparse
import statistics
import sys

try:
    from PIL import Image
except ImportError:
    print("error: PIL/Pillow not installed (pip install Pillow)", file=sys.stderr)
    sys.exit(2)


def content_cells(img_path, grid_cols=6, grid_rows=10, cell_variance_thresh=200.0):
    """Returns (interesting_cell_count, total_cell_count) for the image."""
    img = Image.open(img_path).convert("RGB")
    w, h = img.size
    cw = w // grid_cols
    ch = h // grid_rows
    interesting = 0
    total = grid_cols * grid_rows
    for r in range(grid_rows):
        for c in range(grid_cols):
            cell = img.crop((c * cw, r * ch, (c + 1) * cw, (r + 1) * ch))
            pixels = list(cell.getdata())
            rs = [p[0] for p in pixels]
            gs = [p[1] for p in pixels]
            bs = [p[2] for p in pixels]
            var = statistics.pvariance(rs) + statistics.pvariance(gs) + statistics.pvariance(bs)
            if var > cell_variance_thresh:
                interesting += 1
    return interesting, total


def main():
    ap = argparse.ArgumentParser(description="Detect meaningful content in a screenshot.")
    ap.add_argument("path", help="path to PNG screenshot")
    ap.add_argument("--threshold", type=int, default=30,
                    help="minimum content-cell percentage to PASS (default: 30)")
    ap.add_argument("--cols", type=int, default=6, help="grid columns (default: 6)")
    ap.add_argument("--rows", type=int, default=10, help="grid rows (default: 10)")
    ap.add_argument("--cell-variance", type=float, default=200.0,
                    help="per-cell variance threshold (default: 200.0)")
    args = ap.parse_args()

    try:
        ic, tc = content_cells(args.path,
                               grid_cols=args.cols,
                               grid_rows=args.rows,
                               cell_variance_thresh=args.cell_variance)
    except Exception as e:
        print(f"error: {e} {args.path}", file=sys.stderr)
        sys.exit(2)

    pct = (ic * 100 // tc) if tc else 0
    verdict = "PASS" if pct >= args.threshold else "FAIL"
    print(f"content_cells={ic}/{tc} ({pct}%) {verdict}  {args.path}")
    sys.exit(0 if verdict == "PASS" else 1)


if __name__ == "__main__":
    main()
