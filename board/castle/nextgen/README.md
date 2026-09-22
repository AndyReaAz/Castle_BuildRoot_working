# Castle NextGen Buildroot board files

This directory contains files intentionally owned by the NextGen platform.

Kernel, U-Boot and AT91Bootstrap are maintained as separate sibling repositories.
Buildroot does not configure or build those projects; the image step only stages
their current build products into the NextGen SD-card image.

## Fast-boot branch

The matching development branches are:

- U-Boot: `chatgpt/fast-boot`
- Buildroot: `chatgpt/fast-boot`
- Kernel: fast-boot work belongs in the separate `linux-at91` repository
- Application: current boot-split work

The fast-boot baseline is intentionally simple:

- AT91Bootstrap loads U-Boot from SD.
- U-Boot is headless and loads only `nextgen.dtb` and `zImage` from FAT.
- U-Boot environment remains in `/boot/uboot.env`, but fresh cards are seeded
  at image-build time so there is no first-boot `saveenv`.
- Linux fast-boot configuration is owned by the kernel repository.
- Linux owns display initialisation; the early application owns the splash.
- ADC/audio/display/touch/WILC support is left intact.

Build the kernel in the separate `linux-at91` repository and build U-Boot into
`../u-boot/build-fast` from its `chatgpt/fast-boot` branch. Then build this
Buildroot branch normally. The post-image step packages the already-built
kernel, DTB, U-Boot and AT91Bootstrap artifacts and generates `uboot.env` from
the matching U-Boot text environment.

The resulting deployment artifacts are:

- `output-nextgen/images/boot.vfat`
- `output-nextgen/images/sdcard.img`
- `output-nextgen/images/write-sd-card.sh`
- `output-nextgen/images/nextgen-image-manifest.sha256`
