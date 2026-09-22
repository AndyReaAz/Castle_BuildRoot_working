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

stage_required "$BINARIES_DIR/zImage"     "${NEXTGEN_KERNEL_IMAGE:-}"     "$WORKSPACE_DIR/linux-at91/arch/arm/boot/zImage"

stage_required "$BINARIES_DIR/nextgen.dtb"     "${NEXTGEN_DTB_IMAGE:-}"     "$WORKSPACE_DIR/linux-at91/arch/arm/boot/dts/microchip/nextgen.dtb"     "$WORKSPACE_DIR/linux-at91/arch/arm/boot/dts/nextgen.dtb"

# Do not seed a fresh SD image with a saved U-Boot environment.  Current
# U-Boot defaults deliberately create/save the environment on first boot
# (env_saved guard in bootcmd).  Copying an old uboot.env here can override
# newer compiled bootcmd/bootcmd_mmc definitions indefinitely.
#
# An environment may still be explicitly preseeded for a special image by
# setting NEXTGEN_UBOOT_ENV, but there is intentionally no repository fallback.
UBOOT_ENV_SOURCE="${NEXTGEN_UBOOT_ENV:-}"
rm -f "$BINARIES_DIR/uboot.env"
if [ -n "$UBOOT_ENV_SOURCE" ]; then
    [ -f "$UBOOT_ENV_SOURCE" ] || {
        echo "error: NEXTGEN_UBOOT_ENV does not exist: $UBOOT_ENV_SOURCE" >&2
        exit 1
    }
    install -m 0644 "$UBOOT_ENV_SOURCE" "$BINARIES_DIR/uboot.env"
    printf 'NextGen boot: %-12s <- %s\n' "uboot.env" "$UBOOT_ENV_SOURCE"
fi

BOOT_IMAGE="$BINARIES_DIR/boot.vfat"
BOOT_SIZE_MIB="${NEXTGEN_BOOT_SIZE_MIB:-16}"
rm -f "$BOOT_IMAGE"
truncate -s "${BOOT_SIZE_MIB}M" "$BOOT_IMAGE"
"$HOST_DIR/sbin/mkfs.vfat" -n NEXTGEN "$BOOT_IMAGE" >/dev/null

for file in boot.bin u-boot.bin zImage nextgen.dtb; do
    "$HOST_DIR/bin/mcopy" -o -i "$BOOT_IMAGE" "$BINARIES_DIR/$file" "::/$file"
done
if [ -f "$BINARIES_DIR/uboot.env" ]; then
    "$HOST_DIR/bin/mcopy" -o -i "$BOOT_IMAGE" "$BINARIES_DIR/uboot.env" "::/uboot.env"
fi

# Fast-boot U-Boot no longer displays a bitmap and the application owns the splash.

# Transitional complete SD-boot image:
# p1 FAT boot, p2 ext4 rootfs, p3 ext4 meter data.
# The application requires the legacy data partition to be larger than 4 GiB.
DATA_IMAGE="$BINARIES_DIR/data.ext4"
DATA_IMAGE_SIZE="${NEXTGEN_DATA_IMAGE_SIZE:-5G}"

rm -f "$DATA_IMAGE" "$BINARIES_DIR/sdcard.img"
truncate -s "$DATA_IMAGE_SIZE" "$DATA_IMAGE"
"$HOST_DIR/sbin/mkfs.ext4" -F -L data -m 0 "$DATA_IMAGE" >/dev/null

"$BUILDROOT_DIR/support/scripts/genimage.sh" -c "$SCRIPT_DIR/genimage.cfg"

(
    cd "$BINARIES_DIR"
    sha256sum boot.bin u-boot.bin zImage nextgen.dtb \
        rootfs.ext4 > nextgen-image-manifest.sha256
    if [ -f uboot.env ]; then
        sha256sum uboot.env >> nextgen-image-manifest.sha256
    fi
)

install -m 0755 "$SCRIPT_DIR/write-sd-card.sh" "$BINARIES_DIR/write-sd-card.sh"

echo "NextGen boot FAT image: $BOOT_IMAGE"
echo "NextGen full SD image:  $BINARIES_DIR/sdcard.img"
echo "NextGen SD writer:      $BINARIES_DIR/write-sd-card.sh"
