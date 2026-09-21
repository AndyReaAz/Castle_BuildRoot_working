#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BUILDROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE_DIR="$(CDPATH= cd -- "$BUILDROOT_DIR/.." && pwd)"
APP_DIR="${NEXTGEN_APP_DIR:-$WORKSPACE_DIR/app}"

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

stage_required "$BINARIES_DIR/boot.bin"     "${NEXTGEN_AT91BOOTSTRAP:-}"     "$WORKSPACE_DIR/at91bootstrap/build/binaries/boot.bin"     "$WORKSPACE_DIR/at91bootstrap/build/binaries/at91bootstrap.bin"     "$WORKSPACE_DIR/at91bootstrap/binaries/boot.bin"     "$WORKSPACE_DIR/at91bootstrap/binaries/at91bootstrap.bin"

stage_required "$BINARIES_DIR/u-boot.bin"     "${NEXTGEN_UBOOT_IMAGE:-}"     "$WORKSPACE_DIR/u-boot/u-boot.bin"

stage_required "$BINARIES_DIR/zImage"     "${NEXTGEN_KERNEL_IMAGE:-}"     "$WORKSPACE_DIR/linux-at91/arch/arm/boot/zImage"

stage_required "$BINARIES_DIR/nextgen.dtb"     "${NEXTGEN_DTB_IMAGE:-}"     "$WORKSPACE_DIR/linux-at91/arch/arm/boot/dts/microchip/nextgen.dtb"     "$WORKSPACE_DIR/linux-at91/arch/arm/boot/dts/nextgen.dtb"

# uboot.env is persistent product state as well as boot configuration.
# Prefer a maintained U-Boot/workspace copy.  The DeviceScripts copy is only
# a migration fallback until the environment source is converted to text.
UBOOT_ENV_SOURCE=""
for source in     "${NEXTGEN_UBOOT_ENV:-}"     "$WORKSPACE_DIR/u-boot/uboot.env"     "$WORKSPACE_DIR/u-boot/u-boot.env"     "$WORKSPACE_DIR/Binaries/uboot.env"     "$APP_DIR/DeviceScripts/boot/uboot.env"
do
    [ -n "$source" ] || continue
    if [ -f "$source" ]; then
        UBOOT_ENV_SOURCE="$source"
        break
    fi
done

if [ -z "$UBOOT_ENV_SOURCE" ]; then
    echo "error: cannot find uboot.env; set NEXTGEN_UBOOT_ENV" >&2
    exit 1
fi

if [ "$UBOOT_ENV_SOURCE" = "$APP_DIR/DeviceScripts/boot/uboot.env" ]; then
    echo "warning: using legacy DeviceScripts/boot/uboot.env; migrate this to a maintained U-Boot environment source" >&2
fi
install -m 0644 "$UBOOT_ENV_SOURCE" "$BINARIES_DIR/uboot.env"
printf 'NextGen boot: %-12s <- %s\n' "uboot.env" "$UBOOT_ENV_SOURCE"

BOOT_IMAGE="$BINARIES_DIR/boot.vfat"
BOOT_SIZE_MIB="${NEXTGEN_BOOT_SIZE_MIB:-16}"

rm -f "$BOOT_IMAGE"
truncate -s "${BOOT_SIZE_MIB}M" "$BOOT_IMAGE"
"$HOST_DIR/sbin/mkfs.vfat" -n NEXTGEN "$BOOT_IMAGE" >/dev/null

for file in boot.bin u-boot.bin uboot.env zImage nextgen.dtb; do
    "$HOST_DIR/bin/mcopy" -o -i "$BOOT_IMAGE" "$BINARIES_DIR/$file" "::/$file"
done

(
    cd "$BINARIES_DIR"
    sha256sum boot.bin u-boot.bin uboot.env zImage nextgen.dtb rootfs.ext4         > nextgen-image-manifest.sha256
)

install -m 0755 "$SCRIPT_DIR/write-sd-card.sh" "$BINARIES_DIR/write-sd-card.sh"

echo "NextGen boot FAT image: $BOOT_IMAGE"
echo "NextGen SD writer:      $BINARIES_DIR/write-sd-card.sh"
