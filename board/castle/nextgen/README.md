# Castle NextGen Buildroot board files

This directory contains only files intentionally owned by the NextGen platform.

- `rootfs-overlay/` overlays the Buildroot target root filesystem.
- `post-build.sh` stages application-owned runtime assets from the sibling `app/` repository.
- Package-owned files, generated runtime state, credentials, calibration, recordings,
  SSH host keys and live-meter snapshots do not belong here.
- Field-update packaging can select individual files from this same overlay.

Kernel, U-Boot and AT91Bootstrap are maintained as sibling repositories and are
deliberately not built by this Buildroot defconfig.
