#!/usr/bin/env python3
# Copyright (C) 2026 utzcoz
# SPDX-License-Identifier: Apache-2.0
#
# Reports the freshness of every prebuilt regression APK under sample/prebuilts/
# (single .apk files in the root AND split-app subdirectories), so stale builds
# can be prioritized for a refresh via fetch-prebuilt-apks.py.
#
# For each app it prints the package, versionName/versionCode, targetSdkVersion,
# and a STALE flag when targetSdk is below --min-target (default 29 ~ Android 10).
# A low targetSdk is the tell of an old build: e.g. an X (Twitter) 2018 alpha
# shipped targetSdk 27 and tripped Android's "built for an older version"
# warning, and predated the app's current native libraries.
#
# For apps also pinned in digitalis/apkmirror-apps.json it notes whether the
# local version matches the pin (fetch-prebuilt-apks.py --list already covers
# those; this tool additionally covers the many manually-dropped APKs that are
# NOT in the config). Nothing here is app-specific: it reads each APK's manifest.
import argparse
import glob
import json
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PREBUILTS = os.path.join(ROOT, "sample", "prebuilts")
CONFIG = os.path.join(ROOT, "digitalis", "apkmirror-apps.json")


def find_aapt2():
    for env in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        base = os.environ.get(env)
        if base:
            cands = sorted(glob.glob(os.path.join(base, "build-tools", "*", "aapt2")))
            if cands:
                return cands[-1]
    cands = sorted(glob.glob(os.path.expanduser("~/Android/Sdk/build-tools/*/aapt2")))
    return cands[-1] if cands else None


def badging(aapt2, apk):
    try:
        out = subprocess.run([aapt2, "dump", "badging", apk],
                             capture_output=True, text=True, timeout=60).stdout
    except Exception:
        return {}
    info = {}
    for line in out.splitlines():
        if line.startswith("package:"):
            for key in ("name", "versionCode", "versionName"):
                marker = "%s='" % key
                if marker in line:
                    info[key] = line.split(marker, 1)[1].split("'", 1)[0]
        elif line.startswith("targetSdkVersion:"):
            info["targetSdk"] = line.split("'")[1] if "'" in line else ""
    return info


def config_pins():
    try:
        with open(CONFIG, encoding="utf-8") as f:
            return {e["package"]: e.get("version") for e in json.load(f)}
    except Exception:
        return {}


def targets():
    """Every regression target: root *.apk files + split-app subdirectories."""
    out = []
    for apk in sorted(glob.glob(os.path.join(PREBUILTS, "*.apk"))):
        out.append(("apk", apk))
    for d in sorted(glob.glob(os.path.join(PREBUILTS, "*", ""))):
        base = os.path.basename(d.rstrip("/"))
        # Skip the fetch-tool staging dirs, mirroring test-prebuilts.sh's
        # top-level-only discovery.
        if base in ("top-apps", "top-games"):
            continue
        splits = glob.glob(os.path.join(d, "*.apk"))
        base_apk = next((s for s in splits if s.endswith("base.apk")), None) or (splits[0] if splits else None)
        if base_apk:
            out.append(("split", base_apk))
    return out


def main(argv):
    ap = argparse.ArgumentParser(description="Report prebuilt-APK freshness.")
    ap.add_argument("--min-target", type=int, default=29,
                    help="flag STALE when targetSdk < this (default 29)")
    ap.add_argument("--stale-only", action="store_true", help="only print STALE rows")
    args = ap.parse_args(argv[1:])

    aapt2 = find_aapt2()
    if not aapt2:
        print("aapt2 not found (set ANDROID_HOME).", file=sys.stderr)
        return 2

    pins = config_pins()
    rows, stale = [], 0
    for kind, apk in targets():
        info = badging(aapt2, apk)
        pkg = info.get("name", "?")
        tsdk = info.get("targetSdk", "")
        vn = info.get("versionName", "?")
        is_stale = tsdk.isdigit() and int(tsdk) < args.min_target
        stale += 1 if is_stale else 0
        note = ""
        if pkg in pins:
            note = "pinned=%s" % pins[pkg]
        rows.append((is_stale, tsdk or "?", pkg, vn, kind, os.path.basename(apk), note))

    rows.sort(key=lambda r: (not r[0], r[1]))
    hdr = "%-6s %-7s %-52s %-22s %-6s %s"
    print(hdr % ("STATUS", "tgtSDK", "package", "version", "kind", "file/note"))
    for is_stale, tsdk, pkg, vn, kind, fn, note in rows:
        if args.stale_only and not is_stale:
            continue
        status = "STALE" if is_stale else "ok"
        print(hdr % (status, tsdk, pkg[:52], vn[:22], kind, (fn + ("  " + note if note else ""))))
    total = len(rows)
    print("\n%d apps, %d stale (targetSdk < %d)." % (total, stale, args.min_target))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
