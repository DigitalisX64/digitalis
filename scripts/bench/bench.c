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
 * Digitalis lite-translator microbenchmark.
 *
 * Four kernels that isolate distinct translator hot paths:
 *
 *   alu      tight integer ALU loop — baseline JIT throughput, no branches,
 *            no memory traffic.
 *   branch   data-dependent CMP + B.cond in a tight loop — exercises condition
 *            evaluation and branch/loop codegen.  The values are LCG-random so
 *            the host branch predictor cannot hide a slow conditional path.
 *   syscall  raw svc #0 getpid loop — the guest syscall path through the
 *            translator (not the proxy getpid trampoline).
 *   memcpy   bulk memcpy — proxy-libc / mem path throughput.
 *
 * Each kernel prints one machine-readable line:
 *   BENCH <name> iters=<N> ns_total=<T> ns_per_iter=<F>
 * run-bench.sh parses these; never change the prefix without updating it.
 *
 * Kernels are noinline and consume their result through a volatile sink so
 * the optimizer cannot fold the loop away.  Iteration counts come from argv
 * (or built-in defaults) so the bound is never a compile-time constant.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static volatile uint64_t g_sink;

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

__attribute__((noinline)) static uint64_t kernel_alu(uint64_t iters, uint64_t seed) {
  uint64_t a = seed | 1u;
  for (uint64_t i = 0; i < iters; i++) {
    // A dependent ALU chain: each op feeds the next so it cannot be
    // vectorized or reassociated away.
    a = a * 6364136223846793005ull + 1442695040888963407ull;
    a ^= a >> 17;
    a += i;
    a = (a << 7) | (a >> 57);
  }
  return a;
}

__attribute__((noinline)) static uint64_t kernel_branch(const uint32_t* data,
                                                        uint32_t n,
                                                        uint64_t iters) {
  uint64_t acc = 0;
  uint32_t idx = 0;
  for (uint64_t i = 0; i < iters; i++) {
    uint32_t v = data[idx];
    // Three data-dependent conditionals per iteration: CMP + B.cond x3.
    if (v & 1u) {
      acc += v;
    } else {
      acc -= (v >> 1);
    }
    if (v > 0x80000000u) {
      acc ^= v;
    }
    acc += (v < 0x40000000u) ? 3u : 7u;
    idx++;
    if (idx == n) idx = 0;
  }
  return acc;
}

// Raw arm64 getpid (svc #0, __NR_getpid = 172).  We deliberately bypass the
// libc/proxy getpid wrapper: the proxy libc intercepts getpid() as a direct
// host trampoline (~3 ns), which never exercises the guest SVC path.  The raw
// svc forces the translator's syscall-in-JIT path — the one real
// binder/ioctl/futex traffic takes.
__attribute__((noinline)) static uint64_t kernel_syscall(uint64_t iters) {
  uint64_t last = 0;
  for (uint64_t i = 0; i < iters; i++) {
    register long x8 __asm__("x8") = 172;  // __NR_getpid
    register long x0 __asm__("x0");
    __asm__ __volatile__("svc #0" : "=r"(x0) : "r"(x8) : "memory");
    last = (uint64_t)x0;
  }
  return last;
}

__attribute__((noinline)) static uint64_t kernel_memcpy(uint8_t* dst,
                                                       const uint8_t* src,
                                                       size_t bytes,
                                                       uint64_t iters) {
  uint64_t acc = 0;
  for (uint64_t i = 0; i < iters; i++) {
    memcpy(dst, src, bytes);
    acc += dst[(i * 131u) % bytes];
    dst[0] = (uint8_t)(acc + i);  // defeat dead-store elimination
  }
  return acc;
}

static void report(const char* name, uint64_t iters, uint64_t ns_total) {
  double per = iters ? (double)ns_total / (double)iters : 0.0;
  printf("BENCH %-8s iters=%-12llu ns_total=%-14llu ns_per_iter=%.3f\n",
         name, (unsigned long long)iters, (unsigned long long)ns_total, per);
  fflush(stdout);
}

int main(int argc, char** argv) {
  // Defaults sized for ~0.1-1s per kernel under translation; override per
  // kernel via argv to keep wall time reasonable on slow hosts.
  uint64_t alu_iters = (argc > 1) ? strtoull(argv[1], NULL, 0) : 50000000ull;
  uint64_t branch_iters = (argc > 2) ? strtoull(argv[2], NULL, 0) : 50000000ull;
  uint64_t syscall_iters = (argc > 3) ? strtoull(argv[3], NULL, 0) : 2000000ull;
  uint64_t memcpy_iters = (argc > 4) ? strtoull(argv[4], NULL, 0) : 200000ull;

  // Branch kernel data: LCG-random so the conditionals are unpredictable.
  enum { kN = 4096 };
  static uint32_t data[kN];
  uint64_t s = 0x9e3779b97f4a7c15ull;
  for (int i = 0; i < kN; i++) {
    s = s * 6364136223846793005ull + 1442695040888963407ull;
    data[i] = (uint32_t)(s >> 32);
  }

  // memcpy kernel buffers.
  enum { kBuf = 64 * 1024 };
  static uint8_t src[kBuf], dst[kBuf];
  for (int i = 0; i < kBuf; i++) src[i] = (uint8_t)(i * 7 + 1);

  uint64_t t0, t1;

  // Warm up the translator (force each region to JIT before timing).
  g_sink ^= kernel_alu(100000, 1);
  g_sink ^= kernel_branch(data, kN, 100000);
  g_sink ^= kernel_syscall(1000);
  g_sink ^= kernel_memcpy(dst, src, kBuf, 100);

  t0 = now_ns();
  g_sink ^= kernel_alu(alu_iters, t0 | 1u);
  t1 = now_ns();
  report("alu", alu_iters, t1 - t0);

  t0 = now_ns();
  g_sink ^= kernel_branch(data, kN, branch_iters);
  t1 = now_ns();
  report("branch", branch_iters, t1 - t0);

  t0 = now_ns();
  g_sink ^= kernel_syscall(syscall_iters);
  t1 = now_ns();
  report("syscall", syscall_iters, t1 - t0);

  t0 = now_ns();
  g_sink ^= kernel_memcpy(dst, src, kBuf, memcpy_iters);
  t1 = now_ns();
  report("memcpy", memcpy_iters, t1 - t0);

  // Consume the sink so nothing is dead.
  fprintf(stderr, "sink=%llu\n", (unsigned long long)g_sink);
  return 0;
}
