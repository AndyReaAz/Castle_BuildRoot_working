#!/bin/sh
set -eu

usage()
{
    echo "Usage: sudo $0 /dev/<whole-device> [images-directory]" >&2
    echo "Writes p1=boot, p2=RO system, p3=persist, p4=data to card end." >&2
    exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
DEVICE="$1"
IMAGES_DIR="${2:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"

[ "$(id -u)" -eq 0 ] || { echo "error: must run as root" >&2; exit 1; }
case "$DEVICE" in /dev/*) ;; *) echo "error: expected whole /dev device" >&2; exit 1 ;; esac
[ -b "$DEVICE" ] || { echo "error: not a block device: $DEVICE" >&2; exit 1; }

DEVICE_TYPE="$(lsblk -ndo TYPE "$DEVICE" 2>/dev/null || true)"
PARENT_NAME="$(lsblk -ndo PKNAME "$DEVICE" 2>/dev/null || true)"
[ "$DEVICE_TYPE" = disk ] && [ -z "$PARENT_NAME" ] || {
    echo "error: expected a whole disk device, not a partition/mapping: $DEVICE" >&2
    lsblk "$DEVICE" >&2 || true
    exit 1
}

BOOT_IMAGE="$IMAGES_DIR/boot.vfat"
ROOT_IMAGE="$IMAGES_DIR/rootfs.squashfs"
PERSIST_IMAGE="$IMAGES_DIR/persist.ext4"
MANIFEST="$IMAGES_DIR/nextgen-image-manifest.sha256"
for image in "$BOOT_IMAGE" "$ROOT_IMAGE" "$PERSIST_IMAGE" "$MANIFEST"; do
    [ -f "$image" ] || { echo "error: missing $image" >&2; exit 1; }
done

(
    cd "$IMAGES_DIR"
    sha256sum -c nextgen-image-manifest.sha256
) || {
    echo "error: NextGen image manifest verification failed; refusing to erase $DEVICE" >&2
    exit 1
}

if lsblk -nrpo MOUNTPOINT "$DEVICE" 2>/dev/null | grep -q '[^[:space:]]'; then
    echo "error: $DEVICE or one of its partitions is mounted" >&2
    lsblk "$DEVICE" >&2 || true
    exit 1
fi

SECTOR_SIZE="$(blockdev --getss "$DEVICE")"
DISK_BYTES="$(blockdev --getsize64 "$DEVICE")"
DISK_SECTORS=$((DISK_BYTES / SECTOR_SIZE))
ALIGN_BYTES=$((1024 * 1024))
ALIGN_SECTORS=$(((ALIGN_BYTES + SECTOR_SIZE - 1) / SECTOR_SIZE))

align_up()
{
    value="$1"
    printf '%s\n' $((((value + ALIGN_SECTORS - 1) / ALIGN_SECTORS) * ALIGN_SECTORS))
}

image_sectors()
{
    bytes="$(stat -Lc %s "$1")"
    printf '%s\n' $(((bytes + SECTOR_SIZE - 1) / SECTOR_SIZE))
}

P1_START="$ALIGN_SECTORS"
P1_SIZE="$(image_sectors "$BOOT_IMAGE")"
P2_START="$(align_up $((P1_START + P1_SIZE)))"
P2_SIZE="$(image_sectors "$ROOT_IMAGE")"
P3_START="$(align_up $((P2_START + P2_SIZE)))"
P3_SIZE="$(image_sectors "$PERSIST_IMAGE")"
P4_START="$(align_up $((P3_START + P3_SIZE)))"

DATA_BYTES=$(((DISK_SECTORS - P4_START) * SECTOR_SIZE))
MIN_DATA_BYTES=$((4 * 1024 * 1024 * 1024))
[ "$P4_START" -lt "$DISK_SECTORS" ] && [ "$DATA_BYTES" -gt "$MIN_DATA_BYTES" ] || {
    echo "error: card is too small; p4 data must be larger than 4 GiB" >&2
    exit 1
}

case "$DEVICE" in
    *[0-9]) PART_PREFIX="${DEVICE}p" ;;
    *)      PART_PREFIX="$DEVICE" ;;
esac
P1="${PART_PREFIX}1"
P2="${PART_PREFIX}2"
P3="${PART_PREFIX}3"
P4="${PART_PREFIX}4"

echo
echo "WARNING: this will ERASE ALL DATA on $DEVICE"
lsblk "$DEVICE" || true
echo
printf "Type ERASE to continue: "
read answer
[ "$answer" = ERASE ] || { echo "Cancelled"; exit 1; }

sfdisk --wipe always "$DEVICE" <<EOF
label: dos
unit: sectors

start=$P1_START, size=$P1_SIZE, type=c, bootable
start=$P2_START, size=$P2_SIZE, type=83
start=$P3_START, size=$P3_SIZE, type=83
start=$P4_START, type=83
EOF

blockdev --rereadpt "$DEVICE" || true
command -v udevadm >/dev/null 2>&1 && udevadm settle || true

for part in "$P1" "$P2" "$P3" "$P4"; do
    count=0
    while [ ! -b "$part" ] && [ "$count" -lt 50 ]; do
        sleep 0.1
        count=$((count + 1))
    done
    [ -b "$part" ] || { echo "error: partition did not appear: $part" >&2; exit 1; }
done

dd if="$BOOT_IMAGE" of="$P1" bs=4M conv=fsync status=progress
dd if="$ROOT_IMAGE" of="$P2" bs=4M conv=fsync status=progress
dd if="$PERSIST_IMAGE" of="$P3" bs=4M conv=fsync status=progress
mkfs.ext4 -F -L data -m 0 -E lazy_itable_init=0,lazy_journal_init=0 "$P4"
sync

echo
echo "NextGen RO-root SD card written:"
lsblk -f "$DEVICE"
