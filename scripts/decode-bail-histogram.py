#!/usr/bin/env python3
#
# decode-bail-histogram.py — decode a heavy-tier gear-up bail word list into a
# mnemonic-frequency histogram (companion to heavybail-sweep.sh).
#
# Input: a file (or stdin) of ARM64 instruction words, one per line, as produced
# by heavybail-sweep.sh — each line is a `0x........` 32-bit encoding of the
# instruction the heavy frontend bailed on (duplicates preserved so counts are
# real frequencies).
#
# It disassembles every UNIQUE word once (batched, little-endian raw binary)
# with `aarch64-linux-gnu-objdump -b binary -m aarch64 -D` — the prebuilt
# llvm-objdump rejects `-b binary`, so the GNU objdump is required — then
# aggregates by mnemonic and by raw encoding, printing two ranked tables:
#   1. by mnemonic (the Tier 2 prioritization axis)
#   2. the top raw encodings (to spot a single hot instruction inside a mnemonic)
#
# Usage:
#   decode-bail-histogram.py [WORDS_FILE]      # default: stdin
#   OBJDUMP=/path/to/aarch64-linux-gnu-objdump decode-bail-histogram.py words.txt
#
# Copyright (C) 2026 utzcoz
# SPDX-License-Identifier: Apache-2.0

import collections
import os
import re
import struct
import subprocess
import sys
import tempfile

OBJDUMP = os.environ.get("OBJDUMP", "aarch64-linux-gnu-objdump")


def read_words(src):
    """Yield 32-bit ints from a stream of 0x........ / bare-hex lines."""
    for line in src:
        line = line.strip()
        if not line:
            continue
        m = re.search(r"(?:0x)?([0-9a-fA-F]{8})\b", line)
        if not m:
            continue
        yield int(m.group(1), 16)


def disassemble(words):
    """Return {word: (mnemonic, full_text)} for each unique word via objdump."""
    uniq = sorted(set(words))
    if not uniq:
        return {}
    # Write all unique words as little-endian raw bytes, disassemble in one shot.
    blob = b"".join(struct.pack("<I", w) for w in uniq)
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
        f.write(blob)
        binpath = f.name
    try:
        out = subprocess.check_output(
            [OBJDUMP, "-b", "binary", "-m", "aarch64", "-D", binpath],
            stderr=subprocess.STDOUT,
        ).decode("utf-8", "replace")
    except FileNotFoundError:
        sys.stderr.write(
            "ERROR: %s not found. Install binutils-aarch64-linux-gnu or set OBJDUMP.\n"
            % OBJDUMP
        )
        sys.exit(2)
    finally:
        os.unlink(binpath)

    # objdump lines look like:
    #    4:   91000421        add     x1, x1, #0x1
    # The address (hex, no 0x) is the byte offset; index = offset/4 into uniq.
    result = {}
    line_re = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(.*)$")
    for line in out.splitlines():
        m = line_re.match(line)
        if not m:
            continue
        off = int(m.group(1), 16)
        idx = off // 4
        if idx >= len(uniq):
            continue
        word = uniq[idx]
        text = m.group(3).strip()
        # Mnemonic is the first token; ".word"/".inst" mark undecodable.
        mnem = text.split()[0] if text else "(none)"
        result[word] = (mnem, text)
    return result


def main():
    src = open(sys.argv[1]) if len(sys.argv) > 1 else sys.stdin
    words = list(read_words(src))
    if len(sys.argv) > 1:
        src.close()
    total = len(words)
    if total == 0:
        print("no bail words on input")
        return

    decoded = disassemble(words)
    by_mnem = collections.Counter()
    by_word = collections.Counter(words)
    undecoded = 0
    for w in words:
        info = decoded.get(w)
        if info is None:
            undecoded += 1
            by_mnem["(undecoded)"] += 1
        else:
            by_mnem[info[0]] += 1

    print("=== heavy-tier gear-up bail histogram ===")
    print("total bail events: %d   unique encodings: %d   undecoded: %d\n"
          % (total, len(by_word), undecoded))

    print("--- by mnemonic (Tier 2 prioritization axis) ---")
    print("%8s  %6s  %s" % ("count", "pct", "mnemonic"))
    for mnem, cnt in by_mnem.most_common():
        print("%8d  %5.1f%%  %s" % (cnt, 100.0 * cnt / total, mnem))

    print("\n--- top 25 raw encodings ---")
    print("%8s  %-10s  %s" % ("count", "encoding", "disassembly"))
    for word, cnt in by_word.most_common(25):
        info = decoded.get(word)
        text = info[1] if info else "(undecoded)"
        print("%8d  0x%08x  %s" % (cnt, word, text))


if __name__ == "__main__":
    main()
