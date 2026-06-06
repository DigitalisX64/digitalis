import io
import os
import shutil
import tempfile
import unittest
import zipfile

from apkmirror_fetch import bundle, axml, apksign
from apkmirror_fetch.tests.fixtures import make_axml_fixture as fx_axml
from apkmirror_fetch.tests.fixtures import make_arsc_fixture as fx_arsc


def _apk(entries):
    bio = io.BytesIO()
    with zipfile.ZipFile(bio, "w") as z:
        for name, data in entries.items():
            zi = zipfile.ZipInfo(name)
            zi.compress_type = zipfile.ZIP_STORED
            z.writestr(zi, data)
    return bio.getvalue()


class TestBundle(unittest.TestCase):
    def test_select_splits(self):
        names = ["base.apk", "split_config.arm64_v8a.apk",
                 "split_config.xxhdpi.apk", "split_config.en.apk", "icon.png"]
        sel = bundle.select_splits(names, mode="full")
        self.assertEqual(sel.base, "base.apk")
        self.assertEqual(sel.arch, "split_config.arm64_v8a.apk")
        self.assertIn("split_config.xxhdpi.apk", sel.extras)
        self.assertNotIn("split_config.arm64_v8a.apk", sel.extras)
        sel_n = bundle.select_splits(names, mode="native")
        self.assertEqual(sel_n.extras, [])

    def test_select_splits_skips_other_abis(self):
        names = ["base.apk", "split_config.arm64_v8a.apk",
                 "split_config.x86_64.apk", "split_config.armeabi_v7a.apk"]
        sel = bundle.select_splits(names, mode="full")
        self.assertEqual(sel.extras, [])

    def test_native_merge_copies_arm64_libs(self):
        base = _apk({"AndroidManifest.xml": fx_axml.build_bytes(),
                     "classes.dex": b"d"})
        arch = _apk({"lib/arm64-v8a/libfoo.so": b"so"})
        out = bundle._native_merge(base, arch)
        with zipfile.ZipFile(io.BytesIO(out)) as z:
            self.assertIn("lib/arm64-v8a/libfoo.so", z.namelist())
            self.assertIn("classes.dex", z.namelist())
            # split markers stripped from the manifest
            doc = axml.parse(z.read("AndroidManifest.xml"))
            self.assertNotIn("requiredSplitTypes",
                             {a.name for a in doc.root.attributes})

    def _make_apkm(self):
        base = _apk({
            "AndroidManifest.xml": fx_axml.build_bytes(),
            "resources.arsc": fx_arsc.build_base(),
            "classes.dex": b"dex\n",
        })
        arch = _apk({"lib/arm64-v8a/libfoo.so": b"\x7fELF" + b"\x00" * 64})
        xxhdpi = _apk({
            "resources.arsc": fx_arsc.build_density_split(),
            "res/drawable-xxhdpi/img.png": b"PNGDATA",
        })
        fd, path = tempfile.mkstemp(suffix=".apkm")
        os.close(fd)
        self.addCleanup(os.remove, path)
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("base.apk", base)
            z.writestr("split_config.arm64_v8a.apk", arch)
            z.writestr("split_config.xxhdpi.apk", xxhdpi)
            z.writestr("meta.sai_v2.json", b"{}")
        return path

    def test_native_merge_end_to_end(self):
        # Native mode is the pure-Python base+arm64-lib merge (no Java). It signs,
        # strips manifest split markers, and keeps only base.apk's resource table.
        # The full APKEditor merge is exercised live by the fetch script against a
        # real bundle (a synthetic fixture manifest is too minimal for APKEditor).
        apkm = self._make_apkm()
        cache = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, cache, ignore_errors=True)
        out = apkm + ".merged.apk"
        self.addCleanup(lambda: os.path.exists(out) and os.remove(out))

        mode = bundle.merge_apkm(apkm, out, cache_dir=cache, mode="native")
        self.assertEqual(mode, "native")

        # signed and self-verifies
        self.assertTrue(apksign.has_v2_block(out))
        self.assertTrue(apksign.verify(out))

        with zipfile.ZipFile(out) as z:
            names = z.namelist()
            self.assertIn("lib/arm64-v8a/libfoo.so", names)
            self.assertIn("resources.arsc", names)
            # manifest split markers stripped
            doc = axml.parse(z.read("AndroidManifest.xml"))
            self.assertNotIn("requiredSplitTypes",
                             {a.name for a in doc.root.attributes})

    def test_strip_foreign_abis(self):
        src = _apk({
            "AndroidManifest.xml": fx_axml.build_bytes(),
            "lib/arm64-v8a/libfoo.so": b"keep",
            "lib/armeabi-v7a/libfoo.so": b"drop",
            "lib/x86_64/libfoo.so": b"drop",
            "res/x.png": b"keep",
        })
        out = bundle._strip_foreign_abis(src)
        with zipfile.ZipFile(io.BytesIO(out)) as z:
            names = z.namelist()
            self.assertIn("lib/arm64-v8a/libfoo.so", names)
            self.assertIn("res/x.png", names)
            self.assertNotIn("lib/armeabi-v7a/libfoo.so", names)
            self.assertNotIn("lib/x86_64/libfoo.so", names)
