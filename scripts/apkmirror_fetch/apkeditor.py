# Copyright (C) 2026 utzcoz
# SPDX-License-Identifier: Apache-2.0
"""Thin wrapper around REAndroid's APKEditor for correct split-bundle merges.

The pure-Python `arsc.merge` in `arsc.py` only handles the classic (non-sparse,
non-offset16, non-compact) `ResTable_type` encoding and a single base package, and
it ignores feature-module splits (`split_<feature>.apk`) entirely. Real apkmirror
bundles routinely violate those assumptions, so the in-process merge throws and the
caller silently degrades to a native-only merge that keeps ONLY base.apk's resource
table — dropping every density/feature split's resource entries. The visible symptom
is a `Resources$NotFoundException` at runtime for an id that lives in a dropped split.

APKEditor's `m` (merge) command does a real split-resource-table merge (offset
remap across sparse/offset16/compact entries, package fusion, feature-module
classesN.dex fusion), producing one universal APK with a complete table. We vendor a
pinned release jar into the cache the same way the rest of this tooling vendors its
inputs (download-on-demand from the pinned GitHub release URL), then re-sign the
result with the project debug key so install behaves like every other prebuilt APK.
"""
import os
import shutil
import subprocess

# Pin a specific APKEditor release for reproducibility. Bump both fields together.
VERSION = "1.4.9"
JAR_NAME = "APKEditor-%s.jar" % VERSION
JAR_URL = ("https://github.com/REAndroid/APKEditor/releases/download/"
           "V%s/%s" % (VERSION, JAR_NAME))
# sha256 of the pinned jar; verified on download so a tampered/truncated fetch fails
# loudly instead of producing a broken merge.
JAR_SHA256 = "a9cd40df818845456be6d696de6110c89edf4b0a0580cb83438ed6b25a366e67"


class ApkEditorUnavailable(RuntimeError):
    """Raised when neither java nor the APKEditor jar can be made available."""


def _java_bin():
    """Locate a Java runtime: $JAVA_HOME/bin/java, then PATH."""
    jh = os.environ.get("JAVA_HOME")
    if jh:
        cand = os.path.join(jh, "bin", "java")
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    found = shutil.which("java")
    if found:
        return found
    raise ApkEditorUnavailable(
        "java not found; install a JDK or set JAVA_HOME (APKEditor needs Java 8+)")


def _sha256(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_jar(cache_dir):
    """Return the path to the vendored APKEditor jar, downloading it if absent."""
    tools = os.path.join(cache_dir, "tools")
    os.makedirs(tools, exist_ok=True)
    jar = os.path.join(tools, JAR_NAME)
    if os.path.isfile(jar) and _sha256(jar) == JAR_SHA256:
        return jar
    import requests
    with requests.get(JAR_URL, stream=True, timeout=300) as r:
        r.raise_for_status()
        tmp = jar + ".part"
        with open(tmp, "wb") as f:
            for chunk in r.iter_content(1 << 16):
                f.write(chunk)
    got = _sha256(tmp)
    if got != JAR_SHA256:
        os.remove(tmp)
        raise ApkEditorUnavailable(
            "APKEditor jar checksum mismatch: expected %s got %s"
            % (JAR_SHA256, got))
    os.replace(tmp, jar)
    return jar


def merge(apkm_path, out_apk, cache_dir):
    """Merge a split bundle (.apkm/.apks/.xapk) into one universal APK.

    Returns the path to the merged (APKEditor-signed) APK. The caller is expected
    to post-process (strip foreign-ABI libs) and re-sign with the project key.
    """
    java = _java_bin()
    jar = ensure_jar(cache_dir)
    if os.path.exists(out_apk):
        os.remove(out_apk)
    # -f: overwrite output if present. APKEditor auto-detects the bundle format.
    cmd = [java, "-jar", jar, "m", "-i", apkm_path, "-o", out_apk, "-f"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0 or not os.path.exists(out_apk):
        raise ApkEditorUnavailable(
            "APKEditor merge failed (rc=%d):\n%s\n%s"
            % (proc.returncode, proc.stdout[-2000:], proc.stderr[-2000:]))
    return out_apk
