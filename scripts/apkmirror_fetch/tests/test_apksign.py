import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from apkmirror_fetch import apksign


class TestApkSign(unittest.TestCase):
    def setUp(self):
        self.cache = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.cache, ignore_errors=True)

    def _unsigned(self):
        fd, path = tempfile.mkstemp(suffix=".apk")
        os.close(fd)
        self.addCleanup(os.remove, path)
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("AndroidManifest.xml", b"\x03\x00\x08\x00")
            z.writestr("classes.dex", b"dex\n")
            zi = zipfile.ZipInfo("lib/arm64-v8a/libfoo.so")
            zi.compress_type = zipfile.ZIP_STORED
            z.writestr(zi, b"\x7fELF" + b"\x00" * 200)
        return path

    def _sign(self):
        path = self._unsigned()
        signed = path + ".signed"
        self.addCleanup(lambda: os.path.exists(signed) and os.remove(signed))
        apksign.sign(path, signed, cache_dir=self.cache)
        return signed

    def test_v1_block_present(self):
        signed = self._sign()
        with zipfile.ZipFile(signed) as z:
            names = z.namelist()
        self.assertIn("META-INF/MANIFEST.MF", names)
        self.assertIn("META-INF/CERT.SF", names)
        self.assertIn("META-INF/CERT.RSA", names)

    def test_v2_signing_block_present(self):
        signed = self._sign()
        self.assertTrue(apksign.has_v2_block(signed))

    def test_v2_self_verifies(self):
        signed = self._sign()
        self.assertTrue(apksign.verify(signed))

    def test_signed_zip_still_readable(self):
        signed = self._sign()
        with zipfile.ZipFile(signed) as z:
            self.assertEqual(z.read("classes.dex"), b"dex\n")
            self.assertTrue(z.read("lib/arm64-v8a/libfoo.so").startswith(b"\x7fELF"))

    @unittest.skipUnless(shutil.which("apksigner"), "apksigner not on PATH")
    def test_apksigner_verifies(self):
        signed = self._sign()
        r = subprocess.run(["apksigner", "verify", signed], capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr.decode())
