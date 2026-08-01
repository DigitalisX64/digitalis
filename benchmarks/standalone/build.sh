#!/usr/bin/env bash
#
# Build the standalone benchmark as STATIC binaries for arm64 and x86_64,
# compiling the very sources the hello-bcrypt sample vendors so results are
# comparable with the in-app harness. Static + bionic means the arm64 binary
# runs under Digitalis via binfmt_misc with no guest sysroot, and the x86_64
# binary runs natively inside the same emulator — same kernel, same libc,
# same compiler and flags, isolating translation as the only variable.
#
#   digitalis/benchmarks/standalone/build.sh
#   -> digitalis/out/bench-bin/bench_bcrypt.{arm64,x86_64}
set -euo pipefail
cd "$(dirname "$0")/../../.."

NDK="${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/27.1.12297006}"
BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
API=30
SRC_DIR=sample/hellodigitalis/hello-bcrypt/src/main/cpp
OUT=digitalis/out/bench-bin
mkdir -p "$OUT"

SOURCES=(
  digitalis/benchmarks/standalone/bench_bcrypt.c
  "$SRC_DIR/bcrypt.c"
  "$SRC_DIR/crypt_blowfish/crypt_blowfish.c"
  "$SRC_DIR/crypt_blowfish/crypt_gensalt.c"
  "$SRC_DIR/crypt_blowfish/wrapper.c"
)
# -O2 to match the sample's release flags: crypt_blowfish emits no SIMD below
# -O2, and an unoptimized baseline would flatter the translator.
FLAGS=(-O2 -static -I "$SRC_DIR" -I "$SRC_DIR/crypt_blowfish")

"$BIN/aarch64-linux-android${API}-clang" "${FLAGS[@]}" "${SOURCES[@]}" \
    -o "$OUT/bench_bcrypt.arm64"
"$BIN/x86_64-linux-android${API}-clang" "${FLAGS[@]}" "${SOURCES[@]}" \
    -o "$OUT/bench_bcrypt.x86_64"

file "$OUT"/bench_bcrypt.* | sed 's/, BuildID.*//'
