#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BUILDROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE_DIR="$(CDPATH= cd -- "$BUILDROOT_DIR/.." && pwd)"

: "${BINARIES_DIR:?Buildroot did not provide BINARIES_DIR}"
: "${HOST_DIR:?Buildroot did not provide HOST_DIR}"

stage_required()
{
    destination="$1"
    shift

    for source in "$@"; do
        [ -n "$source" ] || continue
        if [ -f "$source" ]; then
            install -m 0644 "$source" "$destination"
            printf 'NextGen boot: %-12s <- %s\n' "$(basename "$destination")" "$source"
            return 0
        fi
    done

    echo "error: cannot find required NextGen boot artifact $(basename "$destination")" >&2
    return 1
}

SD_BOOTSTRAP="${NEXTGEN_AT91BOOTSTRAP:-}"
if [ -z "$SD_BOOTSTRAP" ]; then
    for candidate in "$WORKSPACE_DIR"/at91bootstrap/build/binaries/sama5d2-sdcardboot-uboot-*.bin; do
        [ -f "$candidate" ] || continue
        SD_BOOTSTRAP="$candidate"
    done
fi

[ -n "$SD_BOOTSTRAP" ] || {
    echo "error: no SD-card AT91Bootstrap image found; build the sdcardboot configuration or set NEXTGEN_AT91BOOTSTRAP" >&2
    exit 1
}

stage_required "$BINARIES_DIR/boot.bin" "$SD_BOOTSTRAP"
stage_required "$BINARIES_DIR/u-boot.bin" \
    "${NEXTGEN_UBOOT_IMAGE:-}" \
    "$WORKSPACE_DIR/u-boot/build-fast/u-boot.bin" \
    "$WORKSPACE_DIR/u-boot/u-boot.bin"
stage_required "$BINARIES_DIR/zImage" \
    "${NEXTGEN_KERNEL_IMAGE:-}" \
    "$WORKSPACE_DIR/linux-at91/arch/arm/boot/zImage"
stage_required "$BINARIES_DIR/nextgen.dtb" \
    "${NEXTGEN_DTB_IMAGE:-}" \
    "$WORKSPACE_DIR/linux-at91/arch/arm/boot/dts/microchip/nextgen.dtb" \
    "$WORKSPACE_DIR/linux-at91/arch/arm/boot/dts/nextgen.dtb"

UBOOT_ENV_SOURCE="${NEXTGEN_UBOOT_ENV:-}"
UBOOT_ENV_TEXT="${NEXTGEN_UBOOT_ENV_TEXT:-$WORKSPACE_DIR/u-boot/board/atmel/sama5d27_nextgen/sama5d27_nextgen.env}"
MKENVIMAGE="${NEXTGEN_MKENVIMAGE:-$WORKSPACE_DIR/u-boot/tools/mkenvimage}"

rm -f "$BINARIES_DIR/uboot.env"
if [ -n "$UBOOT_ENV_SOURCE" ]; then
    [ -f "$UBOOT_ENV_SOURCE" ] || {
        echo "error: NEXTGEN_UBOOT_ENV does not exist: $UBOOT_ENV_SOURCE" >&2
        exit 1
    }
    install -m 0644 "$UBOOT_ENV_SOURCE" "$BINARIES_DIR/uboot.env"
    printf 'NextGen boot: %-12s <- %s\n' "uboot.env" "$UBOOT_ENV_SOURCE"
else
    [ -f "$UBOOT_ENV_TEXT" ] || {
        echo "error: U-Boot environment source does not exist: $UBOOT_ENV_TEXT" >&2
        exit 1
    }
    grep -q '^bootdelay=-2$' "$UBOOT_ENV_TEXT" || {
        echo "error: U-Boot environment is not the fast-boot profile" >&2
        exit 1
    }
    [ -x "$MKENVIMAGE" ] || {
        echo "error: mkenvimage is not available: $MKENVIMAGE" >&2
        echo "       build U-Boot first or set NEXTGEN_MKENVIMAGE" >&2
        exit 1
    }
    "$MKENVIMAGE" -s 0x4000 -o "$BINARIES_DIR/uboot.env" "$UBOOT_ENV_TEXT"
    printf 'NextGen boot: %-12s <- %s\n' "uboot.env" "$UBOOT_ENV_TEXT"
fi

BOOT_IMAGE="$BINARIES_DIR/boot.vfat"
BOOT_SIZE_MIB="${NEXTGEN_BOOT_SIZE_MIB:-16}"

rm -f "$BOOT_IMAGE"
truncate -s "${BOOT_SIZE_MIB}M" "$BOOT_IMAGE"
"$HOST_DIR/sbin/mkfs.vfat" -n NEXTGEN "$BOOT_IMAGE" >/dev/null

for file in boot.bin u-boot.bin zImage nextgen.dtb uboot.env; do
    "$HOST_DIR/bin/mcopy" -o -i "$BOOT_IMAGE" "$BINARIES_DIR/$file" "::/$file"
done

# Fast-boot U-Boot is intentionally headless. Linux owns display initialisation
# and the early application owns the splash.

DATA_IMAGE="$BINARIES_DIR/data.ext4"
DATA_IMAGE_SIZE="${NEXTGEN_DATA_IMAGE_SIZE:-5G}"

rm -f "$DATA_IMAGE" "$BINARIES_DIR/sdcard.img"
truncate -s "$DATA_IMAGE_SIZE" "$DATA_IMAGE"
"$HOST_DIR/sbin/mkfs.ext4" -F -L data -m 0 "$DATA_IMAGE" >/dev/null

"$BUILDROOT_DIR/support/scripts/genimage.sh" -c "$SCRIPT_DIR/genimage.cfg"

(
    cd "$BINARIES_DIR"
    sha256sum boot.bin u-boot.bin zImage nextgen.dtb uboot.env \
        rootfs.ext4 > nextgen-image-manifest.sha256
)

install -m 0755 "$SCRIPT_DIR/write-sd-card.sh" "$BINARIES_DIR/write-sd-card.sh"

echo "NextGen boot FAT image: $BOOT_IMAGE"
echo "NextGen full SD image:  $BINARIES_DIR/sdcard.img"
echo "NextGen SD writer:      $BINARIES_DIR/write-sd-card.sh"
