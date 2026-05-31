import json
import os
import tempfile
import unittest
from apkmirror_fetch import config


class TestConfig(unittest.TestCase):
    def _write(self, data):
        fd, path = tempfile.mkstemp(suffix=".json")
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
        self.addCleanup(os.remove, path)
        return path

    def test_loads_valid_entries(self):
        path = self._write([
            {"package": "com.whatsapp", "slug": "whatsapp-inc/whatsapp",
             "version": "2.26.19.4"}])
        apps = config.load(path)
        self.assertEqual(len(apps), 1)
        self.assertEqual(apps[0].package, "com.whatsapp")
        self.assertEqual(apps[0].slug, "whatsapp-inc/whatsapp")
        self.assertEqual(apps[0].version, "2.26.19.4")
        self.assertIsNone(apps[0].note)
        self.assertEqual(apps[0].category, "app")
        self.assertEqual(apps[0].subdir, "top-apps")

    def test_category_game_routes_to_top_games(self):
        path = self._write([
            {"package": "com.king.candycrushsaga", "slug": "king/candy-crush-saga",
             "version": "1.0", "category": "game"}])
        apps = config.load(path)
        self.assertEqual(apps[0].category, "game")
        self.assertEqual(apps[0].subdir, "top-games")

    def test_invalid_category_raises(self):
        path = self._write([
            {"package": "x", "slug": "a/b", "version": "1", "category": "bogus"}])
        with self.assertRaises(config.ConfigError):
            config.load(path)

    def test_missing_required_field_raises(self):
        path = self._write([{"package": "x", "slug": "a/b"}])
        with self.assertRaises(config.ConfigError):
            config.load(path)

    def test_duplicate_package_raises(self):
        path = self._write([
            {"package": "x", "slug": "a/b", "version": "1"},
            {"package": "x", "slug": "a/c", "version": "2"}])
        with self.assertRaises(config.ConfigError):
            config.load(path)

    def test_filter_by_packages(self):
        path = self._write([
            {"package": "x", "slug": "a/b", "version": "1"},
            {"package": "y", "slug": "a/c", "version": "2"}])
        apps = config.load(path, only=["y"])
        self.assertEqual([a.package for a in apps], ["y"])
