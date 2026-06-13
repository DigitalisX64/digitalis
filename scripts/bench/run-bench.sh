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
# Push bench-arm64 to the booted Digitalis emulator, run it under the
# translator, and print the per-kernel ns/iter.  Run it once before a perf
# change and once after; the median ns_per_iter per kernel is the before/after
# number to cite for any perf claim.
#
# Usage:
#   run-bench.sh [--reps N] [--label TEXT] [-- ALU BRANCH SYSCALL MEMCPY]
#     --reps N   repeat the whole run N times (default 5); the median per
#                kernel is reported (least noisy single number).
#     --label    free-text tag echoed into the output header.
#     trailing args after `--` are passed verbatim as the four iteration
#     counts to bench-arm64 (alu branch syscall memcpy).

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/bench-arm64"
dev=/data/local/tmp/digitalis-bench-arm64

reps=5
label=""
iter_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reps) reps="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --) shift; iter_args=("$@"); break ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -x "$bin" ]]; then
  echo "bench-arm64 not built; running build.sh ..." >&2
  "$here/build.sh"
fi

if ! adb get-state >/dev/null 2>&1; then
  echo "ERROR: no adb device" >&2
  exit 1
fi

adb push "$bin" "$dev" >/dev/null
adb shell chmod 755 "$dev"

echo "=== Digitalis bench ${label:+($label) }reps=$reps ==="
# Collect ns_per_iter per kernel across reps.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
for ((r = 1; r <= reps; r++)); do
  adb shell "$dev" "${iter_args[@]}" 2>/dev/null >>"$tmp"
done

# Median ns_per_iter per kernel name, computed without external deps.
for k in alu branch syscall memcpy; do
  vals=$(awk -v k="$k" '$1=="BENCH" && $2==k {
           for (i=1;i<=NF;i++){ if ($i ~ /^ns_per_iter=/){ sub(/ns_per_iter=/,"",$i); print $i } }
         }' "$tmp" | sort -n)
  n=$(printf '%s\n' "$vals" | grep -c . || true)
  if [[ "$n" -eq 0 ]]; then
    printf '  %-8s no samples\n' "$k"
    continue
  fi
  mid=$(( (n + 1) / 2 ))
  med=$(printf '%s\n' "$vals" | sed -n "${mid}p")
  printf '  %-8s median ns/iter = %s   (n=%s)\n' "$k" "$med" "$n"
done
