#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BUILDROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE_DIR="$(CDPATH= cd -- "$BUILDROOT_DIR/.." && pwd)"
KERNEL_BUILD_DIR="${NEXTGEN_KERNEL_BUILD_DIR:-$WORKSPACE_DIR/linux-working/build-fast}"

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
    if [ -f "$WORKSPACE_DIR/at91bootstrap/build-sd/binaries/boot.bin" ]; then
        SD_BOOTSTRAP="$WORKSPACE_DIR/at91bootstrap/build-sd/binaries/boot.bin"
    else
        # Migration fallback for the pre-wrapper bootstrap build layout.
        for candidate in "$WORKSPACE_DIR"/at91bootstrap/build/binaries/sama5d2-sdcardboot-uboot-*.bin; do
            [ -f "$candidate" ] || continue
            SD_BOOTSTRAP="$candidate"
        done
    fi
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
    "$KERNEL_BUILD_DIR/arch/arm/boot/zImage"
stage_required "$BINARIES_DIR/nextgen.dtb" \
    "${NEXTGEN_DTB_IMAGE:-}" \
    "$KERNEL_BUILD_DIR/arch/arm/boot/dts/microchip/nextgen.dtb" \
    "$KERNEL_BUILD_DIR/arch/arm/boot/dts/nextgen.dtb"

# The same U-Boot binary is later destined for the ratified 0x138000-byte
# NOR partition. Refuse to package a build that would overlap the environment.
# (The SD AT91Bootstrap binary is a different profile; its 32 KiB NOR bound is
# checked by the AT91Bootstrap NOR build itself.)
UBOOT_BYTES="$(wc -c < "$BINARIES_DIR/u-boot.bin")"
[ "$UBOOT_BYTES" -le $((0x138000)) ] || {
    echo "error: u-boot.bin is too large for NOR U-Boot partition: $UBOOT_BYTES > $((0x138000))" >&2
    exit 1
}

UBOOT_ENV_SOURCE="${NEXTGEN_UBOOT_ENV:-}"
UBOOT_ENV_TEXT="${NEXTGEN_UBOOT_ENV_TEXT:-$WORKSPACE_DIR/u-boot/board/atmel/sama5d27_nextgen/sama5d27_nextgen.env}"
MKENVIMAGE="${NEXTGEN_MKENVIMAGE:-$WORKSPACE_DIR/u-boot/build-fast/tools/mkenvimage}"

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
    case "${NEXTGEN_KERNEL_PROFILE:-baseline}" in
        deferred-diag)
            EXPECTED_BOOTDELAY=2
            ;;
        *)
            EXPECTED_BOOTDELAY=-2
            ;;
    esac
    grep -q "^bootdelay=${EXPECTED_BOOTDELAY}$" "$UBOOT_ENV_TEXT" || {
        echo "error: unexpected U-Boot bootdelay in $UBOOT_ENV_TEXT" >&2
        echo "       profile ${NEXTGEN_KERNEL_PROFILE:-baseline} expects bootdelay=${EXPECTED_BOOTDELAY}" >&2
        exit 1
    }
    grep -q '^manufacturer=' "$UBOOT_ENV_TEXT" ||
        { echo "error: U-Boot environment has no manufacturer identity" >&2; exit 1; }
    grep -q '^modeltype=' "$UBOOT_ENV_TEXT" ||
        { echo "error: U-Boot environment has no modeltype identity" >&2; exit 1; }
    grep -q '^model=' "$UBOOT_ENV_TEXT" ||
        { echo "error: U-Boot environment has no model identity" >&2; exit 1; }
    grep -q 'nextgen.manufacturer=${manufacturer}' "$UBOOT_ENV_TEXT" ||
        { echo "error: bootargs do not pass manufacturer identity" >&2; exit 1; }
    grep -q 'nextgen.modeltype=${modeltype}' "$UBOOT_ENV_TEXT" ||
        { echo "error: bootargs do not pass modeltype identity" >&2; exit 1; }
    grep -q 'nextgen.model=${model}' "$UBOOT_ENV_TEXT" ||
        { echo "error: bootargs do not pass model identity" >&2; exit 1; }
    if grep -q '^product=' "$UBOOT_ENV_TEXT" || grep -q 'nextgen.product=' "$UBOOT_ENV_TEXT"; then
        echo "error: obsolete splash/theme product state remains in U-Boot environment" >&2
        exit 1
    fi
    [ -x "$MKENVIMAGE" ] || {
        echo "error: mkenvimage is not available: $MKENVIMAGE" >&2
        echo "       rebuild U-Boot fast profile or set NEXTGEN_MKENVIMAGE" >&2
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
