#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
WORKSPACE="$(CDPATH= cd -- "$ROOT/.." && pwd)"
OUT="${NEXTGEN_BUILDROOT_OUT:-$ROOT/output-nextgen}"
PROFILE="${1:-baseline}"

case "$PROFILE" in
    baseline)
        KERNEL_BUILD_DIR="$WORKSPACE/linux-working/build-fast"
        ;;
    deferred)
        KERNEL_BUILD_DIR="$WORKSPACE/linux-working/build-fast-deferred"
        ;;
    deferred-diag)
        KERNEL_BUILD_DIR="$WORKSPACE/linux-working/build-fast-deferred"
        NEXTGEN_UBOOT_IMAGE="$WORKSPACE/u-boot/build-diag/u-boot.bin"
        NEXTGEN_MKENVIMAGE="$WORKSPACE/u-boot/build-diag/tools/mkenvimage"
        NEXTGEN_UBOOT_ENV_TEXT="$WORKSPACE/u-boot/board/atmel/sama5d27_nextgen/sama5d27_nextgen_diag.env"
        export NEXTGEN_UBOOT_IMAGE NEXTGEN_MKENVIMAGE NEXTGEN_UBOOT_ENV_TEXT
        ;;
    *)
        echo "Usage: $0 [baseline|deferred|deferred-diag] [make-target ...]" >&2
        exit 2
        ;;
esac
shift || true

[ -f "$KERNEL_BUILD_DIR/arch/arm/boot/zImage" ] || {
    echo "error: selected kernel has no zImage: $KERNEL_BUILD_DIR" >&2
    exit 1
}

[ -f "$KERNEL_BUILD_DIR/arch/arm/boot/dts/microchip/nextgen.dtb" ] || {
    echo "error: selected kernel has no nextgen.dtb: $KERNEL_BUILD_DIR" >&2
    exit 1
}

# Reapply the project defconfig on every profile build so changes to
# module loading and other image policy cannot be hidden by a stale O= tree.
make -C "$ROOT" O="$OUT" castle_nextgen_dev_defconfig

printf 'NextGen image profile: %s\n' "$PROFILE"
printf 'Kernel build:          %s\n' "$KERNEL_BUILD_DIR"
printf 'Buildroot output:      %s\n' "$OUT"
if [ "$PROFILE" = "deferred-diag" ]; then
    printf 'Diagnostic U-Boot:     %s\n' "$NEXTGEN_UBOOT_IMAGE"
    printf 'Diagnostic env:        %s\n' "$NEXTGEN_UBOOT_ENV_TEXT"
fi

NEXTGEN_KERNEL_BUILD_DIR="$KERNEL_BUILD_DIR" \
NEXTGEN_KERNEL_PROFILE="$PROFILE" \
    make -C "$ROOT" O="$OUT" "$@"

printf 'Built kernel profile:   %s\n' "$PROFILE"
printf 'Profile marker:         /etc/nextgen-kernel-profile\n'
