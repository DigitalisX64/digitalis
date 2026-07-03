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
# Exhaustive-mode driver for the JIT-vs-interpreter differential fuzzer
# (frameworks/libs/binary_translation/lite_translator/arm64_to_x86_64/
#  differential_fuzz_tests.cc, gtest suite Arm64DifferentialFuzz).
#
# The host suite runs the fuzzer in CI mode: fixed seeds, bounded iteration
# counts, ~seconds. This driver flips the BERBERIS_DIFFERENTIAL_FUZZ_EXHAUSTIVE
# env knob, which multiplies every class's iteration count by 25x, and loops the
# suite so a much wider slice of the seeded corpus is explored. Use it before a
# release, after a translator change to a shared decode/interpret/JIT path, or to
# hunt a suspected reg-mapping/lane/aliasing miscompile. The four historical bugs
# this tool class found (CCMN reg-map clobber, vector SCVTF lane-drop, rd==rn
# in-place convert clobber, SDIV divisor-0/-1 stack imbalance) are pinned by the
# Arm64DifferentialFuzz.HistoricalBugEncodingsInCorpus acceptance test.
#
# Usage:
#   digitalis/scripts/differential-fuzz.sh [ROUNDS]
#
# ROUNDS defaults to 1. Each round re-runs the whole Arm64DifferentialFuzz suite
# under the exhaustive knob. Because the PRNG is fixed-seeded, a single round is
# deterministic; running multiple rounds is only useful together with editing the
# seeds (or after widening the generators). Env overrides:
#   TEST_BIN  path to berberis_arm64_host_tests (default: the standard out/ path)
#   FILTER    gtest filter (default: Arm64DifferentialFuzz.*)
#   SCALE     value for BERBERIS_DIFFERENTIAL_FUZZ_EXHAUSTIVE (default: 1 => on)

set -euo pipefail

ROUNDS="${1:-1}"
FILTER="${FILTER:-Arm64DifferentialFuzz.*}"
SCALE="${SCALE:-1}"

# Resolve the AOSP tree root from this script's location
# (<root>/digitalis/scripts/differential-fuzz.sh).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AOSP_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

TEST_BIN="${TEST_BIN:-${AOSP_ROOT}/out/host/linux-x86/nativetest64/berberis_arm64_host_tests/berberis_arm64_host_tests}"

if [[ ! -x "${TEST_BIN}" ]]; then
  echo "ERROR: host test binary not found: ${TEST_BIN}" >&2
  echo "Build it first:" >&2
  echo "  source build/envsetup.sh" >&2
  echo "  lunch sdk_phone64_x86_64-trunk_staging-userdebug" >&2
  echo "  m berberis_arm64_host_tests" >&2
  exit 1
fi

echo "=== differential-fuzz: exhaustive mode (SCALE=${SCALE}) ==="
echo "bin:    ${TEST_BIN}"
echo "filter: ${FILTER}"
echo "rounds: ${ROUNDS}"

fail=0
for ((r = 1; r <= ROUNDS; r++)); do
  echo "--- round ${r}/${ROUNDS} ---"
  if ! BERBERIS_DIFFERENTIAL_FUZZ_EXHAUSTIVE="${SCALE}" \
       "${TEST_BIN}" --gtest_filter="${FILTER}"; then
    fail=1
    echo "round ${r}: FAIL" >&2
  fi
done

if [[ "${fail}" -ne 0 ]]; then
  echo "=== differential-fuzz: FAILURES detected ===" >&2
  exit 1
fi
echo "=== differential-fuzz: all rounds PASS ==="
