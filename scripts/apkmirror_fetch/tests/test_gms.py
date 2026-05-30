import unittest
from apkmirror_fetch import gms
from apkmirror_fetch.tests.fixtures import make_axml_fixture as fx


class TestGms(unittest.TestCase):
    def test_detects_gms_meta(self):
        blob = fx.build_bytes_with_meta_name("com.google.android.gms.version")
        res = gms.detect_from_manifest_bytes(blob)
        self.assertTrue(res.depends_on_gms)
        self.assertIn("gms.version", res.reason)

    def test_no_gms(self):
        blob = fx.build_bytes_with_meta_name("some.unrelated.meta")
        res = gms.detect_from_manifest_bytes(blob)
        self.assertFalse(res.depends_on_gms)
