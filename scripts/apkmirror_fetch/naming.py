"""Build and parse apkmirror.com-convention APK filenames."""
import re

_RE = re.compile(r"^(?P<pkg>[A-Za-z0-9._]+)_(?P<ver>[^_-]+(?:\.[^_-]+)*)"
                 r"(?:-\d+)?_minAPI\d+\(arm64-v8a\).*_apkmirror\.com\.apk$")


def build_filename(package, version, min_api, dpi="nodpi"):
    return ("%s_%s_minAPI%d(arm64-v8a)(%s)_apkmirror.com.apk"
            % (package, version, min_api, dpi))


def parse_filename(name):
    m = _RE.match(name)
    if not m:
        return (None, None)
    return (m.group("pkg"), m.group("ver"))
