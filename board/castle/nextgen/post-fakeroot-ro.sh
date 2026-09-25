#!/bin/sh
set -eu

TARGET_DIR="$1"
OUT_DIR="$(dirname "$TARGET_DIR")"
PRODUCT="$(cat "$TARGET_DIR/etc/nextgen-product")"
PERSIST_SEED="$OUT_DIR/nextgen-persist-seed"
SLOT_SOURCE="$OUT_DIR/nextgen-app-slot-source"

: "${BINARIES_DIR:?Buildroot did not provide BINARIES_DIR}"
: "${HOST_DIR:?Buildroot did not provide HOST_DIR}"

case "$PRODUCT" in sound|vibra) ;; *) echo "error: invalid product $PRODUCT" >&2; exit 1 ;; esac
[ -d "$PERSIST_SEED" ] || { echo "error: missing persist seed" >&2; exit 1; }
[ -d "$SLOT_SOURCE" ] || { echo "error: missing Application slot source" >&2; exit 1; }

MKSQUASHFS="$HOST_DIR/bin/mksquashfs"
MKFS_EXT4="$HOST_DIR/sbin/mkfs.ext4"
[ -x "$MKSQUASHFS" ] || { echo "error: missing host mksquashfs" >&2; exit 1; }
[ -x "$MKFS_EXT4" ] || { echo "error: missing host mkfs.ext4" >&2; exit 1; }

VERSION="$(sed -n 's/^version=//p' "$SLOT_SOURCE/bundle.info")"
case "$VERSION" in ''|*[!0-9]*) echo "error: invalid slot version" >&2; exit 1 ;; esac

APP_DIR="$PERSIST_SEED/app/$PRODUCT"
SLOT_IMAGE="$APP_DIR/slotA.sqfs"
rm -f "$SLOT_IMAGE" "$APP_DIR/slotA.meta" "$APP_DIR/slotA.sig"     "$APP_DIR/slotB.sqfs" "$APP_DIR/slotB.meta" "$APP_DIR/slotB.sig"

SOURCE_DATE_EPOCH=0 "$MKSQUASHFS" "$SLOT_SOURCE" "$SLOT_IMAGE"     -noappend -all-root -no-xattrs -comp lzo -b 131072     -no-progress -mkfs-time 0 -all-time 0 >/dev/null

chmod 0444 "$SLOT_IMAGE"
BYTES="$(wc -c < "$SLOT_IMAGE")"
SHA256="$(sha256sum "$SLOT_IMAGE" | awk '{print $1}')"

cat > "$APP_DIR/slotA.meta" <<EOF
format=4
product=$PRODUCT
version=$VERSION
platform_abi=1
bytes=$BYTES
sha256=$SHA256
EOF
chmod 0644 "$APP_DIR/slotA.meta"
printf 'slotA %s\n' "$VERSION" > "$PERSIST_SEED/state/$PRODUCT/accepted"
rm -f "$PERSIST_SEED/state/$PRODUCT/previous"       "$PERSIST_SEED/state/$PRODUCT/pending"       "$PERSIST_SEED/state/$PRODUCT/booting"       "$PERSIST_SEED/state/$PRODUCT/rollback"       "$PERSIST_SEED/state/$PRODUCT/cleanup"

chmod 0700 "$PERSIST_SEED/os/ssh"            "$PERSIST_SEED/os/seedrng"            "$PERSIST_SEED/os/NetworkManager/system-connections"

# This hook runs inside Buildroot's fakeroot environment. Make the intended
# on-device ownership explicit before mke2fs copies the tree.
chown -R 0:0 "$PERSIST_SEED"

PERSIST_IMAGE="$BINARIES_DIR/persist.ext4"
PERSIST_SIZE="${NEXTGEN_PERSIST_IMAGE_SIZE:-128M}"
rm -f "$PERSIST_IMAGE"
truncate -s "$PERSIST_SIZE" "$PERSIST_IMAGE"
"$MKFS_EXT4" -F -L persist -m 0     -E lazy_itable_init=0,lazy_journal_init=0     -d "$PERSIST_SEED" "$PERSIST_IMAGE" >/dev/null

echo "NextGen Application slotA image: $SLOT_IMAGE ($BYTES bytes)"
echo "NextGen persistent image:        $PERSIST_IMAGE"
