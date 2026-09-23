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

The development ext4 root image is deliberately limited to 128 MiB. This both
fails the Buildroot image generation if the populated rootfs grows beyond the
first flash-root budget and keeps the SD test image representative of the
planned 128 MiB UBI rootfs partition.

The deferred SD kernel is also the flash-characterisation image. It keeps
MTD/UBI/UBIFS available, disables UBI fastmap for a full-scan baseline, and
ships mtd-utils. The concrete SPI NOR, QSPI and SPI-NAND drivers remain modules
and are blacklisted from udev alias autoload in this SD profile, so they do not
compete with application startup and can be timed explicitly. For quiet flash
timing, SSH over the engineering USB link and run
`/etc/init.d/S00NextGen stop`; this stops both the application and its restart
watchdog. Direct `modprobe spi-nor`, `modprobe atmel-quadspi` and
`modprobe spinand` commands remain available for the test.


## Kernel working checkout

The normal ChatGPT-accessible kernel checkout is expected at
`../linux-working`, tracking `AndyReaAz/Castle_linux_working`. The hidden
`.git/nextgen-batch-push/` repositories are only import/relay machinery and
must not be treated as production build locations.

`post-build.sh` installs a complete module tree from the selected kernel build when one exists; the monolithic control kernel legitimately has none. `post-image.sh` stages `zImage` and `nextgen.dtb` from that same selected build directory.

For the control image, leave `NEXTGEN_KERNEL_BUILD_DIR` unset. For the deferred-module image, set it to `../linux-working/build-fast-deferred`.


## Linux 6.18 migration branch

On `chatgpt/nextgen-6.18`, the first Linux 6.18 SD baseline uses the
external kernel build in `../linux-6.18/build-fast-6.18`. The matching
kernel release is `6.18.35-linux4microchip-2026.04.2+`.

The post-build script accepts `NEXTGEN_KERNEL_MODULES_ROOT` so a validated
external `modules_install` staging tree can be packaged without copying it
into the kernel checkout first. For the current migration test:

```sh
NEXTGEN_KERNEL_BUILD_DIR=../linux-6.18/build-fast-6.18 \
NEXTGEN_KERNEL_MODULES_ROOT=../staging/linux-6.18-modules/lib/modules \
NEXTGEN_EXPECTED_KERNEL_RELEASE=6.18.35-linux4microchip-2026.04.2+ \
NEXTGEN_KERNEL_PROFILE=deferred-diag
```

WILC3000 remains on firmware 16.3 for the first 6.18 comparison. The firmware
package installs the same Wi-Fi binary at both the legacy `mchp/` path and
the 6.18 driver path `atmel/wilc3000_wifi_firmware-1.bin`.


The convenience image wrapper has explicit 6.18 profiles:

```sh
./build-nextgen-image.sh 6.18
./build-nextgen-image.sh 6.18-diag
```

The diagnostic variant selects the existing diagnostic U-Boot/environment while
using the same 6.18 kernel, DTB and staged module tree. Internally it retains
the existing `deferred-diag` policy so WILC, QSPI and SPI-NAND stay
application/manual-load controlled.
