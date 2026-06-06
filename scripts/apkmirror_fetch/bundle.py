"""Merge an APKMirror .apkm split bundle into one installable arm64-v8a APK."""
import io
import os
import re
import zipfile
from dataclasses import dataclass, field
from typing import List

from apkmirror_fetch import axml, apksign, apkeditor

_ARCH_RE = re.compile(r"split_config\.arm64_v8a\.apk$")
_CONFIG_RE = re.compile(r"split_config\.(.+)\.apk$")
_OTHER_ARCH = ("armeabi_v7a", "x86", "x86_64", "armeabi")
# Foreign-ABI native-lib directories to strip from the merged universal APK; these
# regression APKs are arm64-v8a-only so any other ABI's libs are dead weight.
_KEEP_ABI = "arm64-v8a"
_FOREIGN_ABIS = ("armeabi-v7a", "armeabi", "x86", "x86_64", "mips", "mips64")


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


def _strip_foreign_abis(src_bytes):
    """Drop every native-lib dir except arm64-v8a from a merged universal APK.

    APKEditor fuses *all* ABI splits (it has no arm64-only mode), so the universal
    APK carries armeabi-v7a/x86/... libs we never run. Removing them keeps the
    artifact the same arm64-v8a-only shape as the single-APK download path and trims
    tens of MB. Resource entries are unaffected — only `lib/<abi>/` payloads go.
    """
    out = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(src_bytes)) as zin, \
            zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as zo:
        for zi in zin.infolist():
            if zi.is_dir():
                continue
            parts = zi.filename.split("/")
            if (len(parts) >= 2 and parts[0] == "lib"
                    and parts[1] in _FOREIGN_ABIS):
                continue
            zo.writestr(zi.filename, zin.read(zi.filename))
    return out.getvalue()


def _apkeditor_merge(apkm_path, cache_dir):
    """Full merge via APKEditor, then strip foreign-ABI libs. Returns APK bytes."""
    tmp_merged = os.path.join(cache_dir, "apkeditor_merged.apk")
    try:
        apkeditor.merge(apkm_path, tmp_merged, cache_dir)
        with open(tmp_merged, "rb") as f:
            merged = f.read()
    finally:
        if os.path.exists(tmp_merged):
            os.remove(tmp_merged)
    return _strip_foreign_abis(merged)


def merge_apkm(apkm_path, out_path, cache_dir, mode="full"):
    """Merge .apkm -> one signed arm64-v8a APK.

    Returns the merge mode actually used: 'full' (APKEditor, all splits including
    feature/density modules), 'native' (base + arm64 lib only, pure-Python), or
    'native-fallback' (APKEditor unavailable/failed in full mode, degraded to the
    pure-Python native merge — incomplete resource table, warned in the summary).
    """
    used_mode = mode
    if mode == "full":
        try:
            merged = _apkeditor_merge(apkm_path, cache_dir)
        except Exception:
            # APKEditor missing (no java / network) or failed: degrade to the
            # pure-Python base+arm64 merge so the fetch still yields *an* APK,
            # but flag it — its resource table is base-only and may crash.
            used_mode = "native-fallback"
            merged = _python_native_only(apkm_path)
    else:
        merged = _python_native_only(apkm_path)

    tmp = out_path + ".unsigned"
    with open(tmp, "wb") as f:
        f.write(merged)
    try:
        apksign.sign(tmp, out_path, cache_dir=cache_dir)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    return used_mode


def _python_native_only(apkm_path):
    """Pure-Python merge of base.apk + the arm64-v8a native split only."""
    with zipfile.ZipFile(apkm_path) as z:
        sel = select_splits(z.namelist(), "native")
        if not sel.base or not sel.arch:
            raise ValueError("bundle missing base or arm64-v8a split")
        return _native_merge(z.read(sel.base), z.read(sel.arch))
