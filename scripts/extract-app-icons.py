#!/usr/bin/env python3
# Copyright (C) 2026 utzcoz
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
"""Extract launcher icons for the verified-apps list into the website assets.

For every package listed in the digitalisx64.github.io ``_data/apps.yml`` this
walks the local ``sample/prebuilts`` APKs, resolves each app's authoritative
launcher icon, and writes a 96x96 PNG to ``assets/icons/<package>.png``.

Icon resolution (authoritative only — never guesses a random asset):
  1. ``aapt2 dump badging`` gives the declared launcher-icon resource path.
  2. If it is a raster (png/webp) it is used directly.
  3. If it is an adaptive-icon XML, ``aapt2 dump xmltree`` yields the
     background/foreground drawable resource IDs, which ``aapt2 dump
     resources`` maps to their raster files; the layers are composited.
  4. If a layer is a vector drawable (no raster — e.g. Firefox, WhatsApp), or
     no APK is available, a deterministic monogram avatar (rounded colored
     tile with the app's initials) is generated instead, so every row still
     has an icon.

Usage:
    extract-app-icons.py [--aapt2 PATH] [--repo PATH] [--force]

Defaults assume the standard tree layout: repo root two levels up from this
script, aapt2 at out/host/linux-x86/bin/aapt2. ``--force`` re-extracts icons
that already exist (otherwise existing files are left untouched).
"""
import argparse
import glob
import hashlib
import io
import os
import re
import subprocess
import zipfile

from PIL import Image, ImageDraw, ImageFont

SIZE = 96
_PALETTE = [(0x4f, 0x46, 0xe5), (0x0e, 0x7a, 0x5f), (0xb4, 0x53, 0x09),
            (0x9d, 0x17, 0x4d), (0x1d, 0x4e, 0xd8), (0x7c, 0x3a, 0xed),
            (0xb9, 0x1c, 0x1c), (0x0f, 0x76, 0x6e), (0x92, 0x40, 0x0e),
            (0x3f, 0x62, 0x12)]
_FONTS = ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
          "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf")


def sh(args, timeout=120):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout


class Aapt:
    def __init__(self, path):
        self.path = path

    def packagename(self, apk):
        try:
            return sh([self.path, "dump", "packagename", apk], 60).strip()
        except Exception:
            return ""

    def badging(self, apk):
        return sh([self.path, "dump", "badging", apk], 120)

    def xmltree(self, apk, res):
        return sh([self.path, "dump", "xmltree", "--file", res, apk], 60)

    def resources(self, apk):
        return sh([self.path, "dump", "resources", apk], 180)


def declared_icon(aapt, apk):
    out = aapt.badging(apk)
    best = None
    for m in re.finditer(r"application-icon-(\d+):'([^']+)'", out):
        d = int(m.group(1))
        if d >= 65534:
            continue
        if best is None or d > best[0]:
            best = (d, m.group(2))
    if best:
        return best[1]
    m2 = re.search(r"application:.*icon='([^']+)'", out)
    return m2.group(1) if m2 else None


def _resid_block(res_dump, resid):
    """Yield the lines belonging to one resource id's entry."""
    key = "resource %s " % resid
    block, capturing = [], False
    for line in res_dump.splitlines():
        if line.lstrip().startswith("resource 0x"):
            if capturing:
                break
            capturing = line.lstrip().startswith(key.strip())
            if capturing:
                block.append(line)
            continue
        if capturing:
            block.append(line)
    return block


def resid_to_paths(res_dump, resid):
    """Map a resource id (e.g. 0x7f0b0003) to its res/* file paths."""
    paths = []
    for line in _resid_block(res_dump, resid):
        m = re.search(r"(res/[^\s]+\.(?:png|webp|xml))", line)
        if m:
            paths.append(m.group(1))
    return paths


def _hex_to_rgba(h):
    v = int(h, 16)  # AARRGGBB
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255, (v >> 24) & 255)


def _named_color_block(res_dump, name):
    """Lines of the `color/<name>` resource entry, if present."""
    block, capturing = [], False
    for line in res_dump.splitlines():
        if line.lstrip().startswith("resource 0x"):
            capturing = bool(re.search(r"resource 0x[0-9a-fA-F]+\s+color/%s\b" % re.escape(name),
                                       line.lstrip()))
            if capturing:
                block.append(line)
            continue
        if capturing:
            block.append(line)
    return block


def resolve_bg_color(aapt, apk, res_dump, resid, depth=0):
    """Resolve an adaptive-icon background resource id to a solid (r,g,b,a).

    Follows color-resource indirections (@color/foo, @0xID) and inspects a
    background XML drawable for its first solid #AARRGGBB. Returns None if the
    background is not reducible to a solid color (e.g. a gradient/vector).
    """
    if depth > 4:
        return None
    for line in _resid_block(res_dump, resid):
        m = re.search(r"#([0-9a-fA-F]{8})\b", line)
        if m:
            return _hex_to_rgba(m.group(1))
        mn = re.search(r"@color/(\w+)", line)
        if mn:
            for l2 in _named_color_block(res_dump, mn.group(1)):
                m2 = re.search(r"#([0-9a-fA-F]{8})\b", l2)
                if m2:
                    return _hex_to_rgba(m2.group(1))
        mi = re.search(r"@(0x[0-9a-fA-F]+)", line)
        if mi and mi.group(1).lower() != resid.lower():
            c = resolve_bg_color(aapt, apk, res_dump, mi.group(1), depth + 1)
            if c:
                return c
        mf = re.search(r"(res/\S+\.xml)", line)
        if mf:
            tree = aapt.xmltree(apk, mf.group(1))
            mc = re.search(r"#([0-9a-fA-F]{8})\b", tree)
            if mc:
                return _hex_to_rgba(mc.group(1))
    return None


def adaptive_layers(aapt, apk, xml_res):
    tree = aapt.xmltree(apk, xml_res)
    bg = fg = None
    cur = None
    for line in tree.splitlines():
        s = line.strip()
        em = re.match(r"E:\s*(\w+)", s)
        if em:
            cur = em.group(1)
        am = re.search(r":drawable\([^)]*\)=@(0x[0-9a-fA-F]+)", s)
        if am:
            if cur == "background":
                bg = am.group(1)
            elif cur == "foreground":
                fg = am.group(1)
    return bg, fg


def load_raster(z, name):
    try:
        return Image.open(io.BytesIO(z.read(name))).convert("RGBA")
    except Exception:
        return None


def best_raster(z, paths):
    best, bestpx = None, 0
    names = set(z.namelist())
    for p in paths:
        if p not in names or not p.lower().endswith((".png", ".webp")):
            continue
        img = load_raster(z, p)
        if img and img.size[0] * img.size[1] > bestpx:
            best, bestpx = img, img.size[0] * img.size[1]
    return best


def icon_from_apk(aapt, apk):
    """Return an authoritative launcher-icon image, or None if only vector."""
    icon = declared_icon(aapt, apk)
    if not icon:
        return None
    with zipfile.ZipFile(apk) as z:
        names = set(z.namelist())
        if icon.lower().endswith((".png", ".webp")) and icon in names:
            return load_raster(z, icon)
        if icon.lower().endswith(".xml"):
            bg_id, fg_id = adaptive_layers(aapt, apk, icon)
            if not fg_id:
                return None
            res_dump = aapt.resources(apk)
            fg = best_raster(z, resid_to_paths(res_dump, fg_id))
            if fg is None:
                # Vector foreground. Only render it when EVERY layer is a solid
                # fill we can reproduce exactly; brand icons whose art uses
                # gradients/state-list colors (Firefox, VLC, Outlook, …) are left
                # to a monogram rather than risk a wrong-colored render.
                return None  # vector/obfuscated adaptive foreground -> monogram
            if fg is None:
                return None  # unsupported vector -> monogram
            base = None
            if bg_id:
                base = best_raster(z, resid_to_paths(res_dump, bg_id))
                if base is None:
                    color = resolve_bg_color(aapt, apk, res_dump, bg_id)
                    if color:
                        base = Image.new("RGBA", fg.size, color)
            if base is None:
                base = Image.new("RGBA", fg.size, (255, 255, 255, 0))
            if base.size != fg.size:
                base = base.resize(fg.size)
            return Image.alpha_composite(base, fg)
    return None


def monogram(name, dest):
    h = int(hashlib.md5(name.encode()).hexdigest(), 16)
    bg = _PALETTE[h % len(_PALETTE)]
    words = re.sub(r"[^A-Za-z0-9 ]", "", name).split()
    initials = ((words[0][0] + (words[1][0] if len(words) > 1 else "")).upper()
                if words else "?")
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    dr = ImageDraw.Draw(img)
    dr.rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=int(SIZE * 0.22),
                         fill=bg + (255,))
    fs = int(SIZE * (0.42 if len(initials) > 1 else 0.5))
    font = next((ImageFont.truetype(p, fs) for p in _FONTS if os.path.exists(p)),
                ImageFont.load_default())
    bb = dr.textbbox((0, 0), initials, font=font)
    dr.text(((SIZE - (bb[2] - bb[0])) / 2 - bb[0],
             (SIZE - (bb[3] - bb[1])) / 2 - bb[1]),
            initials, font=font, fill=(255, 255, 255, 255))
    img.save(dest, "PNG", optimize=True)


def build_pkg_map(aapt, prebuilts):
    """package -> local APK path (base.apk for split bundles)."""
    m = {}
    sources = (glob.glob(prebuilts + "/*.apk")
               + glob.glob(prebuilts + "/*/base.apk")
               + glob.glob(prebuilts + "/*/*/base.apk")
               + glob.glob(prebuilts + "/benchmark-apps/*arm64*.apk")
               + glob.glob(prebuilts + "/top-games/*.apk")
               + glob.glob(prebuilts + "/top-apps/*.apk"))
    for apk in sources:
        p = aapt.packagename(apk)
        if p and p not in m:
            m[p] = apk
    return m


def main():
    import yaml
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    default_repo = os.path.dirname(os.path.dirname(here))
    ap.add_argument("--repo", default=default_repo)
    ap.add_argument("--aapt2", default=None)
    ap.add_argument("--site", default=None,
                    help="path to the digitalisx64.github.io checkout")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    aapt = Aapt(args.aapt2 or os.path.join(args.repo, "out/host/linux-x86/bin/aapt2"))
    prebuilts = os.path.join(args.repo, "sample/prebuilts")
    site = args.site or os.path.join(args.repo, "digitalisx64.github.io")
    icons = os.path.join(site, "assets/icons")
    os.makedirs(icons, exist_ok=True)

    data = yaml.safe_load(open(os.path.join(site, "_data/apps.yml")))
    pmap = build_pkg_map(aapt, prebuilts)

    real, avatar = 0, []
    for status in ("verified", "partial", "blocked"):
        for app in (data.get(status) or []):
            pkg = app["package"]
            dest = os.path.join(icons, pkg + ".png")
            if os.path.exists(dest) and not args.force:
                continue
            img = None
            apk = pmap.get(pkg)
            if apk:
                try:
                    img = icon_from_apk(aapt, apk)
                except Exception:
                    img = None
            if img is not None:
                img.convert("RGBA").resize((SIZE, SIZE), Image.LANCZOS).save(
                    dest, "PNG", optimize=True)
                real += 1
            else:
                monogram(app["name"], dest)
                avatar.append(pkg)
    print("real-icons=%d monogram-avatars=%d" % (real, len(avatar)))
    for a in avatar:
        print("  avatar", a)


if __name__ == "__main__":
    main()
