#!/usr/bin/env bash
#
# deploy-emulator.sh
#
# Build the Android Emulator host package from an emulator source tree and
# overlay it onto this AOSP tree's in-tree prebuilt emulator.
#
# Why anyone needs this: the emulator shipped under prebuilts/android-emulator/
# is a release binary that lags the emulator's own source. A host-side gfxstream
# fix that has landed upstream is therefore NOT in the prebuilt, and the only
# way to run with it is to build the emulator yourself and overlay the package.
# See digitalis/docs/emulator-gfxstream-deploy.md for the case this was written
# for (a Vulkan pNext struct the older host decoder aborts on).
#
# Why a whole-package overlay instead of copying just libgfxstream_backend.so:
#   * The emulator ships a "fat" libgfxstream_backend.so (rolls in the android-emu
#     host layer). An AOSP tree's own Soong out/host build is the "slim" Cuttlefish
#     flavor and is NOT a drop-in for the goldfish/ranchu emulator.
#   * Emulator releases are not ABI-stable across versions: a newer backend can drop
#     exports that the target's qemu-system-* binaries import (e.g.
#     emuglConfig_current_renderer_supports_snapshot), so a single-.so swap fails at
#     load. The whole interdependent set must move together.
#
# Usage:
#   deploy-emulator.sh --emu-root <emulator-src>               # build + deploy + verify
#   deploy-emulator.sh --emu-root <emulator-src> --no-build    # deploy existing objs/
#   deploy-emulator.sh --restore                               # undo: restore the backup
#
# Options:
#   --emu-root DIR   Emulator source tree (the checkout containing external/qemu).
#                    Required except with --restore.
#   --aosp-root DIR  AOSP/Digitalis tree to deploy into. Defaults to the tree this
#                    script lives in, so it needs passing only when deploying to a
#                    different checkout.
#   --host HOST      Prebuilt host triple under prebuilts/android-emulator/
#                    (default: autodetect, e.g. linux-x86_64 / darwin-aarch64)
#   --no-build       Skip the build; use whatever is already in <emu-root>/external/qemu/objs
#   --restore        Restore the target prebuilt from the backup taken on first deploy
#   -h, --help       Show this help
#
set -euo pipefail

# The host-side fix this script exists to ship. Verified present in the freshly
# built backend before anything is overlaid, so a build from a tree without it
# fails loudly instead of deploying a binary that still aborts.
FIX_SYMBOL="clampMemoryBudgetToGuestHeapSizes"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
usage(){ sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---- args -------------------------------------------------------------------
EMU_ROOT=""
AOSP_ROOT=""
HOST=""
MODE="deploy"        # deploy | nobuild | restore

while [[ $# -gt 0 ]]; do
    case "$1" in
        --emu-root)  EMU_ROOT="${2:?--emu-root needs a value}";   shift 2 ;;
        --aosp-root) AOSP_ROOT="${2:?--aosp-root needs a value}"; shift 2 ;;
        --host)      HOST="${2:?--host needs a value}";           shift 2 ;;
        --no-build)  MODE="nobuild"; shift ;;
        --restore)   MODE="restore"; shift ;;
        -h|--help)   usage 0 ;;
        *)           die "unknown argument: $1 (see --help)" ;;
    esac
done

# The AOSP tree defaults to the one this script is checked out in:
# <aosp-root>/digitalis/scripts/deploy-emulator.sh
if [[ -z "$AOSP_ROOT" ]]; then
    AOSP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
AOSP_ROOT="$(cd "$AOSP_ROOT" 2>/dev/null && pwd)" || die "AOSP root not found"
[[ -d "$AOSP_ROOT/prebuilts/android-emulator" ]] \
    || die "no prebuilts/android-emulator in $AOSP_ROOT — pass --aosp-root"

if [[ "$MODE" != "restore" ]]; then
    [[ -n "$EMU_ROOT" ]] || { echo "Missing --emu-root." >&2; usage 1; }
    EMU_ROOT="$(cd "$EMU_ROOT" 2>/dev/null && pwd)" || die "emulator source not found"
    QEMU_DIR="$EMU_ROOT/external/qemu"
    [[ -d "$QEMU_DIR" ]] || die "not an emulator source tree (no external/qemu): $EMU_ROOT"
fi

# Autodetect the prebuilt host triple if not given.
if [[ -z "$HOST" ]]; then
    case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) die "unsupported OS $(uname -s); pass --host" ;; esac
    case "$(uname -m)" in x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=aarch64 ;; *) die "unsupported arch $(uname -m); pass --host" ;; esac
    HOST="${os}-${arch}"
fi

PREBUILT="$AOSP_ROOT/prebuilts/android-emulator/$HOST"
BACKUP="${PREBUILT}.bak.pre-emu-deploy"

[[ -d "$PREBUILT" ]] || die "no prebuilt emulator at $PREBUILT (wrong --host?)"
[[ -f "$PREBUILT/lib64/libgfxstream_backend.so" ]] || die "$PREBUILT does not look like an emulator prebuilt"

log "Target AOSP root: $AOSP_ROOT"
log "Target prebuilt : $PREBUILT  (host=$HOST)"

# ---- restore mode -----------------------------------------------------------
if [[ "$MODE" == "restore" ]]; then
    [[ -d "$BACKUP" ]] || die "no backup at $BACKUP"
    log "Restoring prebuilt from $BACKUP"
    rsync -a --delete "$BACKUP"/ "$PREBUILT"/
    log "Restored. Backend BuildID: $(file "$PREBUILT/lib64/libgfxstream_backend.so" | grep -o 'BuildID[^,]*')"
    exit 0
fi

DIST="$QEMU_DIR/objs/distribution/emulator"                 # stripped package (mirrors prebuilt)
DIST_UNSTRIPPED="$QEMU_DIR/objs/distribution-unstripped/emulator"
PYTHON="$EMU_ROOT/prebuilts/python/linux-x86/bin/python3"

log "Emulator source : $EMU_ROOT"

# ---- 1. build ---------------------------------------------------------------
if [[ "$MODE" != "nobuild" ]]; then
    [[ -x "$PYTHON" ]] || die "python not found at $PYTHON — is the emulator tree fully synced?"
    log "Building emulator host package (tests/integration disabled to avoid the headless X11 hang)"
    ( cd "$QEMU_DIR" && "$PYTHON" android/build/python/cmake.py --ccache auto \
        --task-disable Clean \
        --task-disable CTest \
        --task-disable EmugenTest \
        --task-disable GenEntriesTest \
        --task-disable CoverageReport \
        --task-disable PackageSamples \
        --task-disable ZipIntegrationTests \
        --task-disable IntegrationTest )
else
    log "Skipping build (--no-build); using existing objs/"
fi

[[ -d "$DIST" ]] || die "distribution package not found at $DIST (run a build first)"

# ---- 2. verify the fix is actually in the freshly built backend -------------
# gfxstream is built -fvisibility=hidden, so the fix is a LOCAL symbol: use the
# unstripped twin with full `nm -C` (NOT `nm -CD`, which only shows dynamic syms).
# Use grep -c (drains stdin) not grep -q: under pipefail, grep -q closes the pipe
# early, nm gets SIGPIPE, and the pipeline would falsely report failure.
log "Verifying the host fix is compiled into the backend"
if [[ -f "$DIST_UNSTRIPPED/lib64/libgfxstream_backend.so" ]]; then
    cnt=$(nm -C "$DIST_UNSTRIPPED/lib64/libgfxstream_backend.so" 2>/dev/null | grep -c "$FIX_SYMBOL")
    [[ "$cnt" -gt 0 ]] \
        || die "fix symbol '$FIX_SYMBOL' not found in built backend — is your emulator branch new enough?"
    echo "  fix present in unstripped backend ✓"
    a=$(file "$DIST/lib64/libgfxstream_backend.so"            | grep -o 'BuildID[^,]*')
    b=$(file "$DIST_UNSTRIPPED/lib64/libgfxstream_backend.so" | grep -o 'BuildID[^,]*')
    [[ "$a" == "$b" ]] || die "stripped/unstripped backend BuildID mismatch ($a vs $b) — stale distribution"
    echo "  stripped package backend matches the fresh build ($a) ✓"
else
    echo "  (no unstripped twin; skipping symbol check)"
fi

# ---- 3. back up the target prebuilt (idempotent, pre-overlay original) -------
if [[ -e "$BACKUP" ]]; then
    log "Backup already exists at $BACKUP — leaving it untouched (pre-overlay original)"
else
    log "Backing up target prebuilt -> $BACKUP"
    cp -a "$PREBUILT" "$BACKUP"
    # Integrity by apparent bytes, checked only right after creation while the
    # prebuilt is still pristine (NB: filesystem dedup/compression makes `du`
    # misleading; compare apparent content instead).
    o=$(find "$PREBUILT" -type f -printf '%s\n' | awk '{s+=$1} END{print s}')
    bb=$(find "$BACKUP"  -type f -printf '%s\n' | awk '{s+=$1} END{print s}')
    [[ "$o" == "$bb" ]] || die "backup byte total mismatch ($o vs $bb)"
    echo "  backup intact ($o bytes) ✓"
fi

# ---- 4. overlay the freshly built package -----------------------------------
# No --delete: keep optional prebuilt extras this build config may not produce
# (e.g. QtWebEngine location-map UI, gles_mesa GL driver).
# Exclude source.properties/android-info.txt so the package keeps its original
# SDK identity for tooling (binaries still self-report their real version via
# `emulator -version`).
log "Overlaying freshly built package onto the target prebuilt"
rsync -a --exclude='source.properties' --exclude='android-info.txt' "$DIST"/ "$PREBUILT"/

# ---- 5. verify the deployment -----------------------------------------------
log "Verifying deployment"
want=$(md5sum "$DIST/lib64/libgfxstream_backend.so"     | awk '{print $1}')
got=$( md5sum "$PREBUILT/lib64/libgfxstream_backend.so" | awk '{print $1}')
[[ "$want" == "$got" ]] || die "deployed backend md5 mismatch"
echo "  backend deployed (md5 $got) ✓"
[[ -f "$PREBUILT/source.properties" ]] && \
    echo "  package identity: $(grep -E 'Pkg.Revision|Pkg.BuildId' "$PREBUILT/source.properties" | tr '\n' ' ')"

# ABI: every android_/emugl/goldfish extern-C import of qemu-system must resolve
# across the package's libs (the whole set is now one consistent build).
export LC_ALL=C
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
qemu_bin=$(ls "$PREBUILT"/qemu/*/qemu-system-x86_64 2>/dev/null | head -1 || true)
if [[ -n "$qemu_bin" ]]; then
  ( cd "$PREBUILT"
    nm -D -u "$qemu_bin" 2>/dev/null | awk '{print $2}' \
        | grep -E '^(android_|emugl|goldfish_)' | sort -u > "$scratch/q_needs.txt"
    for so in lib64/*.so lib64/*/*.so; do
        nm -D --defined-only "$so" 2>/dev/null | awk '$2 ~ /[TWB]/ {print $3}'
    done | sort -u > "$scratch/pkg_exports.txt"
    unres=$(comm -23 "$scratch/q_needs.txt" "$scratch/pkg_exports.txt" || true)
    if [[ -z "$unres" ]]; then echo "  all qemu-system gfx imports resolve in-package ✓"
    else echo "  WARNING: unresolved symbols:"; echo "$unres" | sed 's/^/    /'; fi )
fi

# Smoke test: the binary must load and report a version.
log "Smoke test: emulator -version"
( cd "$PREBUILT" && timeout 60 ./emulator -version 2>&1 | head -2 )

log "Done. Deployed emulator into:"
echo "    $PREBUILT"
echo "Restore the original with: $0 --restore"
