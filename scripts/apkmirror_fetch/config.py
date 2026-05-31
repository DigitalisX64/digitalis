"""Load and validate apkmirror-apps.json into AppEntry records."""
import json
from dataclasses import dataclass
from typing import List, Optional


class ConfigError(Exception):
    pass


@dataclass(frozen=True)
class AppEntry:
    package: str
    slug: str
    version: str
    note: Optional[str] = None
    category: str = "app"   # "app" -> top-apps/, "game" -> top-games/

    @property
    def subdir(self):
        return "top-games" if self.category == "game" else "top-apps"


def load(path: str, only: Optional[List[str]] = None) -> List[AppEntry]:
    with open(path, "r", encoding="utf-8") as f:
        raw = json.load(f)
    if not isinstance(raw, list):
        raise ConfigError("config root must be a JSON array")
    apps, seen = [], set()
    for i, item in enumerate(raw):
        for key in ("package", "slug", "version"):
            if key not in item or not isinstance(item[key], str) or not item[key]:
                raise ConfigError("entry %d missing required string '%s'" % (i, key))
        if item["package"] in seen:
            raise ConfigError("duplicate package '%s'" % item["package"])
        category = item.get("category", "app")
        if category not in ("app", "game"):
            raise ConfigError("entry %d: category must be 'app' or 'game'" % i)
        seen.add(item["package"])
        apps.append(AppEntry(package=item["package"], slug=item["slug"],
                             version=item["version"], note=item.get("note"),
                             category=category))
    if only:
        wanted = set(only)
        apps = [a for a in apps if a.package in wanted]
    return apps
