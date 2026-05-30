import unittest
from apkmirror_fetch import naming


class TestNaming(unittest.TestCase):
    def test_build_basic(self):
        n = naming.build_filename("com.whatsapp", "2.26.19.4", min_api=21,
                                  dpi="nodpi")
        self.assertEqual(
            n, "com.whatsapp_2.26.19.4_minAPI21(arm64-v8a)(nodpi)_apkmirror.com.apk")

    def test_parse_roundtrip(self):
        n = naming.build_filename("com.whatsapp", "2.26.19.4", min_api=21,
                                  dpi="nodpi")
        pkg, ver = naming.parse_filename(n)
        self.assertEqual(pkg, "com.whatsapp")
        self.assertEqual(ver, "2.26.19.4")

    def test_parse_existing_real_name(self):
        n = ("com.facebook.katana_561.0.0.42.67-471216165_minAPI28(arm64-v8a)"
             "(360,400,420,480,560,640dpi)_apkmirror.com.apk")
        pkg, ver = naming.parse_filename(n)
        self.assertEqual(pkg, "com.facebook.katana")
        self.assertEqual(ver, "561.0.0.42.67")

    def test_parse_non_matching_returns_none(self):
        self.assertEqual(naming.parse_filename("random.apk"), (None, None))
