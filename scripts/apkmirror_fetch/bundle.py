"""Merge an APKMirror .apkm split bundle into one installable arm64-v8a APK."""
import io
import os
import re
import zipfile
from dataclasses import dataclass, field
from typing import List

from apkmirror_fetch import arsc, axml, apksign

_ARCH_RE = re.compile(r"split_config\.arm64_v8a\.apk$")
_CONFIG_RE = re.compile(r"split_config\.(.+)\.apk$")
_OTHER_ARCH = ("armeabi_v7a", "x86", "x86_64", "armeabi")


@dataclass
class Selection:
    base: str
    arch: str
    extras: List[str] = field(default_factory=list)


def select_splits(names, mode):
    apks = [n for n in names if n.endswith(".apk")]
    arch = next((n for n in apks if _ARCH_RE.search(n)), None)
    splits = [n for n in apks if _CONFIG_RE.search(n)]
    bases = [n for n in apks if n not in splits]
    base = next((n for n in bases if n.endswith("base.apk")),
                bases[0] if bases else None)
    extras = []
    if mode == "full":
        for n in splits:
            if _ARCH_RE.search(n):
                continue
            label = _CONFIG_RE.search(n).group(1)
            if label in _OTHER_ARCH:
                continue
            extras.append(n)
    return Selection(base=base, arch=arch, extras=extras)


def _native_merge(base_bytes, arch_bytes):
    out = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(base_bytes)) as zb, \
            zipfile.ZipFile(io.BytesIO(arch_bytes)) as za, \
            zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as zo:
        for zi in zb.infolist():
            if zi.is_dir():
                continue
            data = zb.read(zi.filename)
            if zi.filename == "AndroidManifest.xml":
                data = axml.patch_drop_split_markers(data)
            zo.writestr(zi.filename, data)
        for zi in za.infolist():
            if zi.filename.startswith("lib/arm64-v8a/") and not zi.is_dir():
                zo.writestr(zi.filename, za.read(zi.filename))
    return out.getvalue()


def _full_merge(splits_bytes, sel):
    merged = _native_merge(splits_bytes[sel.base], splits_bytes[sel.arch])
    with zipfile.ZipFile(io.BytesIO(merged)) as zm:
        has_arsc = "resources.arsc" in zm.namelist()
    if not has_arsc or not sel.extras:
        return merged

    split_tables, res_files = [], {}
    for name in sel.extras:
        with zipfile.ZipFile(io.BytesIO(splits_bytes[name])) as zs:
            nm = zs.namelist()
            if "resources.arsc" in nm:
                split_tables.append(arsc.parse(zs.read("resources.arsc")))
            for f in nm:
                if f.startswith("res/"):
                    res_files[f] = zs.read(f)

    with zipfile.ZipFile(io.BytesIO(merged)) as zm:
        base_table = arsc.parse(zm.read("resources.arsc"))
        if split_tables:
            base_table = arsc.merge(base_table, split_tables)
        new_arsc = arsc.serialize(base_table)
        out = io.BytesIO()
        with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as zo:
            for zi in zm.infolist():
                if zi.is_dir():
                    continue
                if zi.filename == "resources.arsc":
                    zo.writestr("resources.arsc", new_arsc)
                elif zi.filename in res_files:
                    continue   # superseded by the split copy below
                else:
                    zo.writestr(zi.filename, zm.read(zi.filename))
            for f, data in res_files.items():
                zo.writestr(f, data)
    return out.getvalue()


def merge_apkm(apkm_path, out_path, cache_dir, mode="full"):
    """Merge .apkm -> one signed APK. Returns 'full' or 'native-fallback'."""
    with zipfile.ZipFile(apkm_path) as z:
        names = z.namelist()
        sel = select_splits(names, mode)
        if not sel.base or not sel.arch:
            raise ValueError("bundle missing base or arm64-v8a split")
        blobs = {n: z.read(n) for n in [sel.base, sel.arch] + sel.extras}

    used_mode = mode
    try:
        merged = (_full_merge(blobs, sel) if mode == "full"
                  else _native_merge(blobs[sel.base], blobs[sel.arch]))
    except Exception:
        if mode != "full":
            raise
        used_mode = "native-fallback"
        merged = _native_merge(blobs[sel.base], blobs[sel.arch])

    tmp = out_path + ".unsigned"
    with open(tmp, "wb") as f:
        f.write(merged)
    try:
        apksign.sign(tmp, out_path, cache_dir=cache_dir)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    return "full" if used_mode == "full" else "native-fallback"
