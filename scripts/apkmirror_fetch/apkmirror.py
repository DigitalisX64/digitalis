"""APKMirror download walk: version page -> variant -> token page -> file.

The HTML-parsing helpers (parse_variants/select_variant) are unit-tested against a
fixture and carry the stable logic. The live Session walks the real site and its regexes
may need tuning against current markup; it is exercised manually, not in unit tests.
"""
import re
import time
from dataclasses import dataclass

BASE = "https://www.apkmirror.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/124.0 Safari/537.36")

_ARCH_RE = re.compile(r"\b(arm64-v8a|armeabi-v7a|x86_64|x86|universal)\b")
_API_RE = re.compile(r"(?:min[^0-9]*|API\s*)(\d{1,2})", re.I)
_DPI_RE = re.compile(r"\b(nodpi|\d[\d,]*dpi)\b")
_BUNDLE_RE = re.compile(r"\bBUNDLE\b")
_HREF_RE = re.compile(r'href="([^"]+)"')


@dataclass
class Variant:
    arch: str
    min_api: int
    dpi: str
    kind: str          # "APK" or "BUNDLE"
    url: str


def parse_variants(html):
    variants = []
    for seg in re.split(r'class="table-row', html)[1:]:
        am = _ARCH_RE.search(seg)
        if not am:
            continue
        arch = am.group(1)
        api_m = _API_RE.search(seg)
        api = int(api_m.group(1)) if api_m else 0
        dpi_m = _DPI_RE.search(seg)
        dpi = dpi_m.group(1) if dpi_m else "nodpi"
        kind = "BUNDLE" if _BUNDLE_RE.search(seg) else "APK"
        href_m = _HREF_RE.search(seg)
        url = (BASE + href_m.group(1)) if href_m else ""
        variants.append(Variant(arch, api, dpi, kind, url))
    return variants


_DPI_PREF = {"nodpi": 0, "universal": 1}


def select_variant(variants):
    arm = [v for v in variants if v.arch == "arm64-v8a"] or list(variants)
    if not arm:
        return None

    def score(v):
        return (0 if v.kind == "APK" else 1, _DPI_PREF.get(v.dpi, 2))

    return sorted(arm, key=score)[0]


# ----- live session (manually exercised) -----

class Session:
    # apkmirror rate-limits / Cloudflare-403s bulk access; back off and retry.
    _RETRY_STATUS = (403, 429, 503)

    def __init__(self, throttle=2.0, max_retries=6, backoff_base=5.0):
        import requests
        self._requests = requests
        self.s = requests.Session()
        self.s.headers["User-Agent"] = UA
        self.throttle = throttle
        self.max_retries = max_retries
        self.backoff_base = backoff_base
        self._last = 0.0

    def _get(self, url, referer=None, **kw):
        if referer:
            self.s.headers["Referer"] = referer
        last_exc = None
        for attempt in range(self.max_retries):
            wait = self.throttle - (time.monotonic() - self._last)
            if wait > 0:
                time.sleep(wait)
            try:
                r = self.s.get(url, timeout=60, **kw)
                self._last = time.monotonic()
            except self._requests.RequestException as e:
                last_exc = e
                time.sleep(self.backoff_base * (2 ** attempt))
                continue
            if r.status_code in self._RETRY_STATUS and attempt < self.max_retries - 1:
                # honor Retry-After if present, else exponential back-off
                ra = r.headers.get("Retry-After")
                delay = (float(ra) if ra and ra.isdigit()
                         else self.backoff_base * (2 ** attempt))
                time.sleep(delay)
                continue
            r.raise_for_status()
            return r
        if last_exc:
            raise last_exc
        raise RuntimeError("exhausted retries for %s" % url)

    def version_page_url(self, slug, version):
        app = slug.split("/")[-1]
        vslug = version.replace(".", "-")
        return "%s/apk/%s/%s-%s-release/" % (BASE, slug, app, vslug)

    def find_version_page(self, slug, version, max_pages=5):
        """Locate the version-release page for a pinned version.

        apkmirror's release-page slug uses the app's *display title* (e.g.
        firefox-fast-private-browser-151-0-2-release), which often differs from the
        URL slug. Try the direct construction first (works when title == slug, e.g.
        whatsapp); otherwise scrape the app page (and a few paginated pages) for the
        release link whose trailing version matches.
        """
        vdash = version.replace(".", "-")
        direct = self.version_page_url(slug, version)
        try:
            self._get(direct)
            return direct
        except Exception:
            pass
        suffix = "-%s-release" % vdash
        # version slugs may contain underscores (build codes), e.g. Genshin's
        # genshin-impact-5-0-0_26041933_26161852-release.
        rel_re = re.compile(r'href="(/apk/%s/[a-z0-9][a-z0-9._\-]*-release)/?"'
                            % re.escape(slug))
        for page in range(1, max_pages + 1):
            url = "%s/apk/%s/" % (BASE, slug)
            if page > 1:
                url += "?page=%d" % page
            try:
                html = self._get(url).text
            except Exception:
                break
            for rel in rel_re.findall(html):
                if rel.endswith(suffix):
                    return BASE + rel + "/"
        raise ValueError("version %s not found for %s" % (version, slug))

    def resolve_download(self, variant_url):
        html = self._get(variant_url).text
        m = re.search(r'href="(/apk/[^"]+/download/[^"]*)"', html)
        if not m:
            raise ValueError("no download link on variant page %s" % variant_url)
        dl_page = BASE + m.group(1)
        html2 = self._get(dl_page, referer=variant_url).text
        # The actual file link is a download.php?id=...&key=... anchor (rel=nofollow);
        # download.php 302-redirects to the real CDN file, which requests follows.
        m2 = re.search(r'href="(/wp-content/[^"]*download\.php\?[^"]+)"', html2)
        if not m2:
            raise ValueError("no final download link on %s" % dl_page)
        final = BASE + m2.group(1).replace("&#038;", "&").replace("&amp;", "&")
        return final, dl_page

    def download(self, file_url, referer, dest_path):
        with self.s.get(file_url, headers={"Referer": referer}, stream=True,
                        timeout=300) as r:
            r.raise_for_status()
            with open(dest_path, "wb") as f:
                for chunk in r.iter_content(1 << 16):
                    f.write(chunk)
