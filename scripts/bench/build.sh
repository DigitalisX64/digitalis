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
# Cross-compile bench.c to an arm64-v8a static-ish binary with the Android
# NDK, so it runs under the Digitalis translator on the x86_64 emulator.
# Output: digitalis/scripts/bench/bench-arm64

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# Pick the newest installed NDK unless ANDROID_NDK_HOME is set.
ndk="${ANDROID_NDK_HOME:-}"
if [[ -z "$ndk" ]]; then
  sdk="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
  ndk="$(ls -d "$sdk"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
fi
if [[ -z "$ndk" || ! -d "$ndk" ]]; then
  echo "ERROR: no NDK found; set ANDROID_NDK_HOME" >&2
  exit 1
fi

api="${API_LEVEL:-29}"
cc="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${api}-clang"
if [[ ! -x "$cc" ]]; then
  echo "ERROR: $cc not found" >&2
  exit 1
fi

out="$here/bench-arm64"
echo "NDK: $ndk (API $api)"
"$cc" -O2 -Wall -Wextra -o "$out" "$here/bench.c"
echo "built: $out"
file "$out" 2>/dev/null || true
