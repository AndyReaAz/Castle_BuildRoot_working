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
        NEXTGEN_AT91BOOTSTRAP="$WORKSPACE/at91bootstrap/build-sd/binaries/boot.bin"
        NEXTGEN_UBOOT_IMAGE="$WORKSPACE/u-boot/build-fast/u-boot.bin"
        NEXTGEN_MKENVIMAGE="$WORKSPACE/u-boot/build-fast/tools/mkenvimage"
        NEXTGEN_UBOOT_ENV_TEXT="$WORKSPACE/u-boot/board/atmel/sama5d27_nextgen/sama5d27_nextgen_ro.env"
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
        echo "Usage: $0 [baseline|deferred|deferred-diag|6.18|6.18-ro|6.18-nand|6.18-diag] [sound|vibra|both] [make-target ...]" >&2
        exit 2
        ;;
esac

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

if [ -n "$KERNEL_MODULES_ROOT" ]; then
    [ -d "$KERNEL_MODULES_ROOT/$EXPECTED_KERNEL_RELEASE" ] || {
        echo "error: selected kernel has no staged module tree:" >&2
        echo "       $KERNEL_MODULES_ROOT/$EXPECTED_KERNEL_RELEASE" >&2
        exit 1
    }
fi

if [ "$PROFILE" = "6.18-ro" ]; then
    [ -r "$KERNEL_BUILD_DIR/.config" ] || {
        echo "error: RO-root kernel has no .config: $KERNEL_BUILD_DIR/.config" >&2
        exit 1
    }
    for sym in EXT4_FS BLK_DEV_LOOP SQUASHFS SQUASHFS_LZO; do
        grep -q "^CONFIG_${sym}=y$" "$KERNEL_BUILD_DIR/.config" || {
            echo "error: RO-root kernel requires CONFIG_${sym}=y" >&2
            echo "       rebuild linux-6.18 from chatgpt/ro-root-image-slots first" >&2
            exit 1
        }
    done
    grep -q '^CONFIG_BLK_DEV_LOOP_MIN_COUNT=4$' "$KERNEL_BUILD_DIR/.config" || {
        echo "error: RO-root kernel requires CONFIG_BLK_DEV_LOOP_MIN_COUNT=4" >&2
        echo "       rebuild linux-6.18 from chatgpt/ro-root-image-slots first" >&2
        exit 1
    }
    [ -f "$NEXTGEN_UBOOT_ENV_TEXT" ] || {
        echo "error: RO-root U-Boot environment is missing:" >&2
        echo "       $NEXTGEN_UBOOT_ENV_TEXT" >&2
        exit 1
    }
    [ -z "${NEXTGEN_UBOOT_ENV:-}" ] || {
        echo "error: RO-root profile refuses a prebuilt NEXTGEN_UBOOT_ENV override" >&2
        echo "       the environment must be generated from the validated RO text source" >&2
        exit 1
    }
    grep -q 'root=/dev/mmcblk0p2 rootfstype=squashfs ro rootwait' "$NEXTGEN_UBOOT_ENV_TEXT" || {
        echo "error: RO-root U-Boot environment does not select read-only SquashFS p2" >&2
        exit 1
    }
    grep -q 'nextgen.env=sd-ro' "$NEXTGEN_UBOOT_ENV_TEXT" || {
        echo "error: RO-root U-Boot environment is missing nextgen.env=sd-ro" >&2
        exit 1
    }

    for script in \
        board/castle/nextgen/persist-init-ro.sh \
        board/castle/nextgen/startup-ro.sh \
        board/castle/nextgen/nextgen-slot-common-ro.sh \
        board/castle/nextgen/nextgen-update-install-ro \
        board/castle/nextgen/nextgen-update-accept-ro \
        board/castle/nextgen/post-build-ro.sh \
        board/castle/nextgen/post-image-ro.sh \
        board/castle/nextgen/verify-target-ro-layout.sh \
        board/castle/nextgen/write-sd-card-ro.sh \
        board/castle/nextgen/tests/test-update-state.sh \
        board/castle/nextgen/tests/test-sshd-start.sh \
        board/castle/nextgen/tests/test-usb-identity.sh
    do
        /bin/sh -n "$ROOT/$script" || {
            echo "error: invalid RO-root shell script: $script" >&2
            exit 1
        }
    done

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

    if [ -n "${NEXTGEN_BUILDROOT_OUT:-}" ]; then
        out="$NEXTGEN_BUILDROOT_OUT"
    elif [ "$PRODUCT_EXPLICIT" -eq 1 ]; then
        out="$ROOT/output-nextgen-$product"
    else
        # Preserve the historical no-product invocation for old workflows.
        out="$ROOT/output-nextgen"
    fi

    make -C "$ROOT" O="$out" "$BUILDROOT_DEFCONFIG"

    if [ "$PROFILE" = "6.18-ro" ]; then
        for sym in \
            BR2_TARGET_ROOTFS_SQUASHFS \
            BR2_TARGET_ROOTFS_SQUASHFS4_LZO \
            BR2_PACKAGE_E2FSPROGS \
            BR2_PACKAGE_UTIL_LINUX \
            BR2_PACKAGE_UTIL_LINUX_BINARIES \
            BR2_PACKAGE_UTIL_LINUX_PARTX \
            BR2_PACKAGE_HOST_E2FSPROGS \
            BR2_PACKAGE_HOST_GENIMAGE
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
        make -C "$ROOT" O="$out" "$@"

    if [ "$PROFILE" = "6.18-nand" ]; then
        [ -f "$out/images/rootfs.ubi" ] || {
            echo "error: NAND-root profile did not produce $out/images/rootfs.ubi" >&2
            exit 1
        }
        printf 'NAND rootfs image:      %s\n' "$out/images/rootfs.ubi"
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
 "$KERNEL_BUILD_DIR/.config" || {
        echo "error: RO-root kernel requires CONFIG_BLK_DEV_LOOP_MIN_COUNT=4" >&2
        exit 1
    }
    [ -f "$NEXTGEN_UBOOT_ENV_TEXT" ] || {
        echo "error: RO-root U-Boot environment is missing:" >&2
        echo "       $NEXTGEN_UBOOT_ENV_TEXT" >&2
        exit 1
    }
    [ -z "${NEXTGEN_UBOOT_ENV:-}" ] || {
        echo "error: RO-root profile refuses a prebuilt NEXTGEN_UBOOT_ENV override" >&2
        echo "       the environment must be generated from the validated RO text source" >&2
        exit 1
    }
    grep -q 'root=/dev/mmcblk0p2 rootfstype=squashfs ro rootwait' "$NEXTGEN_UBOOT_ENV_TEXT" || {
        echo "error: RO-root U-Boot environment does not select read-only SquashFS p2" >&2
        exit 1
    }
    grep -q 'nextgen.env=sd-ro' "$NEXTGEN_UBOOT_ENV_TEXT" || {
        echo "error: RO-root U-Boot environment is missing nextgen.env=sd-ro" >&2
        exit 1
    }

    for script in \
        board/castle/nextgen/persist-init-ro.sh \
        board/castle/nextgen/startup-ro.sh \
        board/castle/nextgen/nextgen-slot-common-ro.sh \
        board/castle/nextgen/nextgen-update-install-ro \
        board/castle/nextgen/nextgen-update-accept-ro \
        board/castle/nextgen/post-build-ro.sh \
        board/castle/nextgen/post-image-ro.sh \
        board/castle/nextgen/verify-target-ro-layout.sh \
        board/castle/nextgen/write-sd-card-ro.sh \
        board/castle/nextgen/tests/test-update-state.sh \
        board/castle/nextgen/tests/test-sshd-start.sh \
        board/castle/nextgen/tests/test-usb-identity.sh
    do
        /bin/sh -n "$ROOT/$script" || {
            echo "error: invalid RO-root shell script: $script" >&2
            exit 1
        }
    done

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

    if [ -n "${NEXTGEN_BUILDROOT_OUT:-}" ]; then
        out="$NEXTGEN_BUILDROOT_OUT"
    elif [ "$PRODUCT_EXPLICIT" -eq 1 ]; then
        out="$ROOT/output-nextgen-$product"
    else
        # Preserve the historical no-product invocation for old workflows.
        out="$ROOT/output-nextgen"
    fi

    make -C "$ROOT" O="$out" "$BUILDROOT_DEFCONFIG"

    if [ "$PROFILE" = "6.18-ro" ]; then
        for sym in \
            BR2_TARGET_ROOTFS_SQUASHFS \
            BR2_TARGET_ROOTFS_SQUASHFS4_LZO \
            BR2_PACKAGE_E2FSPROGS \
            BR2_PACKAGE_HOST_E2FSPROGS \
            BR2_PACKAGE_HOST_GENIMAGE
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
        make -C "$ROOT" O="$out" "$@"

    if [ "$PROFILE" = "6.18-nand" ]; then
        [ -f "$out/images/rootfs.ubi" ] || {
            echo "error: NAND-root profile did not produce $out/images/rootfs.ubi" >&2
            exit 1
        }
        printf 'NAND rootfs image:      %s\n' "$out/images/rootfs.ubi"
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
 "$KERNEL_BUILD_DIR/.config" || {
        echo "error: RO-root kernel requires CONFIG_BLK_DEV_LOOP_MIN_COUNT=4" >&2
        echo "       rebuild linux-6.18 from chatgpt/ro-root-image-slots first" >&2
        exit 1
    }
    [ -f "$NEXTGEN_UBOOT_ENV_TEXT" ] || {
        echo "error: RO-root U-Boot environment is missing:" >&2
        echo "       $NEXTGEN_UBOOT_ENV_TEXT" >&2
        exit 1
    }
    [ -z "${NEXTGEN_UBOOT_ENV:-}" ] || {
        echo "error: RO-root profile refuses a prebuilt NEXTGEN_UBOOT_ENV override" >&2
        echo "       the environment must be generated from the validated RO text source" >&2
        exit 1
    }
    grep -q 'root=/dev/mmcblk0p2 rootfstype=squashfs ro rootwait' "$NEXTGEN_UBOOT_ENV_TEXT" || {
        echo "error: RO-root U-Boot environment does not select read-only SquashFS p2" >&2
        exit 1
    }
    grep -q 'nextgen.env=sd-ro' "$NEXTGEN_UBOOT_ENV_TEXT" || {
        echo "error: RO-root U-Boot environment is missing nextgen.env=sd-ro" >&2
        exit 1
    }

    for script in \
        board/castle/nextgen/persist-init-ro.sh \
        board/castle/nextgen/startup-ro.sh \
        board/castle/nextgen/nextgen-slot-common-ro.sh \
        board/castle/nextgen/nextgen-update-install-ro \
        board/castle/nextgen/nextgen-update-accept-ro \
        board/castle/nextgen/post-build-ro.sh \
        board/castle/nextgen/post-image-ro.sh \
        board/castle/nextgen/verify-target-ro-layout.sh \
        board/castle/nextgen/write-sd-card-ro.sh \
        board/castle/nextgen/tests/test-update-state.sh \
        board/castle/nextgen/tests/test-sshd-start.sh \
        board/castle/nextgen/tests/test-usb-identity.sh
    do
        /bin/sh -n "$ROOT/$script" || {
            echo "error: invalid RO-root shell script: $script" >&2
            exit 1
        }
    done

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

    if [ -n "${NEXTGEN_BUILDROOT_OUT:-}" ]; then
        out="$NEXTGEN_BUILDROOT_OUT"
    elif [ "$PRODUCT_EXPLICIT" -eq 1 ]; then
        out="$ROOT/output-nextgen-$product"
    else
        # Preserve the historical no-product invocation for old workflows.
        out="$ROOT/output-nextgen"
    fi

    make -C "$ROOT" O="$out" "$BUILDROOT_DEFCONFIG"

    if [ "$PROFILE" = "6.18-ro" ]; then
        for sym in \
            BR2_TARGET_ROOTFS_SQUASHFS \
            BR2_TARGET_ROOTFS_SQUASHFS4_LZO \
            BR2_PACKAGE_E2FSPROGS \
            BR2_PACKAGE_UTIL_LINUX \
            BR2_PACKAGE_UTIL_LINUX_BINARIES \
            BR2_PACKAGE_UTIL_LINUX_PARTX \
            BR2_PACKAGE_HOST_E2FSPROGS \
            BR2_PACKAGE_HOST_GENIMAGE
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
        make -C "$ROOT" O="$out" "$@"

    if [ "$PROFILE" = "6.18-nand" ]; then
        [ -f "$out/images/rootfs.ubi" ] || {
            echo "error: NAND-root profile did not produce $out/images/rootfs.ubi" >&2
            exit 1
        }
        printf 'NAND rootfs image:      %s\n' "$out/images/rootfs.ubi"
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
 "$KERNEL_BUILD_DIR/.config" || {
        echo "error: RO-root kernel requires CONFIG_BLK_DEV_LOOP_MIN_COUNT=4" >&2
        exit 1
    }
    [ -f "$NEXTGEN_UBOOT_ENV_TEXT" ] || {
        echo "error: RO-root U-Boot environment is missing:" >&2
        echo "       $NEXTGEN_UBOOT_ENV_TEXT" >&2
        exit 1
    }
    [ -z "${NEXTGEN_UBOOT_ENV:-}" ] || {
        echo "error: RO-root profile refuses a prebuilt NEXTGEN_UBOOT_ENV override" >&2
        echo "       the environment must be generated from the validated RO text source" >&2
        exit 1
    }
    grep -q 'root=/dev/mmcblk0p2 rootfstype=squashfs ro rootwait' "$NEXTGEN_UBOOT_ENV_TEXT" || {
        echo "error: RO-root U-Boot environment does not select read-only SquashFS p2" >&2
        exit 1
    }
    grep -q 'nextgen.env=sd-ro' "$NEXTGEN_UBOOT_ENV_TEXT" || {
        echo "error: RO-root U-Boot environment is missing nextgen.env=sd-ro" >&2
        exit 1
    }

    for script in \
        board/castle/nextgen/persist-init-ro.sh \
        board/castle/nextgen/startup-ro.sh \
        board/castle/nextgen/nextgen-slot-common-ro.sh \
        board/castle/nextgen/nextgen-update-install-ro \
        board/castle/nextgen/nextgen-update-accept-ro \
        board/castle/nextgen/post-build-ro.sh \
        board/castle/nextgen/post-image-ro.sh \
        board/castle/nextgen/verify-target-ro-layout.sh \
        board/castle/nextgen/write-sd-card-ro.sh \
        board/castle/nextgen/tests/test-update-state.sh \
        board/castle/nextgen/tests/test-sshd-start.sh \
        board/castle/nextgen/tests/test-usb-identity.sh
    do
        /bin/sh -n "$ROOT/$script" || {
            echo "error: invalid RO-root shell script: $script" >&2
            exit 1
        }
    done

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

    if [ -n "${NEXTGEN_BUILDROOT_OUT:-}" ]; then
        out="$NEXTGEN_BUILDROOT_OUT"
    elif [ "$PRODUCT_EXPLICIT" -eq 1 ]; then
        out="$ROOT/output-nextgen-$product"
    else
        # Preserve the historical no-product invocation for old workflows.
        out="$ROOT/output-nextgen"
    fi

    make -C "$ROOT" O="$out" "$BUILDROOT_DEFCONFIG"

    if [ "$PROFILE" = "6.18-ro" ]; then
        for sym in \
            BR2_TARGET_ROOTFS_SQUASHFS \
            BR2_TARGET_ROOTFS_SQUASHFS4_LZO \
            BR2_PACKAGE_E2FSPROGS \
            BR2_PACKAGE_HOST_E2FSPROGS \
            BR2_PACKAGE_HOST_GENIMAGE
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
        make -C "$ROOT" O="$out" "$@"

    if [ "$PROFILE" = "6.18-nand" ]; then
        [ -f "$out/images/rootfs.ubi" ] || {
            echo "error: NAND-root profile did not produce $out/images/rootfs.ubi" >&2
            exit 1
        }
        printf 'NAND rootfs image:      %s\n' "$out/images/rootfs.ubi"
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
