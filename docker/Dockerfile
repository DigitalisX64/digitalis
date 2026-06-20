# syntax=docker/dockerfile:1
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
# Reproducible build image for the Digitalis (ARM64->x86_64) binary
# distribution. The AOSP toolchains (clang/jdk/build-tools/go) come from the
# bind-mounted tree's prebuilts/, so only host OS utilities are installed here.
# The build identity is "digitalis-build".
#
# No source and no build path are baked in: the repo is bind-mounted at the same
# absolute path it has on the host (run with `-v "$REPO":"$REPO" -w "$REPO"`) so
# AOSP's path-locked out/ is reused, and the package script resolves everything
# relative to that working directory.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        bc bison ca-certificates ccache curl file flex git git-lfs gnupg \
        libncurses5 libssl-dev lib32z1 make procps python3 python-is-python3 \
        rsync unzip xz-utils zip zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Build identity is a parameter (default "digitalis-build"), never a hardcoded or
# host-derived name. It is stamped into AOSP builds via BUILD_USERNAME. Plus the
# env-var lunch bypass: the in-tree `lunch` can panic when a host `ugrep` shadows
# `grep`, so the build script exports the target directly instead of calling it.
ARG BUILD_USER=digitalis-build
ENV BUILD_USERNAME=${BUILD_USER} \
    BUILD_HOSTNAME=${BUILD_USER} \
    TARGET_PRODUCT=sdk_phone64_x86_64_digitalis \
    TARGET_RELEASE=trunk_staging \
    TARGET_BUILD_VARIANT=userdebug

# Create the unprivileged "${BUILD_USER}" user with the host's uid/gid so files
# written into the bind-mounted out/ stay owned by — and writable for — the host
# developer. Handles a pre-existing uid/gid in the base image by renaming it.
ARG HOST_UID=1000
ARG HOST_GID=1000
RUN set -eux; \
    if getent group "${HOST_GID}" >/dev/null; then \
        groupmod -n "${BUILD_USER}" "$(getent group "${HOST_GID}" | cut -d: -f1)"; \
    else \
        groupadd -g "${HOST_GID}" "${BUILD_USER}"; \
    fi; \
    if getent passwd "${HOST_UID}" >/dev/null; then \
        usermod -l "${BUILD_USER}" -d "/home/${BUILD_USER}" -m \
            "$(getent passwd "${HOST_UID}" | cut -d: -f1)"; \
        usermod -g "${HOST_GID}" "${BUILD_USER}"; \
    else \
        useradd -u "${HOST_UID}" -g "${HOST_GID}" -m -s /bin/bash "${BUILD_USER}"; \
    fi

USER ${BUILD_USER}
CMD ["bash", "digitalis/scripts/build-and-package-prebuilts.sh"]
