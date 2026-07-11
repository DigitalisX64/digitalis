#!/usr/bin/env python3
# Copyright (C) 2026 utzcoz
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Reachability enumerator for proxy DoBadTrampoline symbols — the machine-checkable
core of the Digitalis "no Bad '<sym>' call abort" guarantee.

A proxy library forwards each guest lib*.so symbol to the host. The upstream
generator marks a symbol `DoBadTrampoline` (which aborts when called) if it
could not marshal the signature. This script enumerates every such symbol across
all arm64 proxy tables and classifies each as:

  covered-upstream  handler in the generated table is not DoBadTrampoline
                    (an upstream DoCustomTrampoline_* / GetTrampolineFunc<>).
  covered-digitalis the name is registered by a Digitalis extra trampoline
                    (grepped from android_api/digitalis_extra_proxy/*.cc).
  mangled-net       still DoBadTrampoline, C++-mangled (_Z...) internal symbol
                    an app never resolves by name -> the arm64
                    DoGracefulBadTrampoline net handles it if ever reached.
  allowlisted-net   still DoBadTrampoline, unmangled but verified non-NDK-stable
                    and listed (with a reason) in the allowlist -> net handles it.
  UNCOVERED         still DoBadTrampoline, unmangled-C, not covered, not
                    allowlisted. This is the tripwire: a future AOSP uprev that
                    adds a new NDK-stable bad symbol lands here. Exit code 1.

The guarantee: after coverage, the UNCOVERED set is empty, so no NDK-stable
symbol can hit the fatal DoBadTrampoline; anything that ever does hit the
arm64 net degrades to a loud trace + zeroed x0 instead of a SIGABRT.
"""

import pathlib
import re
import sys

# {"NAME", HANDLER, ...}  — capture the quoted name and the following handler token.
_ENTRY_RE = re.compile(r'\{\s*"([^"]+)"\s*,\s*([A-Za-z_][A-Za-z0-9_]*)')
# Any quoted "symbol" appearing in a digitalis_extra trampoline .cc counts as
# Digitalis-covered (those files list only covered/contract-stubbed symbols).
_QUOTED_RE = re.compile(r'"([^"]+)"')


def repo_root():
    # digitalis/scripts/enumerate-proxy-bad-symbols.py -> repo root is two up.
    return pathlib.Path(__file__).resolve().parents[2]


def load_allowlist(path):
    """Return (exact:set, prefixes:list). Lines ending in '_' are prefixes.
    '#' comments and blank lines ignored."""
    exact, prefixes = set(), []
    if not path.exists():
        return exact, prefixes
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.endswith("_"):
            prefixes.append(line)
        else:
            exact.add(line)
    return exact, prefixes


def digitalis_covered(extra_dir):
    """Every quoted symbol registered by a Digitalis extra trampoline .cc."""
    names = set()
    for cc in sorted(extra_dir.glob("digitalis_extra_*_trampolines.cc")):
        for m in _QUOTED_RE.finditer(cc.read_text()):
            names.add(m.group(1))
    return names


def main():
    root = repo_root()
    nbs = root / "frameworks/libs/native_bridge_support"
    extra_dir = root / "frameworks/libs/binary_translation/android_api/digitalis_extra_proxy"
    allowlist_path = root / "digitalis/docs/proxy-bad-symbol-allowlist.txt"
    report_path = root / "digitalis/docs/proxy-bad-symbol-audit.md"

    allow_exact, allow_prefixes = load_allowlist(allowlist_path)
    covered_dig = digitalis_covered(extra_dir)

    headers = sorted(nbs.glob("**/proxy/trampolines_arm64_to_x86_64-inl.h"))
    if not headers:
        print(f"error: no trampoline headers under {nbs}", file=sys.stderr)
        return 2

    per_lib = {}       # lib -> counts dict
    uncovered = []     # (lib, name)
    for hdr in headers:
        lib = re.sub(r".*/android_api/([^/]+)/proxy/.*", r"\1", str(hdr))
        counts = per_lib.setdefault(
            lib, dict(total=0, cov_up=0, cov_dig=0, mangled=0, allow=0, uncovered=0))
        for m in _ENTRY_RE.finditer(hdr.read_text()):
            name, handler = m.group(1), m.group(2)
            counts["total"] += 1
            if handler != "DoBadTrampoline":
                counts["cov_up"] += 1
            elif name in covered_dig:
                counts["cov_dig"] += 1
            elif name.startswith("_Z"):
                counts["mangled"] += 1
            elif name in allow_exact or any(name.startswith(p) for p in allow_prefixes):
                counts["allow"] += 1
            else:
                counts["uncovered"] += 1
                uncovered.append((lib, name))

    # ---- report ----
    lines = []
    lines.append("# Proxy DoBadTrampoline reachability audit\n")
    lines.append("> Generated by `digitalis/scripts/enumerate-proxy-bad-symbols.py`. "
                 "Do not edit by hand.\n")
    lines.append("Every proxy symbol the upstream generator marked `DoBadTrampoline` "
                 "(aborts when called), classified by how the Digitalis "
                 "no-crash guarantee covers it. `UNCOVERED` must be 0 — a nonzero "
                 "value means a new NDK-stable bad symbol needs a contract stub "
                 "(or, if verified non-NDK, an allowlist entry with a reason).\n")
    lines.append("| Library | total entries | covered-upstream | covered-digitalis "
                 "| mangled-net | allowlisted-net | UNCOVERED |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|")
    agg = dict(total=0, cov_up=0, cov_dig=0, mangled=0, allow=0, uncovered=0)
    for lib in sorted(per_lib):
        c = per_lib[lib]
        for k in agg:
            agg[k] += c[k]
        # Only list libraries that carry at least one bad entry.
        if c["cov_dig"] + c["mangled"] + c["allow"] + c["uncovered"] == 0:
            continue
        lines.append(f"| {lib} | {c['total']} | {c['cov_up']} | {c['cov_dig']} "
                     f"| {c['mangled']} | {c['allow']} | {c['uncovered']} |")
    lines.append(f"| **all** | {agg['total']} | {agg['cov_up']} | {agg['cov_dig']} "
                 f"| {agg['mangled']} | {agg['allow']} | **{agg['uncovered']}** |")
    lines.append("")
    total_bad = agg["cov_dig"] + agg["mangled"] + agg["allow"] + agg["uncovered"]
    lines.append(f"Total `DoBadTrampoline` entries: **{total_bad}** — "
                 f"{agg['cov_dig']} contract-stubbed by Digitalis, "
                 f"{agg['mangled']} mangled-internal (net), "
                 f"{agg['allow']} allowlisted non-NDK (net), "
                 f"**{agg['uncovered']} uncovered**.\n")
    if uncovered:
        lines.append("## UNCOVERED (must be empty)\n")
        for lib, name in sorted(uncovered):
            lines.append(f"- `{lib}` :: `{name}`")
        lines.append("")

    report_path.write_text("\n".join(lines) + "\n")

    # ---- console summary ----
    print(f"trampoline headers scanned: {len(headers)}")
    print(f"DoBadTrampoline entries: {total_bad} "
          f"(digitalis={agg['cov_dig']} mangled-net={agg['mangled']} "
          f"allow-net={agg['allow']} UNCOVERED={agg['uncovered']})")
    print(f"report written: {report_path.relative_to(root)}")
    if uncovered:
        print("\nUNCOVERED unmangled-C bad symbols (cover or allowlist each):",
              file=sys.stderr)
        for lib, name in sorted(uncovered):
            print(f"  {lib}: {name}", file=sys.stderr)
        return 1
    print("OK: no uncovered NDK-stable bad symbols.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
