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
 * peek — read guest ARM64 register state from a spinning Berberis thread.
 *
 * Berberis's JIT calling convention keeps the host ThreadState pointer in
 * %rbp. peek does PTRACE_ATTACH on the target TID, reads %rbp via
 * PTRACE_GETREGSET, then reads the guest x[] register array (and a few
 * derived fields) from /proc/<tid>/mem at known ThreadState offsets.
 *
 * The CPUState (= ThreadState.cpu) ARM64 layout is x[0..30] at offset 0..240,
 * then flags/sp/v[]/insn_addr — insn_addr lives at offset 784. Note that
 * insn_addr in CPUState is updated only at region exits, so during a hot
 * JIT spin it can be stale.
 *
 * Useful primarily for diagnosing wedges where the guest is busy-spinning in
 * JIT-cached code and dispatch instrumentation never fires (no region exit
 * → no dispatch hook).
 *
 * Build (NDK r26+):
 *   x86_64-linux-android30-clang -O2 -static -o peek peek.c
 *
 * Run:
 *   adb push peek /data/local/tmp/peek && adb shell chmod +x /data/local/tmp/peek
 *   adb shell /data/local/tmp/peek <busy-TID>
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <sys/user.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>

struct regs_x86_64 {
    unsigned long r15, r14, r13, r12, rbp, rbx, r11, r10, r9, r8;
    unsigned long rax, rcx, rdx, rsi, rdi, orig_rax, rip, cs, eflags;
    unsigned long rsp, ss, fs_base, gs_base, ds, es, fs, gs;
};

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: peek <tid>\n"); return 1; }
    pid_t tid = atoi(argv[1]);

    if (ptrace(PTRACE_ATTACH, tid, 0, 0) < 0) { perror("PTRACE_ATTACH"); return 1; }
    int st;
    if (waitpid(tid, &st, __WALL) < 0) { perror("waitpid"); return 1; }

    struct regs_x86_64 r;
    struct iovec iov = { &r, sizeof(r) };
    if (ptrace(PTRACE_GETREGSET, tid, 1, &iov) < 0) {
        perror("GETREGSET");
        ptrace(PTRACE_DETACH, tid, 0, 0);
        return 1;
    }
    printf("rip=0x%lx rbp=0x%lx rsp=0x%lx rax=0x%lx rbx=0x%lx\n",
           r.rip, r.rbp, r.rsp, r.rax, r.rbx);

    unsigned long ts_addr = r.rbp;
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/mem", tid);
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror("open mem"); ptrace(PTRACE_DETACH, tid, 0, 0); return 1; }
    unsigned long values[7];
    off_t offsets[7] = { 152, 192, 200, 208, 784, 0, 16 };
    const char* names[7] = { "x19", "x24", "x25", "x26", "insn_addr", "x0", "x2" };
    for (int i = 0; i < 7; i++) {
        if (pread(fd, &values[i], 8, ts_addr + offsets[i]) != 8) {
            fprintf(stderr, "read %s @ TS+%ld failed: %s\n",
                    names[i], (long)offsets[i], strerror(errno));
            values[i] = 0xDEADBEEFDEADBEEFul;
        }
    }
    close(fd);
    ptrace(PTRACE_DETACH, tid, 0, 0);

    printf("ThreadState* = 0x%lx (=rbp)\n", ts_addr);
    for (int i = 0; i < 7; i++) {
        printf("  %s @ TS+%ld = 0x%lx\n", names[i], (long)offsets[i], values[i]);
    }

    unsigned long x25 = values[2];
    unsigned long x19 = values[0];
    unsigned long x26 = values[3];
    if (x25) {
        unsigned int n = (unsigned int)x26 + 1;
        if (n > 4096) n = 4096;
        unsigned int* buckets = (unsigned int*)calloc(n, sizeof(unsigned int));
        char mem_path[64];
        snprintf(mem_path, sizeof(mem_path), "/proc/%d/mem", tid);
        int fd2 = open(mem_path, O_RDONLY);
        if (fd2 >= 0) {
            pread(fd2, buckets, n * sizeof(unsigned int), x25);
            close(fd2);
        }
        unsigned int empty = 0, match = 0;
        unsigned int counts[4096] = {0};
        for (unsigned int i = 0; i < n; i++) {
            unsigned int b = buckets[i];
            if ((b & 0xFFFFFu) == 0) ++empty;
            unsigned int h = b >> 20;
            if (h == (unsigned int)x19) ++match;
            if (h < 4096) counts[h]++;
        }
        unsigned int distinct = 0;
        for (int i = 0; i < 4096; i++) if (counts[i]) distinct++;
        printf("bucket_count=%u empty=%u hash-match-with-x19(0x%lx)=%u distinct_hashes=%u\n",
               n, empty, x19, match, distinct);
        printf("hash counts (top 10):\n");
        for (int rank = 0; rank < 10; rank++) {
            int best = -1;
            unsigned int bestc = 0;
            for (int h = 0; h < 4096; h++) {
                if (counts[h] > bestc) { bestc = counts[h]; best = h; }
            }
            if (best < 0) break;
            printf("  rank%d hash=0x%03x count=%u%s\n", rank+1, best, bestc,
                   best == (int)x19 ? "  <== x19" : "");
            counts[best] = 0;
        }
        free(buckets);
    }
    return 0;
}
