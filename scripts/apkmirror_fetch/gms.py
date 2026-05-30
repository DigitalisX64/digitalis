"""Detect Google Mobile Services (GMS) dependency from an APK manifest."""
import zipfile
from dataclasses import dataclass
from apkmirror_fetch import axml

_GMS_PREFIXES = ("com.google.android.gms", "com.google.android.c2dm",
                 "com.google.firebase")


@dataclass
class GmsResult:
    depends_on_gms: bool
    reason: str


def _scan(doc):
    hits = []

    def walk(el):
        for a in el.attributes:
            if a.value and a.value.startswith(_GMS_PREFIXES):
                if "gms.version" in a.value:
                    hits.append("gms.version meta-data")
                else:
                    hits.append("gms.* reference")
        for c in el.children:
            walk(c)

    if doc.root is not None:
        walk(doc.root)
    return hits


def detect_from_manifest_bytes(blob):
    hits = _scan(axml.parse(blob))
    if hits:
        seen, uniq = set(), []
        for h in hits:
            if h not in seen:
                seen.add(h)
                uniq.append(h)
        return GmsResult(True, ", ".join(uniq))
    return GmsResult(False, "")


def detect_from_apk(path):
    with zipfile.ZipFile(path) as z:
        blob = z.read("AndroidManifest.xml")
    return detect_from_manifest_bytes(blob)
