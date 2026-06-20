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
# Convenience shortcut: select the Digitalis lunch target.
#
# SOURCE this (it must run in your current shell so the lunch environment
# persists), from anywhere inside the tree:
#
#     source digitalis/scripts/lunch-digitalis.sh
#
# If build/envsetup.sh has not been sourced yet, this sources it first (locating
# the tree root the same way the other digitalis/scripts do: prefer
# ANDROID_BUILD_TOP, else walk up to the canonical AOSP marker
# build/make/core/envsetup.mk).

# Must be sourced, not executed — `lunch` sets environment in the current shell.
if ! (return 0 2>/dev/null); then
  echo "lunch-digitalis.sh must be SOURCED, not executed:" >&2
  echo "    source digitalis/scripts/lunch-digitalis.sh" >&2
  exit 1
fi

DIGITALIS_TARGET="sdk_phone64_x86_64_digitalis-trunk_staging-userdebug"

if type lunch >/dev/null 2>&1; then
  # build/envsetup.sh is already sourced; lunch from the current (in-tree) dir.
  lunch "$DIGITALIS_TARGET"
else
  # Locate the tree root, then source envsetup and lunch *from the root* (both
  # need the root as the working directory), restoring the caller's directory.
  if [ -n "${ANDROID_BUILD_TOP:-}" ] && [ -f "${ANDROID_BUILD_TOP}/build/make/core/envsetup.mk" ]; then
    _digitalis_top="$ANDROID_BUILD_TOP"
  else
    _digitalis_top="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    while [ "$_digitalis_top" != "/" ] && [ ! -f "$_digitalis_top/build/make/core/envsetup.mk" ]; do
      _digitalis_top="$(dirname -- "$_digitalis_top")"
    done
  fi
  if [ ! -f "$_digitalis_top/build/make/core/envsetup.mk" ]; then
    echo "lunch-digitalis: cannot locate AOSP root (set ANDROID_BUILD_TOP)" >&2
    unset _digitalis_top
    return 1
  fi
  _digitalis_oldpwd="$PWD"
  cd "$_digitalis_top" || { unset _digitalis_top _digitalis_oldpwd; return 1; }
  # shellcheck disable=SC1091
  source build/envsetup.sh
  lunch "$DIGITALIS_TARGET"
  cd "$_digitalis_oldpwd"
  unset _digitalis_top _digitalis_oldpwd
fi
