# Castle NextGen Buildroot board files

This directory contains files intentionally owned by the NextGen platform.

Kernel, U-Boot and AT91Bootstrap are maintained as sibling trees and the
Buildroot image step stages their current build products.

## Fast-boot branch

The matching development branches are:

- U-Boot: `chatgpt/fast-boot`
- Buildroot: `chatgpt/fast-boot`
- Application: current boot-split work

The fast-boot baseline is intentionally simple:

- AT91Bootstrap loads U-Boot from SD.
- U-Boot is headless and loads only `nextgen.dtb` and `zImage` from FAT.
- U-Boot environment remains in `/boot/uboot.env`, but fresh cards are seeded
  at image-build time so there is no first-boot `saveenv`.
- Linux uses LZ4 kernel compression.
- Linux owns display initialisation; the early application owns the splash.
- ADC/audio/display/touch/WILC support is left intact.

Build the kernel from the current `linux-at91/.config` with:

```sh
sh board/castle/nextgen/prepare-fast-kernel.sh
```

That helper changes only kernel compression plus the already-identified unused
MACB/Kionix/APDS9306/SHT4x drivers, then rebuilds `zImage` and DTBs.

Build U-Boot into `../u-boot/build-fast` from its `chatgpt/fast-boot`
branch, then build this Buildroot branch normally. The post-image step refuses
to package a non-LZ4 kernel by default and generates `uboot.env` from the
matching U-Boot text environment.

The resulting deployment artifacts are:

- `output-nextgen/images/boot.vfat`
- `output-nextgen/images/sdcard.img`
- `output-nextgen/images/write-sd-card.sh`
- `output-nextgen/images/nextgen-image-manifest.sha256`
