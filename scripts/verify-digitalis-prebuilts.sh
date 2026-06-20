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
# Verify a generated Digitalis binary distribution: every canonical artifact is
# present with the right ELF arch, the translator exports the native-bridge
# entrypoint, and the recorded checksums still match. No absolute paths: the repo
# root is found with git and the canonical list is parsed from berberis_config.mk.
#
# Usage: verify-digitalis-prebuilts.sh [PREBUILT_DIR]   (default: digitalis/dist/digitalis-prebuilts)

set -euo pipefail

# Find the AOSP tree root. Prefer ANDROID_BUILD_TOP — the env var AOSP's `lunch`
# (build/envsetup.sh) exports — so when the developer has already set up their build
# environment we honor exactly that tree. Otherwise bootstrap by walking up to the
# canonical AOSP TOPFILE (build/make/core/envsetup.mk, the same marker envsetup's
# gettop uses). git rev-parse is unsuitable: the AOSP root is not a git repo and
# digitalis/ is its own repo project.
find_aosp_root() {
  if [ -n "${ANDROID_BUILD_TOP:-}" ] && [ -f "${ANDROID_BUILD_TOP}/build/make/core/envsetup.mk" ]; then
    ( cd -- "$ANDROID_BUILD_TOP" && pwd ); return 0
  fi
  local d; d="$(cd -- "$1" && pwd)"
  while [ "$d" != "/" ]; do
    [ -f "$d/build/make/core/envsetup.mk" ] && { echo "$d"; return 0; }
    d="$(dirname -- "$d")"
  done
  return 1
}
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(find_aosp_root "$SELF_DIR")" || { echo "cannot locate AOSP root (set ANDROID_BUILD_TOP, or run from inside a tree with build/make/core/envsetup.mk)" >&2; exit 1; }
cd "$REPO"

CONFIG_MK="frameworks/libs/binary_translation/berberis_config.mk"
PREBUILT_DIR="${1:-digitalis/dist/digitalis-prebuilts}"
READELF="prebuilts/clang/host/linux-x86/llvm-binutils-stable/llvm-readelf"
[ -x "$READELF" ] || READELF="readelf"

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

[ -d "$PREBUILT_DIR" ] || { echo "no such dir: $PREBUILT_DIR" >&2; exit 1; }

list_artifacts() {
  sed -n '/^BERBERIS_DISTRIBUTION_ARTIFACTS_ARM64 :=/,/^# endregion/p' "$CONFIG_MK" \
    | grep -oE 'system/[^ \\]+'
}

elf_machine() { "$READELF" -h "$1" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p'; }

# ---- presence + arch + non-empty -------------------------------------------
total=0
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  total=$((total + 1))
  f="$PREBUILT_DIR/$rel"
  if [ ! -f "$f" ]; then err "missing artifact: $rel"; continue; fi
  if [ ! -s "$f" ]; then err "zero-size artifact: $rel"; continue; fi

  # Configs/text under etc/ are not ELF; skip the arch check for them.
  case "$rel" in
    system/etc/*) continue ;;
  esac

  machine="$(elf_machine "$f")"
  case "$rel" in
    system/lib64/arm64/*|system/bin/arm64/*)
      # ARM64 guest libraries / executables.
      case "$machine" in
        *AArch64*) ;;
        *) err "expected AArch64, got '$machine' for $rel" ;;
      esac ;;
    system/lib64/*|system/bin/*)
      # Host-side translator / proxy libs / program runners.
      case "$machine" in
        *X86-64*|*x86-64*|*Advanced\ Micro\ Devices\ X86-64*) ;;
        *) err "expected x86-64, got '$machine' for $rel" ;;
      esac ;;
  esac
done < <(list_artifacts)
echo ">>> checked $total artifacts for presence/arch"

# ---- native-bridge entrypoint ----------------------------------------------
# Capture the dynamic symbols into a variable rather than piping into `grep -q`:
# `grep -q` exits on first match and SIGPIPEs readelf, which `set -o pipefail`
# would then report as a (false) failure.
NB="$PREBUILT_DIR/system/lib64/libberberis_arm64.so"
if [ -f "$NB" ]; then
  nb_syms="$("$READELF" --dyn-syms "$NB" 2>/dev/null || true)"
  case "$nb_syms" in
    *NativeBridgeItf*) echo ">>> libberberis_arm64.so exports NativeBridgeItf" ;;
    *) err "libberberis_arm64.so does not export NativeBridgeItf" ;;
  esac
else
  err "translator libberberis_arm64.so absent"
fi

# ---- consumer makefile present + parseable ---------------------------------
MK="$PREBUILT_DIR/digitalis-prebuilts.mk"
if [ -f "$MK" ]; then
  grep -q 'ro.dalvik.vm.native.bridge=libberberis_arm64.so' "$MK" \
    || err "digitalis-prebuilts.mk missing native-bridge property"
  grep -q 'PRODUCT_COPY_FILES += .*libberberis_arm64.so' "$MK" \
    || err "digitalis-prebuilts.mk missing translator copy rule"
  echo ">>> digitalis-prebuilts.mk present and well-formed"
else
  err "digitalis-prebuilts.mk absent"
fi

# ---- checksums --------------------------------------------------------------
if [ -f "$PREBUILT_DIR/SHA256SUMS" ]; then
  if ( cd "$PREBUILT_DIR" && sha256sum -c --quiet SHA256SUMS ); then
    echo ">>> SHA256SUMS verified"
  else
    err "SHA256SUMS mismatch"
  fi
else
  err "SHA256SUMS absent"
fi

# ---- builder identity -------------------------------------------------------
if [ -f "$PREBUILT_DIR/MANIFEST.txt" ]; then
  echo ">>> builder identity:"
  grep -E 'build-username|build-date|binary_translation-sha|artifact-count' "$PREBUILT_DIR/MANIFEST.txt" | sed 's/^/      /'
else
  err "MANIFEST.txt absent"
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: Digitalis binary distribution verified ($total artifacts)."
else
  echo "VERIFY FAILED." >&2
  exit 1
fi
