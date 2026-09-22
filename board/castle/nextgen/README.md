# Castle NextGen Buildroot board files

This directory contains files intentionally owned by the NextGen platform.

Kernel, U-Boot and AT91Bootstrap are maintained as separate sibling repositories.
Buildroot does not configure or build those projects; the image step only stages
their current build products into the NextGen SD-card image.

## Fast-boot branch

The matching development branches are:

- U-Boot: `chatgpt/fast-boot`
- Buildroot: `chatgpt/fast-boot`
- Kernel: `../linux-working`, branch `chatgpt/fast-boot`
- Application: current boot-split work

The fast-boot baseline is intentionally simple:

- AT91Bootstrap loads U-Boot from SD.
- U-Boot is headless and loads only `nextgen.dtb` and `zImage` from FAT.
- U-Boot environment remains in `/boot/uboot.env`, but fresh cards are seeded
  at image-build time so there is no first-boot `saveenv`.
- Linux fast-boot configuration is owned by the kernel repository.
- Linux owns display initialisation; the early application owns the splash.
- The baseline keeps ADC/audio/display/touch/WILC built-in exactly as the known-good `workingconfig`.
- A separate deferred-module profile moves only non-boot-critical drivers out of the kernel for measured comparison.

Build the kernel in `../linux-working` and build U-Boot into
`../u-boot/build-fast` from its `chatgpt/fast-boot` branch.

The kernel has two deliberately separate outputs:

- `../linux-working/build-fast`: LZ4 control kernel; known-good hardware config.
- `../linux-working/build-fast-deferred`: stage-2 kernel with selected
  non-boot-critical drivers moved to modules.

Buildroot packages exactly the directory selected by `NEXTGEN_KERNEL_BUILD_DIR`.
It does not fall back to stale artifacts from the old `linux-at91` checkout.

The resulting deployment artifacts are:

- `output-nextgen/images/boot.vfat`
- `output-nextgen/images/sdcard.img`
- `output-nextgen/images/write-sd-card.sh`
- `output-nextgen/images/nextgen-image-manifest.sha256`


## Kernel working checkout

The normal ChatGPT-accessible kernel checkout is expected at
`../linux-working`, tracking `AndyReaAz/Castle_linux_working`. The hidden
`.git/nextgen-batch-push/` repositories are only import/relay machinery and
must not be treated as production build locations.

`post-build.sh` installs a complete module tree from the selected kernel build when one exists; the monolithic control kernel legitimately has none. `post-image.sh` stages `zImage` and `nextgen.dtb` from that same selected build directory.

For the control image, leave `NEXTGEN_KERNEL_BUILD_DIR` unset. For the deferred-module image, set it to `../linux-working/build-fast-deferred`.
