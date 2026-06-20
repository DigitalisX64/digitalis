#!/usr/bin/env bash
#
# Copyright (C) 2026 utzcoz
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Build the Digitalis (ARM64->x86_64) translator distribution modules, collect
# the canonical artifact set, and emit a binary-only prebuilt bundle that other
# AOSP products can integrate without building Berberis from source.
#
# Runnable inside the digitalis-build Docker image OR directly on the host (same
# logic). No absolute paths: the repo root is found with git and everything is
# referenced relative to it. The artifact and module lists are PARSED from
# frameworks/libs/binary_translation/berberis_config.mk (single source of truth),
# never hardcoded here.
#
# Usage: build-and-package-prebuilts.sh [--full] [--collect-only]
#                                       [--date YYYY-MM-DD] [--username NAME]
#   --full          run a full `m` (guaranteed image-complete) instead of the
#                   targeted module build.
#   --collect-only  skip the build; just collect from the existing out/.
#   --date DATE     stamp this date into the bundle (default: today).
#   --username NAME build identity stamped into the build/manifest. Default order:
#                   this flag, else $BUILD_USERNAME, else "digitalis-build". The
#                   host login name is never used directly.

# No `nounset`: this script must `source build/envsetup.sh`, which is not -u-clean
# (it references unbound vars like TOP). Optional vars below use ${VAR:-default}.
set -eo pipefail

FULL=0
COLLECT_ONLY=0
BUILD_DATE=""
USERNAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --full) FULL=1 ;;
    --collect-only) COLLECT_ONLY=1 ;;
    --date) BUILD_DATE="${2:-}"; shift ;;
    --username) USERNAME="${2:-}"; shift ;;
    -h|--help) sed -n '17,33p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
BUILD_DATE="${BUILD_DATE:-$(date +%Y-%m-%d)}"
# Build identity: parameter-driven, never the raw host login name.
USERNAME="${USERNAME:-${BUILD_USERNAME:-digitalis-build}}"
export BUILD_USERNAME="$USERNAME"

# Find the AOSP tree root by walking up to the dir holding build/envsetup.sh.
# (git rev-parse is wrong here: digitalis/ is its own repo project and the AOSP
# root itself is not a git repo.)
find_aosp_root() {
  local d; d="$(cd -- "$1" && pwd)"
  while [ "$d" != "/" ]; do
    [ -f "$d/build/envsetup.sh" ] && { echo "$d"; return 0; }
    d="$(dirname -- "$d")"
  done
  return 1
}
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(find_aosp_root "$SELF_DIR")" || { echo "cannot locate AOSP root (no build/envsetup.sh above $SELF_DIR)" >&2; exit 1; }
cd "$REPO"

CONFIG_MK="frameworks/libs/binary_translation/berberis_config.mk"
DIST_ROOT="digitalis/dist"
PREBUILT_DIR="$DIST_ROOT/digitalis-prebuilts"

# ---- canonical lists, parsed from berberis_config.mk -----------------------
list_artifacts() {
  sed -n '/^BERBERIS_DISTRIBUTION_ARTIFACTS_ARM64 :=/,/^# endregion/p' "$CONFIG_MK" \
    | grep -oE 'system/[^ \\]+'
}
list_host_modules() {
  sed -n '/^BERBERIS_PRODUCT_PACKAGES_ARM64_TO_X86_64 :=/,/^$/p' "$CONFIG_MK" \
    | grep -oE 'libberberis_[A-Za-z0-9_]+|berberis_program_runner_[a-z0-9_]+|berberis_prebuilt_arm64' \
    | sort -u
}

# ---- build environment (env-var lunch bypass) ------------------------------
export TARGET_PRODUCT="${TARGET_PRODUCT:-sdk_phone64_x86_64_digitalis}"
export TARGET_RELEASE="${TARGET_RELEASE:-trunk_staging}"
export TARGET_BUILD_VARIANT="${TARGET_BUILD_VARIANT:-userdebug}"
echo ">>> repo=$REPO product=$TARGET_PRODUCT release=$TARGET_RELEASE variant=$TARGET_BUILD_VARIANT"
echo ">>> BUILD_USERNAME=$USERNAME"
# shellcheck disable=SC1091
source build/envsetup.sh >/dev/null

# ---- build the distribution modules ----------------------------------------
if [ "$COLLECT_ONLY" -eq 0 ]; then
  if [ "$FULL" -eq 1 ]; then
    echo ">>> full build: m"
    m
  else
    mapfile -t MODS < <(list_host_modules)
    echo ">>> building ${#MODS[@]} distribution modules incrementally: ${MODS[*]}"
    m "${MODS[@]}"
  fi
fi

PRODUCT_OUT="$(get_build_var PRODUCT_OUT 2>/dev/null || echo out/target/product/emu64xa)"
echo ">>> PRODUCT_OUT=$PRODUCT_OUT"

# ---- collect artifacts ------------------------------------------------------
rm -rf "$PREBUILT_DIR"
mkdir -p "$PREBUILT_DIR"
count=0
missing=0
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  src="$PRODUCT_OUT/$rel"
  if [ ! -f "$src" ]; then
    echo "MISSING: $src" >&2
    missing=1
    continue
  fi
  dst="$PREBUILT_DIR/$rel"
  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst"
  count=$((count + 1))
done < <(list_artifacts)

if [ "$missing" -ne 0 ]; then
  echo "ERROR: artifacts missing from $PRODUCT_OUT — re-run with --full to assemble them." >&2
  exit 1
fi
echo ">>> collected $count artifacts into $PREBUILT_DIR"

# ---- generate consumer integration makefile --------------------------------
MK="$PREBUILT_DIR/digitalis-prebuilts.mk"
{
  echo "# Auto-generated by digitalis/scripts/build-and-package-prebuilts.sh — do not edit."
  echo "#"
  echo "# Binary-only Digitalis (ARM64->x86_64) translator for an x86_64 host product."
  echo "# Drop this tree into your tree (e.g. vendor/digitalis/prebuilts/) and add to your"
  echo "# x86_64 product .mk:"
  echo "#"
  echo "#   \$(call inherit-product, vendor/digitalis/prebuilts/digitalis-prebuilts.mk)"
  echo "#"
  echo "# Provides the translator + proxy libs + ARM64 guest libs + configs only; the"
  echo "# consuming product supplies the rest of the x86_64 system (and, for Vulkan, the"
  echo "# GFXStream/ANGLE GPU stack)."
  echo ""
  echo "LOCAL_PATH := \$(call my-dir)"
  echo ""
  echo "# Native-bridge enablement (mirrors frameworks/libs/binary_translation/enable_arm64_to_x86_64.mk)."
  echo "PRODUCT_SYSTEM_PROPERTIES += \\"
  echo "    ro.dalvik.vm.native.bridge=libberberis_arm64.so \\"
  echo "    ro.dalvik.vm.isa.arm64=x86_64 \\"
  echo "    ro.enable.native.bridge.exec=1"
  echo ""
  echo "# Copy every prebuilt artifact into the system image at its canonical path."
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    echo "PRODUCT_COPY_FILES += \$(LOCAL_PATH)/$rel:$rel"
  done < <(list_artifacts)
  echo ""
  echo "# Allow these artifacts to live on /system."
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    echo "PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += $rel"
  done < <(list_artifacts)
} > "$MK"
echo ">>> wrote $MK"

# ---- per-artifact checksums -------------------------------------------------
( cd "$PREBUILT_DIR" && find system -type f -print0 | sort -z \
    | xargs -0 sha256sum > SHA256SUMS )

# ---- manifest (builder identity, versions; no absolute path) ---------------
# Per-project revisions (the AOSP root is not a single git repo; each project is).
bt_sha="$(git -C frameworks/libs/binary_translation rev-parse --short HEAD 2>/dev/null || echo unknown)"
digitalis_sha="$(git -C digitalis rev-parse --short HEAD 2>/dev/null || echo unknown)"
MANIFEST="$PREBUILT_DIR/MANIFEST.txt"
{
  echo "Digitalis binary distribution (ARM64 -> x86_64 translator)"
  echo "build-date:        $BUILD_DATE"
  echo "build-username:    $USERNAME"
  echo "target-product:    $TARGET_PRODUCT"
  echo "binary_translation-sha: $bt_sha"
  echo "digitalis-sha:     $digitalis_sha"
  echo "artifact-count:    $count"
} > "$MANIFEST"
echo ">>> wrote $MANIFEST"

# ---- copy the integration README into the bundle ---------------------------
cp -f digitalis/docker/README.md "$PREBUILT_DIR/README.md" 2>/dev/null || true

# ---- package ----------------------------------------------------------------
TARBALL="$DIST_ROOT/digitalis-prebuilts-${BUILD_DATE}-${bt_sha}.tar.gz"
tar -C "$DIST_ROOT" -czf "$TARBALL" "digitalis-prebuilts"
( cd "$DIST_ROOT" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )
echo ">>> packaged $TARBALL"
echo ">>> done. verify with: digitalis/scripts/verify-digitalis-prebuilts.sh"
