/*
 * Copyright (C) 2026 utzcoz
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * Standalone bcrypt benchmark for cross-configuration baselines.
 *
 * Runs the exact workload of the hello-bcrypt in-app benchmark — a fixed
 * password hashed against a fixed salt at a given cost — as a static binary,
 * so the same executable can be timed as native x86_64 inside the emulator,
 * as ARM64 under Digitalis (binfmt_misc), or under any other emulator. The
 * numbers are then directly comparable across configurations AND against the
 * in-app harness (same sources, same flags, same salt and password).
 *
 * Output is one line per case, machine-readable:
 *   BENCH bcrypt-cost8 iters=30 median_ns=... min_ns=... ns=[...]
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "bcrypt.h"

static int cmp_u64(const void* a, const void* b) {
  uint64_t x = *(const uint64_t*)a, y = *(const uint64_t*)b;
  return x < y ? -1 : x > y;
}

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static int run_case(int cost, int warmup, int iters) {
  char salt[BCRYPT_HASHSIZE];
  char hash[BCRYPT_HASHSIZE];
  /* The in-app benchmark's exact salt and password: no RNG in the path. */
  snprintf(salt, sizeof(salt), "$2b$%02d$abcdefghijklmnopqrstuu", cost);

  for (int i = 0; i < warmup; i++) {
    if (bcrypt_hashpw("digitalis-benchmark", salt, hash) != 0) return 1;
  }

  uint64_t ns[64];
  if (iters > 64) iters = 64;
  for (int i = 0; i < iters; i++) {
    uint64_t start = now_ns();
    if (bcrypt_hashpw("digitalis-benchmark", salt, hash) != 0) return 1;
    ns[i] = now_ns() - start;
  }

  uint64_t sorted[64];
  memcpy(sorted, ns, sizeof(uint64_t) * iters);
  qsort(sorted, iters, sizeof(uint64_t), cmp_u64);

  printf("BENCH bcrypt-cost%d iters=%d median_ns=%llu min_ns=%llu ns=[", cost,
         iters, (unsigned long long)sorted[iters / 2],
         (unsigned long long)sorted[0]);
  for (int i = 0; i < iters; i++) {
    printf("%s%llu", i ? "," : "", (unsigned long long)ns[i]);
  }
  printf("]\n");
  return hash[0] == '\0' ? 1 : 0;
}

int main(void) {
  /* Line-buffer stdout so per-case lines survive a killed run under adb. */
  setvbuf(stdout, NULL, _IOLBF, 0);
  if (run_case(8, 5, 30) || run_case(10, 3, 15)) {
    fprintf(stderr, "bcrypt failed\n");
    return 1;
  }
  return 0;
}
