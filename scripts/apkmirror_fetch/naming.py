"""Build and parse apkmirror.com-convention APK filenames."""
import re

# The version is the digit-led run (dots + underscores; underscores appear in build
# codes, e.g. Genshin's 6.6.0_44318314_44476906) immediately before "_minAPI"; an
# optional "-<digits>" build suffix (e.g. Facebook) is dropped. The package is what
# precedes it — package ids may themselves contain underscores (e.g. cn.wps.moffice_eng),
# so the package is matched lazily and the "_minAPI" anchor disambiguates the boundary.
_RE = re.compile(r"^(?P<pkg>.+?)_(?P<ver>[0-9][0-9._]*?)"
                 r"(?:-\d+)?_minAPI\d+\(arm64-v8a\).*_apkmirror\.com\.apk$")


def build_filename(package, version, min_api, dpi="nodpi"):
    return ("%s_%s_minAPI%d(arm64-v8a)(%s)_apkmirror.com.apk"
            % (package, version, min_api, dpi))


def parse_filename(name):
    m = _RE.match(name)
    if not m:
        return (None, None)
    return (m.group("pkg"), m.group("ver"))
