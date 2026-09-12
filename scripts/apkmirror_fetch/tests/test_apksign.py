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
            # META-INF payload that a re-sign must carry through, alongside the
            # stale signature files it must replace.
            z.writestr("META-INF/services/io.example.SenderProvider",
                       b"io.example.impl.OkHttpSender\n")
            z.writestr("META-INF/versions/9/module-info.class", b"cafebabe")
            z.writestr("META-INF/androidx.room_room-runtime.version", b"2.6.1")
            z.writestr("META-INF/MANIFEST.MF", b"Manifest-Version: 1.0\r\n\r\n")
            z.writestr("META-INF/OLDCERT.SF", b"stale\n")
            z.writestr("META-INF/OLDCERT.RSA", b"stale\n")
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

    def test_meta_inf_services_survive_resigning(self):
        # ServiceLoader registrations are application payload, not signature
        # files. Stripping them re-signs cleanly and then fails at runtime with
        # "No <X>Provider found on classpath" — an app-init crash that reads as
        # a translator or app bug rather than as damage done by this pipeline.
        signed = self._sign()
        with zipfile.ZipFile(signed) as z:
            self.assertEqual(z.read("META-INF/services/io.example.SenderProvider"),
                             b"io.example.impl.OkHttpSender\n")
            self.assertEqual(z.read("META-INF/versions/9/module-info.class"), b"cafebabe")
            self.assertEqual(z.read("META-INF/androidx.room_room-runtime.version"), b"2.6.1")

    def test_stale_signature_files_are_replaced(self):
        signed = self._sign()
        with zipfile.ZipFile(signed) as z:
            names = z.namelist()
            self.assertNotIn("META-INF/OLDCERT.SF", names)
            self.assertNotIn("META-INF/OLDCERT.RSA", names)
            self.assertEqual(names.count("META-INF/MANIFEST.MF"), 1)
            self.assertIn(b"Created-By: Digitalis", z.read("META-INF/MANIFEST.MF"))

    def test_preserved_meta_inf_entries_are_digested(self):
        # A kept entry that is missing from MANIFEST.MF makes the APK fail v1
        # verification on API < 24, so it must be digested like any other file.
        signed = self._sign()
        with zipfile.ZipFile(signed) as z:
            manifest = z.read("META-INF/MANIFEST.MF")
        self.assertIn(b"Name: META-INF/services/io.example.SenderProvider", manifest)

    def test_signature_entry_predicate(self):
        sig = ["META-INF/MANIFEST.MF", "META-INF/CERT.SF", "META-INF/CERT.RSA",
               "META-INF/CERT.DSA", "META-INF/CERT.EC", "META-INF/SIG-FOO",
               "META-INF/manifest.mf", "META-INF/cert.rsa"]
        payload = ["META-INF/services/java.security.Provider",
                   "META-INF/versions/9/foo.class",
                   "META-INF/proguard/okhttp3.pro",
                   "META-INF/kotlinx_coroutines.kotlin_module",
                   "META-INF/subdir/CERT.RSA"]
        for name in sig:
            self.assertTrue(apksign._is_signature_entry(name), name)
        for name in payload:
            self.assertFalse(apksign._is_signature_entry(name), name)

    @unittest.skipUnless(shutil.which("apksigner"), "apksigner not on PATH")
    def test_apksigner_verifies(self):
        signed = self._sign()
        r = subprocess.run(["apksigner", "verify", signed], capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr.decode())
