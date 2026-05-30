import unittest
from apkmirror_fetch import axml
from apkmirror_fetch.tests.fixtures import make_axml_fixture as fx


class TestAxml(unittest.TestCase):
    def setUp(self):
        self.blob = fx.build_bytes()

    def test_read_attributes(self):
        doc = axml.parse(self.blob)
        manifest = doc.root
        self.assertEqual(manifest.name, "manifest")
        names = {a.name for a in manifest.attributes}
        self.assertIn("requiredSplitTypes", names)
        child = manifest.children[0]
        self.assertEqual(child.name, "meta-data")
        self.assertEqual(child.attr("name"),
                         "com.android.vending.splits.required")

    def test_patch_removes_split_markers(self):
        patched = axml.patch_drop_split_markers(self.blob)
        doc = axml.parse(patched)
        self.assertNotIn("requiredSplitTypes",
                         {a.name for a in doc.root.attributes})
        self.assertEqual(len(doc.root.children), 0)

    def test_patch_is_valid_axml(self):
        patched = axml.patch_drop_split_markers(self.blob)
        self.assertEqual(axml.parse(patched).root.name, "manifest")
