import os
import tempfile
import unittest
import zipfile
from apkmirror_fetch import zipalign


class TestZipalign(unittest.TestCase):
    def _make_zip(self):
        fd, path = tempfile.mkstemp(suffix=".apk")
        os.close(fd)
        self.addCleanup(os.remove, path)
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("AndroidManifest.xml", b"x" * 7)
            zi = zipfile.ZipInfo("lib/arm64-v8a/libfoo.so")
            zi.compress_type = zipfile.ZIP_STORED
            z.writestr(zi, b"y" * 100)
        return path

    def test_so_entries_aligned_4096(self):
        path = self._make_zip()
        out = path + ".aligned"
        self.addCleanup(lambda: os.path.exists(out) and os.remove(out))
        zipalign.align(path, out)
        offs = zipalign.data_offsets(out)
        self.assertEqual(offs["lib/arm64-v8a/libfoo.so"] % 4096, 0)

    def test_aligned_zip_still_readable(self):
        path = self._make_zip()
        out = path + ".aligned"
        self.addCleanup(lambda: os.path.exists(out) and os.remove(out))
        zipalign.align(path, out)
        with zipfile.ZipFile(out) as z:
            self.assertEqual(z.read("lib/arm64-v8a/libfoo.so"), b"y" * 100)
            self.assertEqual(z.read("AndroidManifest.xml"), b"x" * 7)
