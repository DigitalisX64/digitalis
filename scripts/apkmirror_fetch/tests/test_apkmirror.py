import os
import unittest
from apkmirror_fetch import apkmirror

HERE = os.path.dirname(__file__)


class TestApkmirror(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(HERE, "fixtures", "variant_table.html"),
                  encoding="utf-8") as f:
            self.html = f.read()

    def test_parse_variants(self):
        variants = apkmirror.parse_variants(self.html)
        arches = {v.arch for v in variants}
        self.assertIn("arm64-v8a", arches)
        self.assertIn("armeabi-v7a", arches)
        self.assertTrue(all(v.url.startswith("https://www.apkmirror.com/")
                            for v in variants))

    def test_parse_variants_reads_kind_and_dpi(self):
        variants = apkmirror.parse_variants(self.html)
        kinds = {v.kind for v in variants}
        self.assertEqual(kinds, {"APK", "BUNDLE"})
        self.assertTrue(all(v.dpi == "nodpi" for v in variants))
        self.assertTrue(all(v.min_api == 21 for v in variants))

    def test_select_prefers_single_apk_arm64(self):
        variants = apkmirror.parse_variants(self.html)
        chosen = apkmirror.select_variant(variants)
        self.assertEqual(chosen.arch, "arm64-v8a")
        self.assertEqual(chosen.kind, "APK")

    def test_select_falls_back_to_bundle(self):
        variants = [v for v in apkmirror.parse_variants(self.html)
                    if v.kind == "BUNDLE"]
        chosen = apkmirror.select_variant(variants)
        self.assertEqual(chosen.kind, "BUNDLE")
        self.assertEqual(chosen.arch, "arm64-v8a")

    def test_version_page_url(self):
        s = object.__new__(apkmirror.Session)  # no network
        url = apkmirror.Session.version_page_url(s, "whatsapp-inc/whatsapp",
                                                 "2.26.19.4")
        self.assertEqual(
            url, "https://www.apkmirror.com/apk/whatsapp-inc/whatsapp/"
                 "whatsapp-2-26-19-4-release/")
