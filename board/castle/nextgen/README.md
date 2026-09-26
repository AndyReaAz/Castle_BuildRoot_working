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


## Read-only root and Application image slots

The `6.18-ro` profile is the first complete storage-layout swap. It keeps
AT91Bootstrap, U-Boot, kernel and DTB on the SD boot partition, but changes
Linux/userspace ownership to:

```text
p1  FAT       /boot      boot.bin, U-Boot, zImage, DTB, uboot.env
p2  SquashFS  /          immutable system root
p3  ext4      /persist   durable instrument/application state
p4  ext4      /sdcard    recordings, imports, exports, update download staging
```

The physical p4 partition is created to the end of the actual card by
`write-sd-card.sh`. The generated `sdcard.img` contains a small seed p4 and
is mainly useful for inspection.

`/sdcard` is deliberately not mounted by `fstab`. The Application owns the
recording filesystem mount so it can validate partition geometry, run ext4
recovery and verify write/fsync behaviour before exposing storage.

The Application supports both migration stages: while the system itself is on
SD, recording storage is the final partition after the system partitions; once
the platform boots completely independently of SD, recording storage is p1.
A future fully SD-independent flash profile must install the immutable
`/etc/nextgen-sd-data-only` marker before allowing Format Memory to replace
the whole card with one p1. Do not install that marker in `6.18-ro` or the
current NAND timing profile because those profiles still consume SD.

Above the mount layer the Application sees stable paths:

```text
/opt/nextgen/platform/         immutable platform helpers/assets
/opt/nextgen/common/share/     immutable shared assets
/opt/nextgen/factory/<product> immutable factory Application fallback

/opt/nextgen/app               bind -> /persist/app
/opt/nextgen/data              bind -> /persist/data
/opt/nextgen/state             bind -> /persist/state
/opt/nextgen/common/state      bind -> /persist/common-state
```

The persistent Application realm is image based:

```text
/persist/app/<product>/
  slotA.sqfs
  slotA.meta
  slotB.sqfs
  slotB.meta
  active/                      runtime mount point
```

The selected `.sqfs` is hash-validated and mounted read-only at
`active/`. The immutable system image also contains a factory Application
directory which is the final recovery anchor when persistent slot state is
missing or corrupt.

Mutable ownership is deliberately separated:

- settings, calibration, FTP queue and user/imported templates live in
  `/persist/data/<product>/`;
- the live HPD database is independently managed persistent content;
- the Application image carries only a known-compatible fallback HPD copy;
- certified/built-in templates are release-owned and live in the Application
  image, while user templates persist across releases;
- service audit/crash/update state live in `/persist/state`;
- SSH keys, NetworkManager/D-Bus/Chrony state and RNG seed live below
  `/persist/os`.

Routine Application updates use format 4 and contain one immutable SquashFS
image plus signed metadata. The accepted image is never modified in place.
A candidate is written to the inactive slot, fully hashed and mounted for
validation, then marked pending. Acceptance happens only after the new
Application reaches the normal measurement-started milestone; failure before
that causes rollback to the previous accepted image.

The platform ABI is currently `1` and is checked by both installer and
launcher.

### Building the first RO SD image

The matching prototype branches are:

```text
Application  chatgpt/ro-root-image-slots
Buildroot    chatgpt/ro-root-image-slots
Linux 6.18  chatgpt/ro-root-image-slots
U-Boot       chatgpt/ro-root-image-slots
AT91Bootstrap existing fast-boot build
```

Rebuild Linux 6.18 from the RO branch first. The branch's
`build-fast.sh` also refreshes the module staging tree expected by Buildroot
at `../staging/linux-6.18-modules`, so there is no separate
`modules_install` step:

```sh
cd ../linux-6.18
KERNEL_BASE_CONFIG=../linux-at91/.config ./build-fast.sh rebuild
```

Buildroot refuses to emit the RO image unless the selected external kernel has
these built in:

```text
CONFIG_EXT4_FS=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_SQUASHFS=y
CONFIG_SQUASHFS_LZO=y
```

Rebuild the matching Application, then from Buildroot run:

```sh
./build-nextgen-image.sh 6.18-ro sound
# or:
./build-nextgen-image.sh 6.18-ro vibra
```

The RO SD and production-flash profiles share one Buildroot output tree because
their package/toolchain universe is identical; product and storage differences
are applied by the late staging/image hooks.  By default that tree is
`output-nextgen-shared`.  During transition an existing populated tree can be
reused without rebuilding packages, for example:

```sh
NEXTGEN_SHARED_BUILDROOT_OUT="$PWD/output-nextgen-sound" \
    ./build-nextgen-image.sh 6.18-ro sound
```

The important RO-SD outputs in the selected shared tree are:

```text
images/boot.vfat
images/uboot.env
images/rootfs.squashfs
images/persist.ext4
images/sdcard.img
images/write-sd-card.sh
```

Switching sound/vibra, SD/NAND or bring-up on that same tree reruns final
staging and image generation but reuses the already-built host tools, toolchain
and target packages. Bring-up uses a different kernel/rootfs format and hook
policy, but its Buildroot package universe is the same; the common post-build
step explicitly normalizes RO-only state when switching profiles.

After each verified 6.18 RO/flash/bring-up build, the wrapper snapshots the
deployable artifacts outside the mutable shared O= tree under:

```text
output-nextgen-artifacts/<product>/<profile>/
```

Each snapshot includes a generated `SHA256SUMS`, so the next product/backend
pass can safely replace `output-nextgen-shared/images` without losing the
previous verified result.

A populated Buildroot `O=` directory must not be physically renamed or moved:
host tools such as GCC and fakeroot contain absolute paths back into that tree.
For an existing populated tree, keep its original physical directory and use
`NEXTGEN_SHARED_BUILDROOT_OUT`, or create a neutral symlink such as
`output-nextgen-shared -> output-nextgen-sound`.  The wrapper resolves such a
symlink before invoking Buildroot and rejects an already-relocated tree when the
cross-compiler sysroot no longer matches its physical path.

The RO post-build/post-image checks deliberately fail the build for stale
Application binaries, wrong storage ownership, missing factory content,
missing HPD/template fallbacks, invalid helper scripts or a kernel without the
required built-in filesystem support.

Development images retain the explicit `unsigned-development` update policy.
A production image can require Ed25519-signed Application images by supplying
the update public key in the normal way.


## Linux 6.18 NAND-root timing profile

The isolated `6.18-nand` image profile keeps AT91Bootstrap, U-Boot, the DTB
and the kernel on the SD boot partition, but changes the Linux root filesystem
to the SPI-NAND `rootfs` UBI volume:

```text
ubi.mtd=rootfs root=ubi0:rootfs rootfstype=ubifs rw
```

This deliberately measures only the UBI/UBIFS root-filesystem path. It does not
change the normal SD-root environment and does not move the kernel or DTB into
NAND.

Build it with:

```sh
./build-nextgen-image.sh 6.18-nand sound
# or: vibra
```

Before booting this profile, write the matching `rootfs.ubi` image to the
128 MiB NAND `rootfs` partition. The partition is defined by the NextGen DTB
at offset `0x00880000` and is exposed by Linux as the MTD partition named
`rootfs`. Use the partition name when scripting rather than relying on a
fixed MTD number.

The timing profile uses the normal preemptible Linux 6.18 kernel and otherwise
retains the same runtime policy as the `6.18` image. Switching back to the
normal SD environment returns the meter to SD-root operation.


## Production NOR + SPI-NAND boot profile

The `6.18-flash` profile builds the production storage chain without an SD-card
dependency:

```text
SAMA5D2 ROM
  -> SPI NOR: AT91Bootstrap
  -> SPI NOR: U-Boot
  -> SPI-NAND "boot" UBI partition
       static volume "device-tree"
       static volume "kernel"
  -> SPI-NAND "rootfs" UBI partition
       volume "rootfs"
```

The SPI-NAND layout is deliberately split at `0x00880000`:

```text
0x00000000-0x0087ffff   boot    8.5 MiB / 68 eraseblocks
0x00880000-0x0887ffff   rootfs  128 MiB
remainder               spare
```

The boot partition is a separate small UBI device so U-Boot does not have to
attach and scan the 128 MiB rootfs device just to obtain the kernel. Both boot
objects are static UBI volumes. Their volume metadata records the exact
`used_bytes`, so `ubi read` with no explicit size loads only the real DTB or
kernel length rather than the whole reserved partition. Static-volume CRC and
UBI bad-block handling also apply to the boot objects. Image generation limits
`boot.ubi` to 8 MiB, deliberately leaving four 128 KiB eraseblocks free in the
8.5 MiB partition for UBI/bad-block reserve.

Build the prerequisites and image with:

```sh
cd ../at91bootstrap
./build-fast.sh rebuild nor

cd ../u-boot
./build-fast.sh rebuild flash

cd ../Castle_BuildRoot_working
./build-nextgen-image.sh 6.18-flash sound
```

The flash profile emits:

```text
nor.img                    complete 2 MiB NOR image for an external programmer
nor-at91bootstrap.bin      0x008000-byte labelled NOR partition image
nor-uboot.bin              0x138000-byte labelled NOR partition image
nor-uboot-env.bin          0x020000-byte redundant environment partition image
boot.ubi                   small SPI-NAND boot UBI image
rootfs.ubi                 SPI-NAND root filesystem UBI image
program-nextgen-flash.sh   manual Linux/bring-up-SD programming helper
nextgen-flash-manifest.sha256
```

The complete `nor.img` contains AT91Bootstrap, U-Boot, the exact-length
trailer at `0x13fff0`, and both redundant 16 KiB environment payloads. The
partition-sized NOR images contain the same bytes but are aligned to the DT
labels `at91bootstrap`, `uboot` and `uboot-env`; this lets a bring-up SD
program them by MTD label without assuming a `/dev/mtdN` number.

Linux is required to expose 4 KiB SPI-NOR erase units for this programming
path. The MX25V1635F supports 4 KiB subsectors, and the 4 KiB geometry is needed
because the `0x8000` AT91Bootstrap/U-Boot boundary is not 64 KiB aligned.
U-Boot itself may still erase a full 64 KiB block when updating an environment
copy; each redundant copy deliberately owns its own 64 KiB region.

The UBI images are installed with `ubiformat`, not raw NAND writes, so factory
bad blocks are handled during installation. From the SD bring-up system, copy
the complete flash artifact set into one directory and first run the
non-destructive check:

```sh
./program-nextgen-flash.sh check
```

Only after the labels, geometry and SHA-256 manifest all validate, program with:

```sh
./program-nextgen-flash.sh program --confirm-nextgen-flash
```

The helper refuses the write unless it is running from the SD environment. It
formats `rootfs` first, then the small boot UBI, writes the redundant NOR
environment, installs the new AT91Bootstrap, and writes U-Boot last. Making
U-Boot the final write leaves the old boot path untouched until every storage
dependency needed by the new production U-Boot has been prepared.


## Production NOR + NAND/UBI boot

The production flash schema keeps the two bootloader stages in the 2 MiB SPI NOR
and uses two independent UBI devices in SPI-NAND:

```text
SPI NOR
  0x000000-0x007fff  AT91Bootstrap
  0x008000-0x13ffff  U-Boot partition
  0x140000-0x15ffff  redundant U-Boot environment

SPI-NAND
  0x00000000-0x0087ffff  boot UBI (8.5 MiB)
      device-tree          static volume
      kernel               static volume
  0x00880000-0x0887ffff  rootfs UBI (128 MiB)
      rootfs               dynamic/autoresize volume
  remainder                intentionally spare
```

The boot UBI partition deliberately occupies exactly the old raw DTB + kernel
area, so the already-used rootfs offset remains `0x00880000`. Its size is 68
128-KiB eraseblocks. The generated `boot.ubi` is limited to 8 MiB, leaving at
least four physical eraseblocks of margin for bad blocks/UBI overhead.

The boot objects are UBI static volumes rather than UBIFS files. U-Boot attaches
only the small `boot` partition and runs:

```text
ubi part boot
ubi read ${loadaddr} device-tree
ubi read ${krnladdr} kernel
bootz ${krnladdr} - ${loadaddr}
```

No explicit byte count is supplied to `ubi read`. U-Boot therefore uses the
volume's recorded `used_bytes`, so only the actual DTB/kernel content is read
even though their volumes may reserve more eraseblocks. This also gives the boot
objects UBI bad-block handling without mounting UBIFS or scanning the 128 MiB
rootfs UBI before the kernel starts.

Build the complete flash artifact set with:

```sh
./build-nextgen-image.sh 6.18-flash sound
# or: vibra
```

The image step emits `boot.ubi`, `rootfs.ubi`, the three padded NOR partition
images, a complete 2 MiB `nor.img`, a SHA-256 manifest and
`program-nextgen-flash.sh`. The programming helper is intentionally allowed
only from the SD bring-up environment and writes U-Boot last.
