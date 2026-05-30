import unittest
from apkmirror_fetch import deps


class TestDeps(unittest.TestCase):
    def test_present_modules_report_no_missing(self):
        self.assertEqual(deps.missing_modules(["sys", "json"]), [])

    def test_absent_module_is_reported(self):
        self.assertEqual(
            deps.missing_modules(["sys", "definitely_not_a_module_xyz"]),
            ["definitely_not_a_module_xyz"])

    def test_hint_lists_pip_install(self):
        msg = deps.install_hint(["requests", "cryptography"])
        self.assertIn("pip install requests cryptography", msg)
