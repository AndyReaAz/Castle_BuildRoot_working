#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BUILDROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"

: "${BINARIES_DIR:?Buildroot did not provide BINARIES_DIR}"

for image in boot.vfat rootfs.squashfs persist.ext4 data.ext4; do
    [ -f "$BINARIES_DIR/$image" ] || {
        echo "error: RO-root image is missing $BINARIES_DIR/$image" >&2
        exit 1
    }
done

rm -f "$BINARIES_DIR/sdcard.img"
"$BUILDROOT_DIR/support/scripts/genimage.sh" -c "$SCRIPT_DIR/genimage-ro.cfg"

(
    cd "$BINARIES_DIR"
    sha256sum boot.bin u-boot.bin zImage nextgen.dtb uboot.env         rootfs.squashfs persist.ext4 > nextgen-image-manifest.sha256
)

install -m 0755 "$SCRIPT_DIR/write-sd-card-ro.sh"     "$BINARIES_DIR/write-sd-card.sh"

echo "NextGen RO system image:  $BINARIES_DIR/rootfs.squashfs"
echo "NextGen persist image:    $BINARIES_DIR/persist.ext4"
echo "NextGen RO full SD image: $BINARIES_DIR/sdcard.img"
echo "NextGen RO SD writer:     $BINARIES_DIR/write-sd-card.sh"
