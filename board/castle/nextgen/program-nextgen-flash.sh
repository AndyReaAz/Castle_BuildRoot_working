#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ACTION="${1:-check}"
CONFIRM="${2:-}"

die()
{
    echo "program-nextgen-flash: $*" >&2
    exit 1
}

find_tool()
{
    name="$1"

    for tool in "/usr/sbin/$name" "/usr/bin/$name" "/sbin/$name" "/bin/$name"; do
        [ -x "$tool" ] && {
            printf '%s\n' "$tool"
            return 0
        }
    done

    tool="$(command -v "$name" 2>/dev/null || true)"
    [ -n "$tool" ] || die "missing required tool: $name"
    printf '%s\n' "$tool"
}

load_flash_modules()
{
    command -v modprobe >/dev/null 2>&1 || return 0

    # These may already be built in. Explicit modprobe is harmless in that case
    # and is required for the deferred bring-up SD profile when they are modules.
    modprobe atmel-quadspi >/dev/null 2>&1 || true
    modprobe spinand >/dev/null 2>&1 || true
    modprobe spi-nor >/dev/null 2>&1 || true
}

find_mtd()
{
    label="$1"
    expected_size="$2"
    expected_erase="$3"

    [ -r /proc/mtd ] || die "/proc/mtd is unavailable"

    while read -r dev size erase name rest; do
        [ "$name" = "\"$label\"" ] || continue

        [ "$size" = "$expected_size" ] ||
            die "$label has size 0x$size, expected 0x$expected_size"
        [ "$erase" = "$expected_erase" ] ||
            die "$label has erase size 0x$erase, expected 0x$expected_erase"

        dev="${dev%:}"
        [ -c "/dev/$dev" ] ||
            die "$label resolves to /dev/$dev but that character device is missing"

        printf '%s\n' "/dev/$dev"
        return 0
    done < /proc/mtd

    die "cannot find MTD partition labelled $label"
}

require_size()
{
    file="$1"
    expected="$2"

    [ -f "$file" ] || die "missing image: $file"
    actual="$(wc -c < "$file" | tr -d '[:space:]')"
    [ "$actual" -eq "$expected" ] ||
        die "$(basename "$file") is $actual bytes, expected $expected"
}

require_bringup_boot()
{
    cmdline="$(cat /proc/cmdline 2>/dev/null || true)"

    case " $cmdline " in
        *" nextgen.env=bringup "*) ;;
        *)
            die "programming is allowed only from the explicit bring-up SD environment"
            ;;
    esac
}

MANIFEST="$SCRIPT_DIR/nextgen-flash-manifest.sha256"
NOR_AT91="$SCRIPT_DIR/nor-at91bootstrap.bin"
NOR_UBOOT="$SCRIPT_DIR/nor-uboot.bin"
NOR_ENV="$SCRIPT_DIR/nor-uboot-env.bin"
BOOT_UBI="$SCRIPT_DIR/boot.ubi"
ROOTFS_UBI="$SCRIPT_DIR/rootfs.ubi"

SHA256SUM="$(find_tool sha256sum)"
FLASHCP="$(find_tool flashcp)"
FLASH_ERASE="$(find_tool flash_erase)"
UBIFORMAT="$(find_tool ubiformat)"
UBIDETACH="$(find_tool ubidetach)"

[ "$(id -u)" -eq 0 ] || die "must be run as root"
[ -f "$MANIFEST" ] || die "missing manifest: $MANIFEST"

require_size "$NOR_AT91" $((0x8000))
require_size "$NOR_UBOOT" $((0x138000))
require_size "$NOR_ENV" $((0x20000))
[ -f "$BOOT_UBI" ] || die "missing image: $BOOT_UBI"
[ -f "$ROOTFS_UBI" ] || die "missing image: $ROOTFS_UBI"
[ "$(wc -c < "$BOOT_UBI" | tr -d '[:space:]')" -le $((0x00800000)) ] ||
    die "boot.ubi exceeds its 8 MiB image budget"
[ "$(wc -c < "$ROOTFS_UBI" | tr -d '[:space:]')" -le $((0x08000000)) ] ||
    die "rootfs.ubi exceeds its 128 MiB partition"

(
    cd "$SCRIPT_DIR"
    "$SHA256SUM" -c "$(basename "$MANIFEST")"
) || die "image manifest verification failed"

load_flash_modules

# NOR must expose 4 KiB MTD erase units because the first partition boundary
# is 0x8000. NAND geometry is the Winbond 128 KiB PEB / 2 KiB page geometry.
MTD_AT91="$(find_mtd at91bootstrap 00008000 00001000)"
MTD_UBOOT="$(find_mtd uboot 00138000 00001000)"
MTD_ENV="$(find_mtd uboot-env 00020000 00001000)"
MTD_BOOT="$(find_mtd boot 00880000 00020000)"
MTD_ROOTFS="$(find_mtd rootfs 08000000 00020000)"

echo "Validated flash targets:"
echo "  at91bootstrap -> $MTD_AT91"
echo "  uboot         -> $MTD_UBOOT"
echo "  uboot-env     -> $MTD_ENV"
echo "  boot UBI      -> $MTD_BOOT"
echo "  rootfs UBI    -> $MTD_ROOTFS"

case "$ACTION" in
    check)
        echo "Flash layout and image set are consistent."
        echo "No flash was modified."
        echo "To program from the SD bring-up image:"
        echo "  $0 program --confirm-nextgen-flash"
        exit 0
        ;;
    program)
        [ "$CONFIRM" = "--confirm-nextgen-flash" ] ||
            die "program action requires --confirm-nextgen-flash"
        ;;
    *)
        die "usage: $0 [check|program --confirm-nextgen-flash]"
        ;;
esac

require_bringup_boot

echo "Programming SPI-NAND system/persist UBI first..."
"$UBIDETACH" -p "$MTD_ROOTFS" >/dev/null 2>&1 || true
"$UBIFORMAT" "$MTD_ROOTFS" -y -f "$ROOTFS_UBI"

echo "Programming SPI-NAND boot UBI..."
"$UBIDETACH" -p "$MTD_BOOT" >/dev/null 2>&1 || true
"$UBIFORMAT" "$MTD_BOOT" -y -f "$BOOT_UBI"

# Replace U-Boot while the existing fixed-window bootstrap can still load the
# first 640 KiB if power is lost before the trailer-aware bootstrap is written.
echo "Programming U-Boot..."
"$FLASHCP" -v "$NOR_UBOOT" "$MTD_UBOOT"

echo "Erasing legacy/test U-Boot environment..."
"$FLASH_ERASE" "$MTD_ENV" 0 0 >/dev/null

# Bootstrap is deliberately last. Reaching this point means both NAND UBI
# devices and the migration-safe U-Boot have already been programmed.
echo "Programming AT91Bootstrap last..."
"$FLASHCP" -v "$NOR_AT91" "$MTD_AT91"

sync

echo "NextGen production flash programming completed successfully."
echo "Power down, remove the SD card, then boot the unit normally."
