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
        echo "Usage: $0 [baseline|deferred|deferred-diag|6.18|6.18-diag] [sound|vibra|both] [make-target ...]" >&2
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

    make -C "$ROOT" O="$out" castle_nextgen_dev_defconfig

    printf 'NextGen image profile: %s\n' "$PROFILE"
    printf 'NextGen product:       %s\n' "$product"
    printf 'Kernel build:          %s\n' "$KERNEL_BUILD_DIR"
    printf 'Kernel policy:         %s\n' "$KERNEL_PROFILE"
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
        make -C "$ROOT" O="$out" "$@"

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
