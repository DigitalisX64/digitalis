#!/usr/bin/env python3
# Copyright (C) 2026 utzcoz
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
"""Render TRUE launcher icons for the given packages by asking the running
emulator to composite them — the only faithful source for vector / obfuscated
adaptive icons (browsers, WhatsApp, VLC, …) that carry no raster in the APK and
that render-*offline* only as a monogram.

It builds Resources straight from the app's APK splits inside an app_process
run of the tiny IconDump helper (icon-render/src/com/digitalis/IconDump.java),
draws the launcher Drawable to a Bitmap, and writes a 96px PNG into the site's
assets/icons/<package>.png, overwriting the monogram placeholder.

Requires: a booted emulator with the app's APK available under sample/prebuilts,
`adb root`, aapt2 + jdk + d8 from the build tree (auto-compiles the helper dex on
first run). Companion to extract-app-icons.py, which handles raster/adaptive-raster
icons offline; run this afterwards for whatever still fell back to a monogram.

Usage: render-app-icons.py <package> [<package> ...]
"""
import glob, os, re, subprocess, sys
from PIL import Image

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AAPT = REPO + "/out/host/linux-x86/bin/aapt2"
JAVAC = REPO + "/prebuilts/jdk/jdk21/linux-x86/bin/javac"
D8 = REPO + "/out/host/linux-x86/bin/d8"
ANDROID_JAR = REPO + "/prebuilts/sdk/current/public/android.jar"
HELPER_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "icon-render/src/com/digitalis/IconDump.java")
PREBUILTS = REPO + "/sample/prebuilts"
ICONS = REPO + "/digitalisx64.github.io/assets/icons"
SIZE = 96
DEXREMOTE = "/data/local/tmp/icondump.dex"

def sh(*a, timeout=120):
    return subprocess.run(a, capture_output=True, text=True, timeout=timeout).stdout

def build_and_push_dex():
    """Compile IconDump.java -> dex and push it to the device."""
    work = "/tmp/icondump_build"
    os.makedirs(work + "/classes", exist_ok=True)
    sh(JAVAC, "-cp", ANDROID_JAR, "-d", work + "/classes", HELPER_SRC, timeout=120)
    cls = work + "/classes/com/digitalis/IconDump.class"
    sh(D8, "--min-api", "26", "--output", work, cls, timeout=120)
    sh("adb", "push", work + "/classes.dex", DEXREMOTE, timeout=60)

def adb(*a, timeout=120):
    return sh("adb", *a, timeout=timeout)

def pkg_of(apk):
    return sh(AAPT, "dump", "packagename", apk, timeout=60).strip()

def build_map():
    """package -> list of split APKs (base + config splits), or a single APK."""
    m = {}
    # bundle dirs anywhere (root, top-apps, top-games)
    for base in (glob.glob(PREBUILTS + "/*/base.apk")
                 + glob.glob(PREBUILTS + "/*/*/base.apk")):
        p = pkg_of(base)
        if not p or p in m:
            continue
        d = os.path.dirname(base)
        splits = [x for x in glob.glob(d + "/*.apk")
                  if not re.search(r"config\.(armeabi|x86|mips)", os.path.basename(x))]
        m[p] = splits
    # single APKs
    for apk in (glob.glob(PREBUILTS + "/*.apk")
                + glob.glob(PREBUILTS + "/benchmark-apps/*arm64*.apk")
                + glob.glob(PREBUILTS + "/top-games/*.apk")
                + glob.glob(PREBUILTS + "/top-apps/*.apk")):
        p = pkg_of(apk)
        if p and p not in m:
            m[p] = [apk]
    return m

def icon_resid(apk):
    tree = sh(AAPT, "dump", "xmltree", "--file", "AndroidManifest.xml", apk, timeout=90)
    # find the <application> android:icon reference
    in_app = False
    for line in tree.splitlines():
        s = line.strip()
        if s.startswith("E: application"):
            in_app = True
        if in_app and "android:icon(" in s:
            m = re.search(r"=@?(0x[0-9a-fA-F]+)", s)
            if m:
                return m.group(1)
    return None

def render(pkg, apks):
    base = next((a for a in apks if os.path.basename(a) == "base.apk"), apks[0])
    resid = icon_resid(base)
    if not resid:
        return None, "no-icon-resid"
    remote_paths = []
    adb("shell", "rm", "-f", "/data/local/tmp/split*.apk")
    for i, a in enumerate(apks):
        rp = "/data/local/tmp/split%d.apk" % i
        adb("push", a, rp, timeout=180)
        remote_paths.append(rp)
    out_remote = "/data/local/tmp/icon.png"
    adb("shell", "rm", "-f", out_remote)
    r = adb("shell",
            "CLASSPATH=%s app_process /data/local/tmp com.digitalis.IconDump "
            "%s %s 192 %s" % (DEXREMOTE, resid, out_remote, " ".join(remote_paths)),
            timeout=120)
    local = "/tmp/dev_icon.png"
    if os.path.exists(local):
        os.remove(local)
    adb("pull", out_remote, local, timeout=60)
    if not os.path.exists(local):
        return None, "no-output(%s)" % r.strip()[:40]
    try:
        img = Image.open(local).convert("RGBA")
    except Exception as e:
        return None, "bad-png:%s" % e
    # reject fully transparent / empty renders
    bbox = img.getbbox()
    if bbox is None:
        return None, "empty"
    return img, "ok"

def main():
    build_and_push_dex()
    pmap = build_map()
    pkgs = sys.argv[1:]
    ok, fail = [], []
    for pkg in pkgs:
        apk = pmap.get(pkg)
        if not apk:
            fail.append((pkg, "no-apk")); continue
        img, why = render(pkg, apk)
        if img is None:
            fail.append((pkg, why)); continue
        img.resize((SIZE, SIZE), Image.LANCZOS).save(os.path.join(ICONS, pkg + ".png"),
                                                      "PNG", optimize=True)
        ok.append(pkg)
    print("RENDERED %d, FAILED %d" % (len(ok), len(fail)))
    for p in ok: print("  ok", p)
    for p, w in fail: print("  FAIL", p, w)

if __name__ == "__main__":
    main()
