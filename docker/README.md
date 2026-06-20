# Digitalis binary distribution (Docker build)

Build the **Digitalis** ARM64→x86_64 translator as a **binary-only** bundle that
other AOSP x86_64 products can integrate without compiling Berberis from source.
The build runs in a reproducible Docker container whose build identity is
`digitalis-build`, and it **reuses the host's existing `out/`** so a normal host
developer never has to rebuild the tree.

## What you get

A `digitalis/dist/digitalis-prebuilts/` tree (and a matching `.tar.gz`) holding the
73 canonical artifacts from `BERBERIS_DISTRIBUTION_ARTIFACTS_ARM64`:

- `system/lib64/libberberis_arm64.so` — the translator / native bridge.
- `system/lib64/libberberis_exec_region.so` + 21 `libberberis_proxy_*.so` proxy libs.
- `system/bin/berberis_program_runner_arm64`, `…_binfmt_misc_arm64`.
- `system/lib64/arm64/*.so` — the ARM64 guest libraries (libc, libm, libvulkan, …).
- `system/bin/arm64/{app_process64,linker64}`.
- Configs: `system/etc/ld.config.arm64.txt`, `system/etc/init/berberis.rc`,
  `system/etc/binfmt_misc/arm64_{dyn,exe}`.
- `digitalis-prebuilts.mk`, `MANIFEST.txt`, `SHA256SUMS`, and a generated
  `README.md` that documents how a consumer integrates the bundle into an x86_64
  product source.

**Scope:** the translator only. The consuming product supplies the x86_64 host
system (and, for Vulkan, the GFXStream/ANGLE GPU stack).

## Prerequisites

- Docker, with your user in the `docker` group.
- A **full host build already present** at `out/target/product/emu64xa/` (the guest
  libs and configs come from image assembly). If you have never run a full `m`,
  pass `--full` the first time.

## Build

```bash
# From anywhere inside the repo:
digitalis/docker/build-digitalis.sh                # incremental, reuses out/
digitalis/docker/build-digitalis.sh --full         # full image-complete build
```

The wrapper discovers the repo root with `git`, builds the `digitalis-build` image
with your uid/gid, and runs the container with the repo **bind-mounted at the same
absolute path** (`-v "$REPO":"$REPO" -w "$REPO"`). That identical path is what lets
AOSP's path-locked `out/` be shared: the in-container build is incremental and the
result stays usable by a later host `m`. Files written into `out/` are owned by your
host user (the container runs as `digitalis-build` with your uid).

You can also run the package step directly on the host (no Docker), same logic:

```bash
digitalis/scripts/build-and-package-prebuilts.sh
```

## Verify

```bash
digitalis/scripts/verify-digitalis-prebuilts.sh
```

Checks every artifact is present with the correct ELF arch (host libs → x86-64,
guest libs → AArch64), the translator exports `NativeBridgeItf`, the consumer
makefile is well-formed, and the recorded `SHA256SUMS` still match. It prints the
`digitalis-build` builder identity from `MANIFEST.txt`.

## Integrate into a consumer product

1. Copy `digitalis/dist/digitalis-prebuilts/` into the consumer tree, e.g.
   `vendor/digitalis/prebuilts/`.
2. Inherit it from the x86_64 product `.mk`:

   ```make
   $(call inherit-product, vendor/digitalis/prebuilts/digitalis-prebuilts.mk)
   ```

   That makefile sets the native-bridge properties
   (`ro.dalvik.vm.native.bridge=libberberis_arm64.so`, `ro.dalvik.vm.isa.arm64=x86_64`,
   `ro.enable.native.bridge.exec=1`), copies every artifact into the image, and
   allow-lists the artifact paths.
3. Build the consumer product. ARM64-only apps now run via translation.

## Notes

- **Permissions:** the container uses your host uid/gid so it never leaves
  root-owned files in `out/`. If you build as a different user, the image is rebuilt
  with that uid automatically.
- **No hardcoded paths:** nothing in these scripts or the generated bundle embeds an
  absolute build path. The tree root is taken from `ANDROID_BUILD_TOP` (the env var
  AOSP's `lunch` exports) when set, otherwise found by walking up to the canonical
  AOSP marker `build/make/core/envsetup.mk` (the same one envsetup's `gettop` uses);
  the package step then re-verifies it against `gettop` after sourcing envsetup. So
  the tree works wherever it is checked out, and host and container agree on the path
  via the `-v "$REPO":"$REPO"` mount.
