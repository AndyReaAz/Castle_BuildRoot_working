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
    *)
        echo "Usage: $0 [baseline|deferred] [make-target ...]" >&2
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

NEXTGEN_KERNEL_BUILD_DIR="$KERNEL_BUILD_DIR" \
NEXTGEN_KERNEL_PROFILE="$PROFILE" \
    make -C "$ROOT" O="$OUT" "$@"

printf 'Built kernel profile:   %s\n' "$PROFILE"
printf 'Profile marker:         /etc/nextgen-kernel-profile\n'
