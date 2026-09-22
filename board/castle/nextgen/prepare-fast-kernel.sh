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

"$cfg" --file "$config" -e KERNEL_LZ4
for sym in KERNEL_GZIP KERNEL_LZO KERNEL_LZMA KERNEL_XZ KERNEL_ZSTD; do
    "$cfg" --file "$config" -d "$sym"
done

for sym in MACB KXCJK1013 APDS9306 SENSORS_SHT4X; do
    "$cfg" --file "$config" -d "$sym"
done

CROSS_COMPILE="${CROSS_COMPILE:-}"
OUTPUT_DIR=""
if [ -z "$CROSS_COMPILE" ]; then
    for output in "$BUILDROOT_DIR/output-nextgen" "$BUILDROOT_DIR/output"; do
        prefix="$output/host/bin/arm-buildroot-linux-gnueabihf-"
        if [ -x "${prefix}gcc" ]; then
            CROSS_COMPILE="$prefix"
            OUTPUT_DIR="$output"
            break
        fi
    done
else
    host_bin="$(dirname "${CROSS_COMPILE}gcc")"
    if [ -d "$host_bin" ]; then
        OUTPUT_DIR="$(CDPATH= cd -- "$host_bin/../.." 2>/dev/null && pwd || true)"
    fi
fi

[ -n "$CROSS_COMPILE" ] || {
    echo "error: ARM Buildroot cross compiler not found; set CROSS_COMPILE" >&2
    exit 1
}

if [ -n "$OUTPUT_DIR" ]; then
    make -C "$BUILDROOT_DIR" O="$OUTPUT_DIR" host-lz4
    PATH="$OUTPUT_DIR/host/bin:$PATH"
    export PATH
fi

command -v lz4 >/dev/null 2>&1 || {
    echo "error: host lz4 compressor not found" >&2
    echo "       build Buildroot target host-lz4 or install lz4" >&2
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
