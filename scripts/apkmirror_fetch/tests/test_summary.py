import unittest
from apkmirror_fetch import summary


class TestSummary(unittest.TestCase):
    def test_renders_status_and_gms(self):
        rows = [
            summary.Row("com.whatsapp", "DOWNLOADED 2.26.19.4", gms=False),
            summary.Row("com.facebook.katana", "MERGED (full)",
                        gms=True, gms_reason="gms.version meta-data"),
        ]
        text = summary.render(rows)
        self.assertIn("com.whatsapp", text)
        self.assertIn("DOWNLOADED 2.26.19.4", text)
        self.assertIn("Apps depending on Google Mobile Services", text)
        gms_section = text.split(
            "Apps depending on Google Mobile Services")[1]
        self.assertIn("com.facebook.katana", gms_section)
        self.assertNotIn("com.whatsapp",
                         gms_section.split("NO GMS dependency")[0])

    def test_any_failed(self):
        rows = [summary.Row("x", "FAILED (network)", gms=False)]
        self.assertTrue(summary.any_failed(rows))
        ok = [summary.Row("y", "SKIPPED (current)")]
        self.assertFalse(summary.any_failed(ok))
