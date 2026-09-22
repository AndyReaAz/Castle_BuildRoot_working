#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BUILDROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE_DIR="$(CDPATH= cd -- "$BUILDROOT_DIR/.." && pwd)"
KERNEL_DIR="${NEXTGEN_KERNEL_DIR:-$WORKSPACE_DIR/linux-at91}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

[ -x "$KERNEL_DIR/scripts/config" ] || {
    echo "error: kernel scripts/config not found in $KERNEL_DIR" >&2
    exit 1
}
[ -f "$KERNEL_DIR/.config" ] || {
    echo "error: kernel .config not found in $KERNEL_DIR" >&2
    exit 1
}

cfg="$KERNEL_DIR/scripts/config"
config="$KERNEL_DIR/.config"

# Fastest practical ARM zImage decompression on the current SAMA5D27 target.
"$cfg" --file "$config" -e KERNEL_LZ4
for sym in KERNEL_GZIP KERNEL_LZO KERNEL_LZMA KERNEL_XZ KERNEL_ZSTD; do
    "$cfg" --file "$config" -d "$sym"
done

# Known unused drivers already identified on the boot-split branch.  These are
# deliberately conservative; ADC/audio/display/touch/WILC paths are left alone.
for sym in MACB KXCJK1013 APDS9306 SENSORS_SHT4X; do
    "$cfg" --file "$config" -d "$sym"
done

CROSS_COMPILE="${CROSS_COMPILE:-}"
if [ -z "$CROSS_COMPILE" ]; then
    for prefix in         "$BUILDROOT_DIR/output-nextgen/host/bin/arm-buildroot-linux-gnueabihf-"         "$BUILDROOT_DIR/output/host/bin/arm-buildroot-linux-gnueabihf-"
    do
        if [ -x "${prefix}gcc" ]; then
            CROSS_COMPILE="$prefix"
            break
        fi
    done
fi

[ -n "$CROSS_COMPILE" ] || {
    echo "error: ARM Buildroot cross compiler not found; set CROSS_COMPILE" >&2
    exit 1
}

make -C "$KERNEL_DIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
make -C "$KERNEL_DIR" -j"$JOBS" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" zImage dtbs

grep -q '^CONFIG_KERNEL_LZ4=y$' "$config"

echo "Fast-boot kernel ready:"
echo "  $KERNEL_DIR/arch/arm/boot/zImage"
if [ -f "$KERNEL_DIR/arch/arm/boot/dts/microchip/nextgen.dtb" ]; then
    echo "  $KERNEL_DIR/arch/arm/boot/dts/microchip/nextgen.dtb"
else
    echo "  $KERNEL_DIR/arch/arm/boot/dts/nextgen.dtb"
fi
