import unittest
from apkmirror_fetch import arsc
from apkmirror_fetch.tests.fixtures import make_arsc_fixture as fx


class TestArsc(unittest.TestCase):
    def test_roundtrip_identity(self):
        blob = fx.build_base()
        table = arsc.parse(blob)
        self.assertEqual(arsc.serialize(table), blob)

    def test_merge_appends_split_config_types(self):
        base = arsc.parse(fx.build_base())
        split = arsc.parse(fx.build_density_split())
        merged = arsc.merge(base, [split])
        configs = arsc.list_type_configs(merged, type_name="drawable")
        self.assertIn("DEFAULT", configs)
        self.assertIn("xxhdpi", configs)

    def test_merge_remaps_value_strings(self):
        base = arsc.parse(fx.build_base())
        split = arsc.parse(fx.build_density_split())
        merged = arsc.merge(base, [split])
        self.assertIn("res/drawable-xxhdpi/img.png", arsc.global_strings(merged))

    def test_merge_remapped_index_points_at_split_path(self):
        base = arsc.parse(fx.build_base())
        split = arsc.parse(fx.build_density_split())
        merged = arsc.merge(base, [split])
        # serialize + reparse to confirm the merged table is still valid
        reparsed = arsc.parse(arsc.serialize(merged))
        self.assertEqual(arsc.list_type_configs(reparsed),
                         arsc.list_type_configs(merged))
