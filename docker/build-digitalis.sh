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
# Build the Digitalis (ARM64->x86_64) binary distribution inside the
# "digitalis-build" Docker container, reusing the host's out/.
#
# No path is hardcoded: the repo root is discovered with git and bind-mounted at
# the SAME absolute path inside the container (`-v "$REPO":"$REPO" -w "$REPO"`),
# so AOSP's path-locked out/ is shared and the in-container build is incremental
# (no full rebuild) and stays usable by a subsequent host build. The container
# runs with the host uid/gid (as user "digitalis-build") so files written into
# out/ remain owned by the host developer. Forwards extra args (e.g. --full) to
# the package script.

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
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
# Build identity is a parameter (default "digitalis-build"), overridable via the
# BUILD_USER env var. The host login name ($(whoami)) is never used directly.
BUILD_USER="${BUILD_USER:-digitalis-build}"
IMAGE="${DIGITALIS_BUILD_IMAGE:-digitalis-build}"

echo ">>> repo:  $REPO"
echo ">>> image: $IMAGE  (user $BUILD_USER, uid:gid ${HOST_UID}:${HOST_GID})"

docker build -t "$IMAGE" \
    --build-arg "BUILD_USER=${BUILD_USER}" \
    --build-arg "HOST_UID=${HOST_UID}" \
    --build-arg "HOST_GID=${HOST_GID}" \
    "$REPO/digitalis/docker"

exec docker run --rm \
    -v "$REPO":"$REPO" -w "$REPO" \
    --user "${HOST_UID}:${HOST_GID}" \
    "$IMAGE" \
    bash digitalis/scripts/build-and-package-prebuilts.sh --username "$BUILD_USER" "$@"
