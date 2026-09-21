#!/bin/sh
set -eu

usage()
{
    echo "Usage: sudo $0 /dev/<whole-device> [images-directory]" >&2
    echo "Writes p1=FAT boot, p2=Buildroot rootfs, p3=ext4 data using the rest of the card." >&2
    exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
DEVICE="$1"
IMAGES_DIR="${2:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"

[ "$(id -u)" -eq 0 ] || {
    echo "error: must run as root" >&2
    exit 1
}

case "$DEVICE" in
    /dev/*) ;;
    *) echo "error: expected a whole block device under /dev" >&2; exit 1 ;;
esac

[ -b "$DEVICE" ] || {
    echo "error: not a block device: $DEVICE" >&2
    exit 1
}

BOOT_IMAGE="$IMAGES_DIR/boot.vfat"
ROOT_IMAGE="$IMAGES_DIR/rootfs.ext4"
[ -f "$BOOT_IMAGE" ] || { echo "error: missing $BOOT_IMAGE" >&2; exit 1; }
[ -f "$ROOT_IMAGE" ] || { echo "error: missing $ROOT_IMAGE" >&2; exit 1; }

# Never overwrite a mounted disk.
if lsblk -nrpo MOUNTPOINT "$DEVICE" 2>/dev/null | grep -q '[^[:space:]]'; then
    echo "error: $DEVICE or one of its partitions is mounted" >&2
    lsblk "$DEVICE" >&2 || true
    exit 1
fi

SECTOR_SIZE="$(blockdev --getss "$DEVICE")"
DISK_BYTES="$(blockdev --getsize64 "$DEVICE")"
BOOT_BYTES="$(stat -c %s "$BOOT_IMAGE")"
ROOT_BYTES="$(stat -Lc %s "$ROOT_IMAGE")"
MIN_ROOT_BYTES=$((16 * 1024 * 1024))
[ "$ROOT_BYTES" -ge "$MIN_ROOT_BYTES" ] || {
    echo "error: rootfs image is unexpectedly small ($ROOT_BYTES bytes): $ROOT_IMAGE" >&2
    exit 1
}

ALIGN_BYTES=$((1024 * 1024))
P1_START=$(((ALIGN_BYTES + SECTOR_SIZE - 1) / SECTOR_SIZE))
P1_SIZE=$(((BOOT_BYTES + SECTOR_SIZE - 1) / SECTOR_SIZE))
P2_START=$((P1_START + P1_SIZE))
P2_SIZE=$(((ROOT_BYTES + SECTOR_SIZE - 1) / SECTOR_SIZE))
P3_START=$((P2_START + P2_SIZE))
DISK_SECTORS=$((DISK_BYTES / SECTOR_SIZE))
DATA_BYTES=$(((DISK_SECTORS - P3_START) * SECTOR_SIZE))
MIN_DATA_BYTES=$((4 * 1024 * 1024 * 1024))

[ "$P3_START" -lt "$DISK_SECTORS" ] && [ "$DATA_BYTES" -gt "$MIN_DATA_BYTES" ] || {
    echo "error: card is too small; p3 data must be larger than 4 GiB" >&2
    exit 1
}

case "$DEVICE" in
    *[0-9]) PART_PREFIX="${DEVICE}p" ;;
    *)      PART_PREFIX="$DEVICE" ;;
esac
P1="${PART_PREFIX}1"
P2="${PART_PREFIX}2"
P3="${PART_PREFIX}3"

echo
echo "WARNING: this will ERASE ALL DATA on $DEVICE"
lsblk "$DEVICE" || true
echo
printf "Type ERASE to continue: "
read answer
[ "$answer" = "ERASE" ] || {
    echo "Cancelled"
    exit 1
}

sfdisk --wipe always "$DEVICE" <<EOF
label: dos
unit: sectors

start=$P1_START, size=$P1_SIZE, type=c, bootable
start=$P2_START, size=$P2_SIZE, type=83
start=$P3_START, type=83
EOF

blockdev --rereadpt "$DEVICE" || true
command -v udevadm >/dev/null 2>&1 && udevadm settle || true

for part in "$P1" "$P2" "$P3"; do
    count=0
    while [ ! -b "$part" ] && [ "$count" -lt 50 ]; do
        sleep 0.1
        count=$((count + 1))
    done
    [ -b "$part" ] || {
        echo "error: partition did not appear: $part" >&2
        exit 1
    }
done

dd if="$BOOT_IMAGE" of="$P1" bs=4M conv=fsync status=progress
dd if="$ROOT_IMAGE" of="$P2" bs=4M conv=fsync status=progress
mkfs.ext4 -F -L data -m 0 "$P3"
sync

echo
echo "NextGen SD card written:"
lsblk -f "$DEVICE"
