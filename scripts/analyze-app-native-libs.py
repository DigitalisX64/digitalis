#!/usr/bin/env python3
# Copyright (C) 2026 utzcoz
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
"""Inventory the native (.so) libraries each verified app/game bundles, and
aggregate them by how many distinct apps use each. Maps every verified package
to its local prebuilt APK(s) and lists lib/arm64-v8a/*.so from the APK that
carries native code (base or the arm64 config split)."""
import glob, os, re, subprocess, zipfile, json, collections
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AAPT = REPO + "/out/host/linux-x86/bin/aapt2"
PREB = REPO + "/sample/prebuilts"

def pkg_of(apk):
    try:
        return subprocess.run([AAPT,"dump","packagename",apk],capture_output=True,text=True,timeout=60).stdout.strip()
    except Exception:
        return ""

def build_map():
    """package -> list of APK paths (base + arm64 split for bundles)."""
    m = {}
    for base in glob.glob(PREB+"/*/base.apk")+glob.glob(PREB+"/*/*/base.apk"):
        p = pkg_of(base)
        if not p or p in m: continue
        d = os.path.dirname(base)
        m[p] = [x for x in glob.glob(d+"/*.apk")
                if not re.search(r"config\.(armeabi|x86|mips|[a-z]{2})\.apk$",os.path.basename(x))
                or "arm64" in os.path.basename(x) or os.path.basename(x)=="base.apk"]
    for apk in (glob.glob(PREB+"/*.apk")+glob.glob(PREB+"/benchmark-apps/*arm64*.apk")
                +glob.glob(PREB+"/top-games/*.apk")+glob.glob(PREB+"/top-apps/*.apk")):
        p = pkg_of(apk)
        if p and p not in m: m[p] = [apk]
    return m

def libs_of(apks):
    s = set()
    for apk in apks:
        try:
            with zipfile.ZipFile(apk) as z:
                for n in z.namelist():
                    mm = re.match(r"lib/arm64-v8a/(lib.+\.so)$", n)
                    if mm: s.add(mm.group(1))
        except Exception:
            pass
    return s

def main():
    import yaml
    d = yaml.safe_load(open(REPO+"/digitalisx64.github.io/_data/apps.yml"))
    pmap = build_map()
    lib_apps = collections.defaultdict(set)   # lib -> set(package)
    app_libs = {}                              # package -> sorted libs
    missing = []
    for a in d["verified"]:
        pkg = a["package"]; apks = pmap.get(pkg)
        if not apks:
            missing.append(pkg); continue
        libs = libs_of(apks)
        app_libs[pkg] = sorted(libs)
        for l in libs:
            lib_apps[l].add(pkg)
    out = {
        "n_apps": len(app_libs),
        "no_apk": missing,
        "lib_freq": sorted(([l, len(pk), sorted(pk)] for l,pk in lib_apps.items()),
                           key=lambda x:-x[1]),
        "app_libs": app_libs,
    }
    open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "out", "lib_analysis.json"), "w").write(json.dumps(out,indent=1))
    print("apps analyzed:", len(app_libs), "| no-apk:", len(missing))
    print("distinct native libs:", len(lib_apps))
    print("\n=== TOP native libs by #apps using them ===")
    for l,n,pk in out["lib_freq"][:60]:
        print("%3d  %s" % (n, l))

if __name__ == "__main__":
    main()
