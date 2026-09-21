# Castle NextGen Buildroot board files

This directory contains only files intentionally owned by the NextGen platform.

- `rootfs-overlay/` overlays the Buildroot target root filesystem.
- `post-build.sh` stages application-owned runtime assets from the sibling `app/` repository.
- Package-owned files, generated runtime state, credentials, calibration, recordings,
  SSH host keys and live-meter snapshots do not belong here.
- Field-update packaging can select individual files from this same overlay.

Kernel, U-Boot and AT91Bootstrap are maintained as sibling repositories and are
deliberately not built by this Buildroot defconfig.


## SD-card images

The Buildroot post-image step assembles `images/boot.vfat` from the current
sibling builds:

- `../at91bootstrap` -> `boot.bin`
- `../u-boot` -> `u-boot.bin`
- `../linux-at91` -> `zImage` and `nextgen.dtb`
- a maintained `uboot.env` (the old app DeviceScripts copy is accepted only
  as a migration fallback)

A complete currently-bootable card uses the legacy three-partition layout:
FAT p1 for boot, ext4 p2 for the Buildroot rootfs, and ext4 p3 for meter data.
Because p3 should use the actual remainder of whatever SD card is being
programmed, `images/write-sd-card.sh` writes the final card rather than
embedding a fixed-size data partition in a huge disk image.

Usage:

```sh
sudo output-nextgen/images/write-sd-card.sh /dev/sdX
```

The writer refuses mounted devices, requires an explicit ERASE confirmation,
and verifies that p3 will be larger than the application's 4 GiB minimum.
