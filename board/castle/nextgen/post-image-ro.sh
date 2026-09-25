#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BUILDROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
OUTPUT_DIR="$(CDPATH= cd -- "$BINARIES_DIR/.." && pwd)"

: "${BINARIES_DIR:?Buildroot did not provide BINARIES_DIR}"
: "${HOST_DIR:?Buildroot did not provide HOST_DIR}"

PRODUCT="${NEXTGEN_PRODUCT:-sound}"
case "$PRODUCT" in sound|vibra) ;; *)
    echo "error: invalid NEXTGEN_PRODUCT '$PRODUCT'" >&2
    exit 1
    ;;
esac

PERSIST_SEED="$OUTPUT_DIR/nextgen-persist-seed"
SLOT_SOURCE="$OUTPUT_DIR/nextgen-app-slot-source"
APP_DIR="$PERSIST_SEED/app/$PRODUCT"
STATE_DIR="$PERSIST_SEED/state/$PRODUCT"
SLOT_IMAGE="$APP_DIR/slotA.sqfs"
PERSIST_IMAGE="$BINARIES_DIR/persist.ext4"
PERSIST_SIZE="${NEXTGEN_PERSIST_IMAGE_SIZE:-128M}"
MKSQUASHFS="$HOST_DIR/bin/mksquashfs"
MKFS_EXT4="$HOST_DIR/sbin/mkfs.ext4"
FAKEROOT="$HOST_DIR/bin/fakeroot"

for image in boot.vfat rootfs.squashfs data.ext4; do
    [ -f "$BINARIES_DIR/$image" ] || {
        echo "error: RO-root image is missing $BINARIES_DIR/$image" >&2
        exit 1
    }
done
[ -d "$PERSIST_SEED" ] || {
    echo "error: RO-root persist seed is missing: $PERSIST_SEED" >&2
    exit 1
}
[ -d "$SLOT_SOURCE" ] || {
    echo "error: RO-root Application slot source is missing: $SLOT_SOURCE" >&2
    exit 1
}
[ -x "$MKSQUASHFS" ] || {
    echo "error: host mksquashfs is missing: $MKSQUASHFS" >&2
    exit 1
}
[ -x "$MKFS_EXT4" ] || {
    echo "error: host mkfs.ext4 is missing: $MKFS_EXT4" >&2
    exit 1
}
[ -x "$FAKEROOT" ] || {
    echo "error: host fakeroot is missing: $FAKEROOT" >&2
    exit 1
}

VERSION="$(sed -n 's/^version=//p' "$SLOT_SOURCE/bundle.info")"
case "$VERSION" in
    ''|*[!0-9]*) echo "error: invalid staged Application version" >&2; exit 1 ;;
esac

mkdir -p "$APP_DIR" "$STATE_DIR"
rm -f     "$APP_DIR/slotA.sqfs" "$APP_DIR/slotA.meta" "$APP_DIR/slotA.sig"     "$APP_DIR/slotB.sqfs" "$APP_DIR/slotB.meta" "$APP_DIR/slotB.sig"

SOURCE_DATE_EPOCH=0 "$MKSQUASHFS" "$SLOT_SOURCE" "$SLOT_IMAGE"     -noappend -all-root -no-xattrs -comp lzo -b 131072     -no-progress -mkfs-time 0 -all-time 0 >/dev/null

chmod 0444 "$SLOT_IMAGE"
SLOT_BYTES="$(wc -c < "$SLOT_IMAGE")"
SLOT_SHA256="$(sha256sum "$SLOT_IMAGE" | awk '{print $1}')"

cat > "$APP_DIR/slotA.meta" <<EOF
format=4
product=$PRODUCT
version=$VERSION
platform_abi=1
bytes=$SLOT_BYTES
sha256=$SLOT_SHA256
EOF
chmod 0644 "$APP_DIR/slotA.meta"

printf 'slotA %s\n' "$VERSION" > "$STATE_DIR/accepted"
rm -f     "$STATE_DIR/previous"     "$STATE_DIR/pending"     "$STATE_DIR/booting"     "$STATE_DIR/rollback"     "$STATE_DIR/cleanup"

# Build the writable persistent filesystem exactly once.  Run chown and
# mke2fs within the same fakeroot process so files copied by -d are encoded as
# root-owned without requiring the Buildroot host user to have real uid 0.
rm -f "$PERSIST_IMAGE"
"$FAKEROOT" -- /bin/sh -eu -c '
    seed=$1
    image=$2
    size=$3
    mkfs=$4

    chown -h -R 0:0 "$seed"
    truncate -s "$size" "$image"
    "$mkfs" -F -L persist -m 0         -E lazy_itable_init=0,lazy_journal_init=0         -d "$seed" "$image" >/dev/null
' sh "$PERSIST_SEED" "$PERSIST_IMAGE" "$PERSIST_SIZE" "$MKFS_EXT4"

[ -s "$PERSIST_IMAGE" ] || {
    echo "error: persistent image was not created" >&2
    exit 1
}

# The raw image is useful for inspection.  For real removable media the
# generated writer below is preferred because it extends p4 to the actual card
# size instead of the fixed data.ext4 seed size.
rm -f "$BINARIES_DIR/sdcard.img"
"$BUILDROOT_DIR/support/scripts/genimage.sh" -c "$SCRIPT_DIR/genimage-ro.cfg"

(
    cd "$BINARIES_DIR"
    sha256sum         boot.bin u-boot.bin zImage nextgen.dtb uboot.env         rootfs.squashfs persist.ext4         > nextgen-image-manifest.sha256
)

install -m 0755 "$SCRIPT_DIR/write-sd-card-ro.sh"     "$BINARIES_DIR/write-sd-card.sh"

echo "NextGen initial app image: $SLOT_IMAGE ($SLOT_BYTES bytes)"
echo "NextGen RO system image:   $BINARIES_DIR/rootfs.squashfs"
echo "NextGen persist image:     $PERSIST_IMAGE"
echo "NextGen RO full SD image:  $BINARIES_DIR/sdcard.img"
echo "NextGen RO SD writer:      $BINARIES_DIR/write-sd-card.sh"
