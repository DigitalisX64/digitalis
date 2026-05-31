#!/usr/bin/env python3
# Copyright (C) 2026 utzcoz
# SPDX-License-Identifier: Apache-2.0
#
# Downloads a curated, version-pinned set of arm64-v8a APKs from apkmirror.com
# into sample/prebuilts/ for Digitalis translator regression testing. This is
# low-rate, explicit-list developer tooling; it paces requests politely.
import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from apkmirror_fetch import deps

REQUIRED = ["requests", "cryptography"]
_missing = deps.missing_modules(REQUIRED)
if _missing:
    print(deps.install_hint(REQUIRED))
    sys.exit(2)

import zipfile  # noqa: E402
from apkmirror_fetch import config, naming, apkmirror, bundle, gms, summary, axml  # noqa: E402


def _apk_package(apk_path):
    try:
        with zipfile.ZipFile(apk_path) as z:
            return axml.parse(z.read("AndroidManifest.xml")).root.attr("package")
    except Exception:
        return None

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PREBUILTS = os.path.join(ROOT, "sample", "prebuilts")
CONFIG = os.path.join(ROOT, "digitalis", "apkmirror-apps.json")
CACHE = os.path.join(ROOT, "digitalis", ".cache")


def _local_version(app):
    # Look only in the app's category subdir (top-apps/ or top-games/) so these
    # downloads stay separate from any manually-dropped APKs in the prebuilts root.
    subdir = os.path.join(PREBUILTS, app.subdir)
    if not os.path.isdir(subdir):
        return None, None
    for fn in os.listdir(subdir):
        if not fn.endswith(".apk"):
            continue
        pkg, ver = naming.parse_filename(fn)
        if pkg == app.package:
            return ver, os.path.join(subdir, fn)
    return None, None


def _annotate_gms(row, apk_path):
    try:
        res = gms.detect_from_apk(apk_path)
        row.gms, row.gms_reason = res.depends_on_gms, res.reason
    except Exception:
        pass


def _git_stage(rel_path):
    try:
        subprocess.run(["git", "add", rel_path], cwd=PREBUILTS,
                       check=False, capture_output=True)
    except Exception:
        pass


def _fetch_one(sess, app, local_path, args):
    vpage = sess.find_version_page(app.slug, app.version)
    variants = apkmirror.parse_variants(sess._get(vpage).text)
    chosen = apkmirror.select_variant(variants)
    if chosen is None:
        return summary.Row(app.package, "FAILED (no arm64 variant)")
    if chosen.kind == "BUNDLE" and args.no_merge:
        return summary.Row(app.package, "SKIPPED (bundle, --no-merge)")

    file_url, referer = sess.resolve_download(chosen.url)
    os.makedirs(CACHE, exist_ok=True)
    dest_dir = os.path.join(PREBUILTS, app.subdir)
    os.makedirs(dest_dir, exist_ok=True)
    fname = naming.build_filename(app.package, app.version,
                                  chosen.min_api or 21, chosen.dpi)
    dest = os.path.join(dest_dir, fname)
    rel_path = os.path.join(app.subdir, fname)

    if chosen.kind == "BUNDLE":
        tmp = os.path.join(CACHE, app.package + ".apkm")
        sess.download(file_url, referer, tmp)
        mode = bundle.merge_apkm(tmp, dest, CACHE, mode=args.merge)
        os.remove(tmp)
        status = "MERGED (%s) -> %s" % (mode, app.subdir)
    else:
        sess.download(file_url, referer, dest)
        status = "DOWNLOADED %s -> %s" % (app.version, app.subdir)

    # Safety net: the resolved slug must actually deliver the configured package.
    # A wrong slug (e.g. resolving to the Play Store) otherwise silently produces a
    # mislabeled APK. Reject and delete any package mismatch.
    actual_pkg = _apk_package(dest)
    if actual_pkg and actual_pkg != app.package:
        os.remove(dest)
        return summary.Row(app.package,
                           "FAILED (package mismatch: got %s from slug %s)"
                           % (actual_pkg, app.slug))

    if local_path and os.path.abspath(local_path) != os.path.abspath(dest):
        os.remove(local_path)
        status = status + " (replaced %s)" % os.path.basename(local_path)

    row = summary.Row(app.package, status)
    _annotate_gms(row, dest)
    _git_stage(rel_path)
    return row


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Fetch arm64-v8a prebuilt APKs from apkmirror.com.")
    ap.add_argument("packages", nargs="*",
                    help="only fetch these package ids (default: all)")
    ap.add_argument("--force", action="store_true",
                    help="re-download even if the local file matches the pin")
    ap.add_argument("--merge", choices=["full", "native"], default="full",
                    help="bundle merge scope (default: full)")
    ap.add_argument("--no-merge", action="store_true",
                    help="skip bundle-only apps instead of merging")
    ap.add_argument("--list", action="store_true",
                    help="show config + local-vs-pinned status; download nothing")
    ap.add_argument("--dry-run", action="store_true",
                    help="resolve actions but download nothing")
    args = ap.parse_args(argv)

    apps = config.load(CONFIG, only=args.packages or None)
    rows = []
    sess = None

    for app in apps:
        local_ver, local_path = _local_version(app)
        if args.list:
            state = ("current" if local_ver == app.version
                     else "missing" if local_ver is None
                     else "outdated(%s)" % local_ver)
            rows.append(summary.Row(app.package,
                                    "PINNED %s [%s/%s]"
                                    % (app.version, app.subdir, state)))
            continue
        if local_ver == app.version and not args.force:
            row = summary.Row(app.package, "SKIPPED (current)")
            _annotate_gms(row, local_path)
            rows.append(row)
            continue
        if args.dry_run:
            rows.append(summary.Row(app.package,
                                    "WOULD FETCH %s" % app.version))
            continue
        if sess is None:
            sess = apkmirror.Session()
        try:
            rows.append(_fetch_one(sess, app, local_path, args))
        except Exception as e:  # noqa: BLE001
            rows.append(summary.Row(app.package, "FAILED (%s)" % e))

    print(summary.render(rows))
    return 1 if summary.any_failed(rows) else 0


if __name__ == "__main__":
    sys.exit(main())
