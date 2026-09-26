#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
WORKSPACE="$(CDPATH= cd -- "$ROOT/.." && pwd)"
PROFILE="${1:-baseline}"
shift || true

PRODUCT_EXPLICIT=0
if [ -n "${NEXTGEN_PRODUCT:-}" ]; then
    PRODUCT="$NEXTGEN_PRODUCT"
    PRODUCT_EXPLICIT=1
else
    PRODUCT=sound
fi

case "${1:-}" in
    sound|vibra|both)
        PRODUCT="$1"
        PRODUCT_EXPLICIT=1
        shift
        ;;
esac

case "$PRODUCT" in
    sound|vibra|both) ;;
    *)
        echo "error: NEXTGEN_PRODUCT must be sound, vibra or both" >&2
        exit 2
        ;;
esac

if [ "$PRODUCT" = both ] && [ -n "${NEXTGEN_BUILDROOT_OUT:-}" ]; then
    echo "error: NEXTGEN_BUILDROOT_OUT cannot name one output tree when building both products" >&2
    exit 2
fi

KERNEL_PROFILE="$PROFILE"
KERNEL_MODULES_ROOT=""
EXPECTED_KERNEL_RELEASE=""
BUILDROOT_DEFCONFIG="castle_nextgen_dev_defconfig"
STORAGE_SCHEMA="legacy"
STORAGE_BACKEND="legacy"

case "$PROFILE" in
    baseline)
        KERNEL_BUILD_DIR="$WORKSPACE/linux-working/build-fast"
        EXPECTED_KERNEL_RELEASE="6.6.23-linux4microchip-2024.04+"
        ;;
    deferred)
        KERNEL_BUILD_DIR="$WORKSPACE/linux-working/build-fast-deferred"
        EXPECTED_KERNEL_RELEASE="6.6.23-linux4microchip-2024.04+"
        ;;
    deferred-diag)
        KERNEL_BUILD_DIR="$WORKSPACE/linux-working/build-fast-deferred"
        EXPECTED_KERNEL_RELEASE="6.6.23-linux4microchip-2024.04+"
        NEXTGEN_UBOOT_IMAGE="$WORKSPACE/u-boot/build-diag/u-boot.bin"
        NEXTGEN_MKENVIMAGE="$WORKSPACE/u-boot/build-diag/tools/mkenvimage"
        NEXTGEN_UBOOT_ENV_TEXT="$WORKSPACE/u-boot/board/atmel/sama5d27_nextgen/sama5d27_nextgen_diag.env"
        export NEXTGEN_UBOOT_IMAGE NEXTGEN_MKENVIMAGE NEXTGEN_UBOOT_ENV_TEXT
        ;;
    6.18)
        KERNEL_BUILD_DIR="$WORKSPACE/linux-6.18/build-fast-6.18"
        KERNEL_MODULES_ROOT="$WORKSPACE/staging/linux-6.18-modules/lib/modules"
        EXPECTED_KERNEL_RELEASE="6.18.35-linux4microchip-2026.04.2+"
        KERNEL_PROFILE="deferred"
        NEXTGEN_AT91BOOTSTRAP="$WORKSPACE/at91bootstrap/build-sd/binaries/boot.bin"
        NEXTGEN_UBOOT_IMAGE="$WORKSPACE/u-boot/build-fast/u-boot.bin"
        NEXTGEN_MKENVIMAGE="$WORKSPACE/u-boot/build-fast/tools/mkenvimage"
        export NEXTGEN_AT91BOOTSTRAP NEXTGEN_UBOOT_IMAGE NEXTGEN_MKENVIMAGE
        ;;
    6.18-ro)
        # Isolated RO-root prototype: boot/kernel/DTB remain on SD, p2 is
        # immutable SquashFS, p3 is writable persistent state and p4 is data.
        KERNEL_BUILD_DIR="$WORKSPACE/linux-6.18/build-fast-6.18"
        KERNEL_MODULES_ROOT="$WORKSPACE/staging/linux-6.18-modules/lib/modules"
        EXPECTED_KERNEL_RELEASE="6.18.35-linux4microchip-2026.04.2+"
        KERNEL_PROFILE="deferred"
        BUILDROOT_DEFCONFIG="castle_nextgen_ro_dev_defconfig"
        STORAGE_SCHEMA="ro-persist-v1"
        STORAGE_BACKEND="sd-ext4"
        NEXTGEN_AT91BOOTSTRAP="$WORKSPACE/at91bootstrap/build-sd/binaries/boot.bin"
        NEXTGEN_UBOOT_IMAGE="$WORKSPACE/u-boot/build-fast/u-boot.bin"
        NEXTGEN_MKENVIMAGE="$WORKSPACE/u-boot/build-fast/tools/mkenvimage"
        NEXTGEN_UBOOT_ENV_TEXT="$WORKSPACE/u-boot/board/atmel/sama5d27_nextgen/sama5d27_nextgen_ro.env"
        export NEXTGEN_AT91BOOTSTRAP NEXTGEN_UBOOT_IMAGE NEXTGEN_MKENVIMAGE NEXTGEN_UBOOT_ENV_TEXT
        ;;
    6.18-bringup)
        # Factory/service image: SD boot and rootfs with framebuffer-console
        # operator UI. It carries a separately-built production provision bundle
        # but no measurement Application.
        KERNEL_BUILD_DIR="$WORKSPACE/linux-6.18/build-fast-6.18-bringup"
        KERNEL_MODULES_ROOT=""
        EXPECTED_KERNEL_RELEASE="6.18.35-linux4microchip-2026.04.2+"
        KERNEL_PROFILE="bringup"
        BUILDROOT_DEFCONFIG="castle_nextgen_bringup_defconfig"
        STORAGE_SCHEMA="bringup-sd-v1"
        STORAGE_BACKEND="bringup-sd"
        NEXTGEN_AT91BOOTSTRAP="$WORKSPACE/at91bootstrap/build-sd/binaries/boot.bin"
        NEXTGEN_UBOOT_IMAGE="$WORKSPACE/u-boot/build-fast/u-boot.bin"
        NEXTGEN_MKENVIMAGE="$WORKSPACE/u-boot/build-fast/tools/mkenvimage"
        NEXTGEN_UBOOT_ENV_TEXT="$ROOT/board/castle/nextgen/uboot-bringup.env"
        export NEXTGEN_AT91BOOTSTRAP NEXTGEN_UBOOT_IMAGE NEXTGEN_MKENVIMAGE NEXTGEN_UBOOT_ENV_TEXT
        ;;
    6.18-nand)
        # Timing profile: keep bootstrap/U-Boot/kernel/DTB on SD and move only
        # the Linux root filesystem to the SPI-NAND rootfs UBI volume.
        KERNEL_BUILD_DIR="$WORKSPACE/linux-6.18/build-fast-6.18"
        KERNEL_MODULES_ROOT="$WORKSPACE/staging/linux-6.18-modules/lib/modules"
        EXPECTED_KERNEL_RELEASE="6.18.35-linux4microchip-2026.04.2+"
        KERNEL_PROFILE="deferred"
        NEXTGEN_AT91BOOTSTRAP="$WORKSPACE/at91bootstrap/build-sd/binaries/boot.bin"
        NEXTGEN_UBOOT_IMAGE="$WORKSPACE/u-boot/build-fast/u-boot.bin"
        NEXTGEN_MKENVIMAGE="$WORKSPACE/u-boot/build-fast/tools/mkenvimage"
        NEXTGEN_UBOOT_ENV_TEXT="$WORKSPACE/u-boot/board/atmel/sama5d27_nextgen/sama5d27_nextgen_nand.env"
        export NEXTGEN_AT91BOOTSTRAP NEXTGEN_UBOOT_IMAGE NEXTGEN_MKENVIMAGE NEXTGEN_UBOOT_ENV_TEXT
        ;;
    6.18-flash)
        # Production no-SD image. NOR contains bootstrap/U-Boot; the small NAND
        # boot UBI contains kernel+DTB; the 128 MiB NAND rootfs UBI contains the
        # same immutable SquashFS system and writable persist tree as the SD
        # ro-persist-v1 image.
        KERNEL_BUILD_DIR="$WORKSPACE/linux-6.18/build-fast-6.18"
        KERNEL_MODULES_ROOT="$WORKSPACE/staging/linux-6.18-modules/lib/modules"
        EXPECTED_KERNEL_RELEASE="6.18.35-linux4microchip-2026.04.2+"
        KERNEL_PROFILE="deferred"
        BUILDROOT_DEFCONFIG="castle_nextgen_ro_dev_defconfig"
        STORAGE_SCHEMA="ro-persist-v1"
        STORAGE_BACKEND="nand-ubi"
        NEXTGEN_AT91BOOTSTRAP="$WORKSPACE/at91bootstrap/build-nor/binaries/boot.bin"
        NEXTGEN_UBOOT_IMAGE="$WORKSPACE/u-boot/build-flash/u-boot.bin"
        NEXTGEN_UBOOT_TRAILER="$WORKSPACE/u-boot/build-flash/u-boot.nor-trailer"
        NEXTGEN_MKENVIMAGE="$WORKSPACE/u-boot/build-flash/tools/mkenvimage"
        NEXTGEN_UBOOT_ENV_TEXT="$WORKSPACE/u-boot/board/atmel/sama5d27_nextgen/sama5d27_nextgen_flash.env"
        export NEXTGEN_AT91BOOTSTRAP NEXTGEN_UBOOT_IMAGE NEXTGEN_UBOOT_TRAILER
        export NEXTGEN_MKENVIMAGE NEXTGEN_UBOOT_ENV_TEXT
        ;;
    6.18-diag)
        KERNEL_BUILD_DIR="$WORKSPACE/linux-6.18/build-fast-6.18"
        KERNEL_MODULES_ROOT="$WORKSPACE/staging/linux-6.18-modules/lib/modules"
        EXPECTED_KERNEL_RELEASE="6.18.35-linux4microchip-2026.04.2+"
        KERNEL_PROFILE="deferred-diag"
        NEXTGEN_AT91BOOTSTRAP="$WORKSPACE/at91bootstrap/build-sd-timing-deferred/binaries/boot.bin"
        NEXTGEN_UBOOT_IMAGE="$WORKSPACE/u-boot/build-diag/u-boot.bin"
        NEXTGEN_MKENVIMAGE="$WORKSPACE/u-boot/build-diag/tools/mkenvimage"
        NEXTGEN_UBOOT_ENV_TEXT="$WORKSPACE/u-boot/board/atmel/sama5d27_nextgen/sama5d27_nextgen_diag.env"
        export NEXTGEN_AT91BOOTSTRAP NEXTGEN_UBOOT_IMAGE NEXTGEN_MKENVIMAGE NEXTGEN_UBOOT_ENV_TEXT
        ;;
    *)
        echo "Usage: $0 [baseline|deferred|deferred-diag|6.18|6.18-ro|6.18-bringup|6.18-nand|6.18-flash|6.18-diag] [sound|vibra|both] [make-target ...]" >&2
        exit 2
        ;;
esac

nextgen_buildroot_out()
{
    product="$1"

    if [ -n "${NEXTGEN_BUILDROOT_OUT:-}" ]; then
        printf '%s\n' "$NEXTGEN_BUILDROOT_OUT"
    elif [ "$PROFILE" = "6.18-ro" ] || [ "$PROFILE" = "6.18-flash" ]; then
        printf '%s\n' "${NEXTGEN_SHARED_BUILDROOT_OUT:-$ROOT/output-nextgen-shared}"
    elif [ "$PROFILE" = "6.18-bringup" ]; then
        printf '%s\n' "${NEXTGEN_BRINGUP_BUILDROOT_OUT:-$ROOT/output-nextgen-bringup}"
    elif [ "$PRODUCT_EXPLICIT" -eq 1 ]; then
        printf '%s\n' "$ROOT/output-nextgen-$product"
    else
        printf '%s\n' "$ROOT/output-nextgen"
    fi
}

# Lightweight planning mode for wrapper regressions and operator inspection.
# It deliberately stops before checking or building any platform artifact.
if [ "${NEXTGEN_PLAN_ONLY:-0}" = 1 ]; then
    case "$PRODUCT" in
        both)
            printf 'sound=%s\n' "$(nextgen_buildroot_out sound)"
            printf 'vibra=%s\n' "$(nextgen_buildroot_out vibra)"
            ;;
        sound|vibra)
            printf '%s=%s\n' "$PRODUCT" "$(nextgen_buildroot_out "$PRODUCT")"
            ;;
    esac
    exit 0
fi

[ -f "$KERNEL_BUILD_DIR/arch/arm/boot/zImage" ] || {
    echo "error: selected kernel has no zImage: $KERNEL_BUILD_DIR" >&2
    exit 1
}

[ -f "$KERNEL_BUILD_DIR/arch/arm/boot/dts/microchip/nextgen.dtb" ] || {
    echo "error: selected kernel has no nextgen.dtb: $KERNEL_BUILD_DIR" >&2
    exit 1
}

if [ -n "${NEXTGEN_AT91BOOTSTRAP:-}" ]; then
    [ -f "$NEXTGEN_AT91BOOTSTRAP" ] || {
        echo "error: selected profile has no AT91Bootstrap image:" >&2
        echo "       $NEXTGEN_AT91BOOTSTRAP" >&2
        exit 1
    }
fi

if [ -n "${NEXTGEN_UBOOT_IMAGE:-}" ]; then
    [ -f "$NEXTGEN_UBOOT_IMAGE" ] || {
        echo "error: selected profile has no U-Boot image:" >&2
        echo "       $NEXTGEN_UBOOT_IMAGE" >&2
        exit 1
    }
fi

if [ "$PROFILE" = "6.18-flash" ]; then
    [ -f "$NEXTGEN_UBOOT_TRAILER" ] || {
        echo "error: flash profile has no U-Boot NOR trailer:" >&2
        echo "       $NEXTGEN_UBOOT_TRAILER" >&2
        exit 1
    }
    [ "$(wc -c < "$NEXTGEN_UBOOT_TRAILER" | tr -d '[:space:]')" -eq 16 ] || {
        echo "error: U-Boot NOR trailer must be exactly 16 bytes" >&2
        exit 1
    }

    for source in \
        "$WORKSPACE/u-boot/build-fast.sh" \
        "$WORKSPACE/u-boot/configs/sama5d27_nextgen_flash_defconfig" \
        "$WORKSPACE/u-boot/arch/arm/dts/sama5d27_nextgen.dts" \
        "$WORKSPACE/u-boot/board/atmel/sama5d27_nextgen/sama5d27_nextgen_flash.env"
    do
        [ ! "$source" -nt "$NEXTGEN_UBOOT_IMAGE" ] || {
            echo "error: flash U-Boot artifact is stale: $NEXTGEN_UBOOT_IMAGE" >&2
            echo "       newer source: $source" >&2
            echo "       rebuild with: ../u-boot/build-fast.sh rebuild flash" >&2
            exit 1
        }
    done

    for source in \
        "$WORKSPACE/at91bootstrap/build-fast.sh" \
        "$WORKSPACE/at91bootstrap/configs/nextgen_nor_uboot_defconfig" \
        "$WORKSPACE/at91bootstrap/driver/spi_flash.c" \
        "$WORKSPACE/at91bootstrap/driver/nextgen_fuse.c" \
        "$WORKSPACE/at91bootstrap/include/nextgen_fuse.h" \
        "$WORKSPACE/at91bootstrap/main.c"
    do
        [ ! "$source" -nt "$NEXTGEN_AT91BOOTSTRAP" ] || {
            echo "error: NOR AT91Bootstrap artifact is stale: $NEXTGEN_AT91BOOTSTRAP" >&2
            echo "       newer source: $source" >&2
            echo "       rebuild with: ../at91bootstrap/build-fast.sh rebuild nor" >&2
            exit 1
        }
    done

    KERNEL_DTS="$WORKSPACE/linux-6.18/arch/arm/boot/dts/microchip/nextgen.dts"
    KERNEL_DTB="$KERNEL_BUILD_DIR/arch/arm/boot/dts/microchip/nextgen.dtb"
    [ ! "$KERNEL_DTS" -nt "$KERNEL_DTB" ] || {
        echo "error: flash profile DTB is stale: $KERNEL_DTB" >&2
        echo "       newer source: $KERNEL_DTS" >&2
        echo "       rebuild the linux-6.18 kernel/DTBs first" >&2
        exit 1
    }

    [ ! "$NEXTGEN_UBOOT_IMAGE" -nt "$NEXTGEN_UBOOT_TRAILER" ] || {
        echo "error: U-Boot NOR trailer is older than u-boot.bin; rebuild the flash profile" >&2
        exit 1
    }
fi

if [ -n "$KERNEL_MODULES_ROOT" ]; then
    [ -d "$KERNEL_MODULES_ROOT/$EXPECTED_KERNEL_RELEASE" ] || {
        echo "error: selected kernel has no staged module tree:" >&2
        echo "       $KERNEL_MODULES_ROOT/$EXPECTED_KERNEL_RELEASE" >&2
        exit 1
    }
fi

if [ "$PROFILE" = "6.18-bringup" ]; then
    grep -a -q 'FUSE: incompatible existing boot fuse; not modified' "$NEXTGEN_AT91BOOTSTRAP" || {
        echo "error: bring-up AT91Bootstrap does not contain the NextGen fuse guard" >&2
        echo "       rebuild at91bootstrap from chatgpt/fuse-burn first" >&2
        exit 1
    }

    [ -r "$KERNEL_BUILD_DIR/.config" ] || {
        echo "error: bring-up kernel has no .config: $KERNEL_BUILD_DIR/.config" >&2
        exit 1
    }
    for sym in MTD_SPI_NOR MTD_SPI_NAND MTD_UBI MTD_UBI_BLOCK UBIFS_FS SQUASHFS \
               DRM DRM_FBDEV_EMULATION DRM_ATMEL_HLCDC VT VT_CONSOLE \
               FRAMEBUFFER_CONSOLE FRAMEBUFFER_CONSOLE_DETECT_PRIMARY
    do
        grep -q "^CONFIG_${sym}=y$" "$KERNEL_BUILD_DIR/.config" || {
            echo "error: bring-up kernel requires CONFIG_${sym}=y" >&2
            echo "       rebuild linux-6.18 with: ./build-fast.sh rebuild bringup" >&2
            exit 1
        }
    done

    [ -f "$NEXTGEN_UBOOT_ENV_TEXT" ] || {
        echo "error: bring-up U-Boot environment is missing: $NEXTGEN_UBOOT_ENV_TEXT" >&2
        exit 1
    }
    grep -q 'console=ttyS0,576000' "$NEXTGEN_UBOOT_ENV_TEXT" ||
        { echo "error: bring-up environment lost the serial console" >&2; exit 1; }
    grep -q 'vt.global_cursor_default=0' "$NEXTGEN_UBOOT_ENV_TEXT" ||
        { echo "error: bring-up environment does not suppress the VT cursor" >&2; exit 1; }
    grep -q 'nextgen.env=bringup' "$NEXTGEN_UBOOT_ENV_TEXT" ||
        { echo "error: bring-up environment is missing nextgen.env=bringup" >&2; exit 1; }
    ! grep -q 'console=tty0' "$NEXTGEN_UBOOT_ENV_TEXT" ||
        { echo "error: bring-up environment must not make LCD a kernel console" >&2; exit 1; }

    for script in \
        board/castle/nextgen/nextgen-bringup-screen \
        board/castle/nextgen/nextgen-bringup.sh \
        board/castle/nextgen/nextgen-provision-storage \
        board/castle/nextgen/S01NextGenBringup \
        board/castle/nextgen/post-build-bringup.sh
    do
        /bin/sh -n "$ROOT/$script" || {
            echo "error: invalid bring-up shell script: $script" >&2
            exit 1
        }
    done
fi

if [ "$STORAGE_SCHEMA" = "ro-persist-v1" ]; then
    [ -r "$KERNEL_BUILD_DIR/.config" ] || {
        echo "error: RO-root kernel has no .config: $KERNEL_BUILD_DIR/.config" >&2
        exit 1
    }
    for sym in BLK_DEV_LOOP SQUASHFS SQUASHFS_LZO; do
        grep -q "^CONFIG_${sym}=y$" "$KERNEL_BUILD_DIR/.config" || {
            echo "error: RO-root kernel requires CONFIG_${sym}=y" >&2
            exit 1
        }
    done
    grep -q '^CONFIG_BLK_DEV_LOOP_MIN_COUNT=4$' "$KERNEL_BUILD_DIR/.config" || {
        echo "error: RO-root kernel requires CONFIG_BLK_DEV_LOOP_MIN_COUNT=4" >&2
        exit 1
    }

    [ -f "$NEXTGEN_UBOOT_ENV_TEXT" ] || {
        echo "error: RO-root U-Boot environment is missing: $NEXTGEN_UBOOT_ENV_TEXT" >&2
        exit 1
    }
    [ -z "${NEXTGEN_UBOOT_ENV:-}" ] || {
        echo "error: RO-root profiles refuse a prebuilt NEXTGEN_UBOOT_ENV override" >&2
        exit 1
    }

    case "$STORAGE_BACKEND" in
        sd-ext4)
            grep -q '^CONFIG_EXT4_FS=y$' "$KERNEL_BUILD_DIR/.config" ||
                { echo "error: SD RO-root kernel requires CONFIG_EXT4_FS=y" >&2; exit 1; }
            grep -q 'root=/dev/mmcblk0p2 rootfstype=squashfs ro rootwait' "$NEXTGEN_UBOOT_ENV_TEXT" ||
                { echo "error: SD RO-root environment does not select SquashFS p2" >&2; exit 1; }
            grep -q 'nextgen.env=sd-ro' "$NEXTGEN_UBOOT_ENV_TEXT" ||
                { echo "error: SD RO-root environment is missing nextgen.env=sd-ro" >&2; exit 1; }
            ;;
        nand-ubi)
            for sym in SPI SPI_ATMEL SPI_ATMEL_QUADSPI MTD MTD_SPI_NAND MTD_UBI MTD_UBI_BLOCK UBIFS_FS UBIFS_FS_LZO; do
                grep -q "^CONFIG_${sym}=y$" "$KERNEL_BUILD_DIR/.config" ||
                    { echo "error: NAND RO-root kernel requires CONFIG_${sym}=y" >&2; exit 1; }
            done
            grep -q 'ubi.mtd=rootfs' "$NEXTGEN_UBOOT_ENV_TEXT" &&
            grep -q 'ubi.block=0,system' "$NEXTGEN_UBOOT_ENV_TEXT" &&
            grep -q 'root=/dev/ubiblock0_0 rootfstype=squashfs ro rootwait' "$NEXTGEN_UBOOT_ENV_TEXT" ||
                { echo "error: production environment does not select system SquashFS ubiblock" >&2; exit 1; }
            grep -q 'nextgen.env=flash' "$NEXTGEN_UBOOT_ENV_TEXT" ||
                { echo "error: production environment is missing nextgen.env=flash" >&2; exit 1; }
            grep -q 'ubi part boot' "$NEXTGEN_UBOOT_ENV_TEXT" &&
            grep -q 'ubi read ${loadaddr} device-tree' "$NEXTGEN_UBOOT_ENV_TEXT" &&
            grep -q 'ubi read ${krnladdr} kernel' "$NEXTGEN_UBOOT_ENV_TEXT" ||
                { echo "error: production environment does not load boot UBI objects" >&2; exit 1; }
            ;;
        *) echo "error: unknown RO storage backend $STORAGE_BACKEND" >&2; exit 1 ;;
    esac

    for script in \
        board/castle/nextgen/persist-init-ro.sh \
        board/castle/nextgen/startup-ro.sh \
        board/castle/nextgen/nextgen-slot-common-ro.sh \
        board/castle/nextgen/nextgen-update-install-ro \
        board/castle/nextgen/nextgen-update-accept-ro \
        board/castle/nextgen/post-build-ro.sh \
        board/castle/nextgen/post-image-ro.sh \
        board/castle/nextgen/verify-target-ro-layout.sh \
        board/castle/nextgen/tests/test-update-state.sh \
        board/castle/nextgen/tests/test-sshd-start.sh \
        board/castle/nextgen/tests/test-usb-identity.sh
    do
        /bin/sh -n "$ROOT/$script" || {
            echo "error: invalid RO-root shell script: $script" >&2
            exit 1
        }
    done
    if [ "$STORAGE_BACKEND" = sd-ext4 ]; then
        /bin/sh -n "$ROOT/board/castle/nextgen/write-sd-card-ro.sh" || exit 1
    else
        for script in board/castle/nextgen/program-nextgen-flash.sh \
                      board/castle/nextgen/make-production-provision-bundle.sh
        do
            /bin/sh -n "$ROOT/$script" || {
                echo "error: invalid production-flash shell script: $script" >&2
                exit 1
            }
        done
    fi

    for test in test-update-state.sh test-sshd-start.sh test-usb-identity.sh; do
        /bin/sh "$ROOT/board/castle/nextgen/tests/$test" || {
            echo "error: RO-root preflight failed: $test" >&2
            exit 1
        }
    done
fi

# Reapply the project defconfig on every profile build so changes to
# module loading and other image policy cannot be hidden by a stale O= tree.
build_product()
{
    product="$1"
    shift

    out="$(nextgen_buildroot_out "$product")"

    make -C "$ROOT" O="$out" "$BUILDROOT_DEFCONFIG"

    if [ "$PROFILE" = "6.18-bringup" ]; then
        if [ -z "${NEXTGEN_PROVISION_BUNDLE_DIR:-}" ]; then
            shared_out="${NEXTGEN_SHARED_BUILDROOT_OUT:-$ROOT/output-nextgen-shared}"
            candidate_bundle="$shared_out/images/production-provision"
            if [ -d "$candidate_bundle" ]; then
                NEXTGEN_PROVISION_BUNDLE_DIR="$candidate_bundle"
                export NEXTGEN_PROVISION_BUNDLE_DIR
            fi
        fi
        for sym in \
            BR2_PACKAGE_MTD \
            BR2_PACKAGE_MTD_MTD_DEBUG \
            BR2_PACKAGE_MTD_FLASH_ERASE \
            BR2_PACKAGE_MTD_UBIFORMAT \
            BR2_PACKAGE_MTD_UBIATTACH \
            BR2_PACKAGE_MTD_UBIDETACH \
            BR2_PACKAGE_MTD_FSCKUBIFS
        do
            grep -q "^$sym=y$" "$out/.config" || {
                echo "error: bring-up image requires $sym=y" >&2
                exit 1
            }
        done
        grep -q 'post-build-bringup.sh' "$out/.config" ||
            { echo "error: bring-up post-build hook is not configured" >&2; exit 1; }
    fi

    if [ "$STORAGE_SCHEMA" = "ro-persist-v1" ]; then
        for sym in \
            BR2_TARGET_ROOTFS_SQUASHFS \
            BR2_TARGET_ROOTFS_SQUASHFS4_LZO \
            BR2_PACKAGE_E2FSPROGS \
            BR2_PACKAGE_MTD \
            BR2_PACKAGE_MTD_FSCKUBIFS \
            BR2_PACKAGE_UTIL_LINUX \
            BR2_PACKAGE_UTIL_LINUX_BINARIES \
            BR2_PACKAGE_UTIL_LINUX_PARTX \
            BR2_PACKAGE_HOST_E2FSPROGS \
            BR2_PACKAGE_HOST_GENIMAGE \
            BR2_PACKAGE_HOST_MTD
        do
            grep -q "^$sym=y$" "$out/.config" || {
                echo "error: RO-root Buildroot config requires $sym=y" >&2
                exit 1
            }
        done
        for sym in BR2_TARGET_GENERIC_REMOUNT_ROOTFS_RW BR2_TARGET_ROOTFS_EXT2 BR2_TARGET_ROOTFS_UBI; do
            if grep -q "^$sym=y$" "$out/.config"; then
                echo "error: RO-root Buildroot config unexpectedly enables $sym" >&2
                exit 1
            fi
        done
    fi

    printf 'NextGen image profile: %s\n' "$PROFILE"
    printf 'NextGen product:       %s\n' "$product"
    printf 'Kernel build:          %s\n' "$KERNEL_BUILD_DIR"
    printf 'Kernel policy:         %s\n' "$KERNEL_PROFILE"
    printf 'Storage schema:        %s\n' "$STORAGE_SCHEMA"
    printf 'Storage backend:       %s\n' "$STORAGE_BACKEND"
    printf 'Buildroot defconfig:   %s\n' "$BUILDROOT_DEFCONFIG"
    printf 'Buildroot output:      %s\n' "$out"
    if [ -n "$KERNEL_MODULES_ROOT" ]; then
        printf 'Kernel modules:        %s\n' "$KERNEL_MODULES_ROOT"
        printf 'Kernel release:        %s\n' "$EXPECTED_KERNEL_RELEASE"
    fi
    if [ "$KERNEL_PROFILE" = "deferred-diag" ]; then
        printf 'Diagnostic U-Boot:     %s\n' "$NEXTGEN_UBOOT_IMAGE"
        printf 'Diagnostic env:        %s\n' "$NEXTGEN_UBOOT_ENV_TEXT"
    fi

    NEXTGEN_PRODUCT="$product" \
    NEXTGEN_KERNEL_BUILD_DIR="$KERNEL_BUILD_DIR" \
    NEXTGEN_KERNEL_MODULES_ROOT="$KERNEL_MODULES_ROOT" \
    NEXTGEN_EXPECTED_KERNEL_RELEASE="$EXPECTED_KERNEL_RELEASE" \
    NEXTGEN_KERNEL_PROFILE="$KERNEL_PROFILE" \
    NEXTGEN_STORAGE_SCHEMA="$STORAGE_SCHEMA" \
    NEXTGEN_STORAGE_BACKEND="$STORAGE_BACKEND" \
        make -C "$ROOT" O="$out" "$@"

    if [ "$PROFILE" = "6.18-nand" ]; then
        [ -f "$out/images/rootfs.ubi" ] || {
            echo "error: NAND-root profile did not produce $out/images/rootfs.ubi" >&2
            exit 1
        }
        printf 'NAND rootfs image:      %s\n' "$out/images/rootfs.ubi"
    fi

    if [ "$PROFILE" = "6.18-flash" ]; then
        for artifact in \
            rootfs.squashfs persist.ubifs boot.ubi rootfs.ubi \
            nor-at91bootstrap.bin nor-uboot.bin nor-uboot-env.bin nor.img \
            program-nextgen-flash.sh nextgen-flash-manifest.sha256
        do
            [ -f "$out/images/$artifact" ] || {
                echo "error: flash profile did not produce $out/images/$artifact" >&2
                exit 1
            }
        done
        for artifact in at91bootstrap.bin u-boot.bin u-boot.trailer boot.ubi rootfs.ubi layout.env manifest.sha256; do
            [ -f "$out/images/production-provision/$artifact" ] || {
                echo "error: production provision bundle is incomplete: $artifact" >&2
                exit 1
            }
        done
        [ "$(wc -c < "$out/images/nor-at91bootstrap.bin")" -eq $((0x8000)) ] ||
            { echo "error: AT91Bootstrap NOR partition image is not 32 KiB" >&2; exit 1; }
        [ "$(wc -c < "$out/images/nor-uboot.bin")" -eq $((0x138000)) ] ||
            { echo "error: U-Boot NOR partition image has wrong size" >&2; exit 1; }
        [ "$(wc -c < "$out/images/nor-uboot-env.bin")" -eq $((0x20000)) ] ||
            { echo "error: U-Boot environment partition image is not 128 KiB" >&2; exit 1; }
        [ "$(wc -c < "$out/images/nor.img")" -eq $((0x200000)) ] ||
            { echo "error: NOR programming image is not 2 MiB" >&2; exit 1; }
        [ "$(wc -c < "$out/images/boot.ubi")" -le $((0x00800000)) ] ||
            { echo "error: boot.ubi exceeds 8 MiB image budget" >&2; exit 1; }
        [ "$(wc -c < "$out/images/rootfs.ubi")" -le $((0x08000000)) ] ||
            { echo "error: rootfs.ubi exceeds 128 MiB partition" >&2; exit 1; }
        (cd "$out/images" && sha256sum -c nextgen-flash-manifest.sha256 >/dev/null) ||
            { echo "error: flash image manifest verification failed" >&2; exit 1; }
        (cd "$out/images/production-provision" && sha256sum -c manifest.sha256 >/dev/null) ||
            { echo "error: provision bundle manifest verification failed" >&2; exit 1; }

        printf 'RO system image:        %s\n' "$out/images/rootfs.squashfs"
        printf 'UBIFS persist seed:     %s\n' "$out/images/persist.ubifs"
        printf 'NAND boot UBI image:   %s\n' "$out/images/boot.ubi"
        printf 'NAND rootfs UBI image: %s\n' "$out/images/rootfs.ubi"
        printf 'NOR programming image: %s\n' "$out/images/nor.img"
        printf 'Provision bundle:      %s\n' "$out/images/production-provision"
    fi

    if [ "$PROFILE" = "6.18-bringup" ]; then
        for artifact in boot.vfat rootfs.ext4 sdcard.img write-sd-card.sh; do
            [ -f "$out/images/$artifact" ] || {
                echo "error: bring-up profile did not produce $out/images/$artifact" >&2
                exit 1
            }
        done
        if [ -n "${NEXTGEN_PROVISION_BUNDLE_DIR:-}" ]; then
            [ -f "$out/target/opt/nextgen/provision/manifest.sha256" ] || {
                echo "error: bring-up rootfs did not stage the production bundle" >&2
                exit 1
            }
        fi
        printf 'Bring-up SD image:      %s\n' "$out/images/sdcard.img"
    fi

    if [ "$PROFILE" = "6.18-ro" ]; then
        for artifact in boot.vfat uboot.env rootfs.squashfs persist.ext4 sdcard.img write-sd-card.sh nextgen-image-manifest.sha256; do
            [ -f "$out/images/$artifact" ] || {
                echo "error: RO-root profile did not produce $out/images/$artifact" >&2
                exit 1
            }
        done
        [ "$(wc -c < "$out/images/uboot.env")" -eq $((0x4000)) ] || {
            echo "error: RO-root uboot.env is not the expected 16 KiB image" >&2
            exit 1
        }
        (cd "$out/images" && sha256sum -c nextgen-image-manifest.sha256 >/dev/null) || {
            echo "error: RO-root image manifest verification failed" >&2
            exit 1
        }
        printf 'RO system image:        %s\n' "$out/images/rootfs.squashfs"
        printf 'Persistent image:       %s\n' "$out/images/persist.ext4"
        printf 'Full SD image:          %s\n' "$out/images/sdcard.img"
        printf 'U-Boot environment:     %s\n' "$out/images/uboot.env"
    fi

    printf 'Built product:          %s\n' "$product"
    printf 'Built kernel profile:   %s\n' "$PROFILE"
    printf 'Profile marker:         /etc/nextgen-kernel-profile\n'
}

case "$PRODUCT" in
    both)
        build_product sound "$@"
        build_product vibra "$@"
        ;;
    sound|vibra)
        build_product "$PRODUCT" "$@"
        ;;
esac
