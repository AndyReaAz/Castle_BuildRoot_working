#!/bin/sh
set -eu

if [ "$#" -ne 7 ]; then
    echo "Usage: $0 <bundle-dir> <nor-at91bootstrap.bin> <prod-u-boot.bin> <u-boot.trailer> <boot.ubi> <rootfs.ubi> <sound|vibra>" >&2
    exit 2
fi

OUT="$1"
AT91="$2"
UBOOT="$3"
TRAILER="$4"
BOOT_UBI="$5"
ROOT_UBI="$6"
PRODUCT="$7"

case "$PRODUCT" in sound|vibra) ;; *)
    echo "error: invalid production product '$PRODUCT'" >&2
    exit 1
    ;;
esac

for f in "$AT91" "$UBOOT" "$TRAILER" "$BOOT_UBI" "$ROOT_UBI"; do
    [ -f "$f" ] || {
        echo "error: missing production artifact: $f" >&2
        exit 1
    }
done

AT91_BYTES="$(wc -c < "$AT91" | tr -d '[:space:]')"
UBOOT_BYTES="$(wc -c < "$UBOOT" | tr -d '[:space:]')"
TRAILER_BYTES="$(wc -c < "$TRAILER" | tr -d '[:space:]')"
BOOT_UBI_BYTES="$(wc -c < "$BOOT_UBI" | tr -d '[:space:]')"
ROOT_UBI_BYTES="$(wc -c < "$ROOT_UBI" | tr -d '[:space:]')"

grep -a -q 'FUSE: incompatible existing boot fuse; not modified' "$AT91" || {
    echo "error: NOR AT91Bootstrap does not contain the NextGen fuse guard" >&2
    exit 1
}
[ "$AT91_BYTES" -le $((0x8000)) ] || {
    echo "error: AT91Bootstrap exceeds its 32 KiB NOR partition: $AT91_BYTES" >&2
    exit 1
}

# Preserve bootability if power disappears after U-Boot is replaced but before
# trailer-aware AT91Bootstrap is programmed: the old bootstrap reads 0xA0000.
[ "$UBOOT_BYTES" -le $((0x0a0000)) ] || {
    echo "error: production U-Boot exceeds 640 KiB migration window: $UBOOT_BYTES" >&2
    exit 1
}

[ "$TRAILER_BYTES" -eq 16 ] || {
    echo "error: U-Boot length trailer is not 16 bytes" >&2
    exit 1
}
set -- $(od -An -tu1 -N16 "$TRAILER")
[ "$1" -eq 78 ] && [ "$2" -eq 71 ] && [ "$3" -eq 85 ] && [ "$4" -eq 66 ] || {
    echo "error: U-Boot length trailer has invalid NGUB magic" >&2
    exit 1
}
TRAILER_LEN=$(( $5 | ($6 << 8) | ($7 << 16) | ($8 << 24) ))
TRAILER_INV=$(( $9 | (${10} << 8) | (${11} << 16) | (${12} << 24) ))
TRAILER_VER=$(( ${13} | (${14} << 8) | (${15} << 16) | (${16} << 24) ))
[ "$TRAILER_LEN" -eq "$UBOOT_BYTES" ] &&
[ $(( (TRAILER_LEN ^ TRAILER_INV) & 0xffffffff )) -eq $((0xffffffff)) ] &&
[ "$TRAILER_VER" -eq 1 ] || {
    echo "error: U-Boot trailer does not match u-boot.bin" >&2
    exit 1
}

[ "$BOOT_UBI_BYTES" -le $((0x00800000)) ] || {
    echo "error: boot.ubi exceeds its 8 MiB image budget: $BOOT_UBI_BYTES" >&2
    exit 1
}
[ "$ROOT_UBI_BYTES" -le $((0x08000000)) ] || {
    echo "error: rootfs.ubi exceeds the 128 MiB rootfs partition: $ROOT_UBI_BYTES" >&2
    exit 1
}

rm -rf "$OUT"
mkdir -p "$OUT"
install -m 0644 "$AT91" "$OUT/at91bootstrap.bin"
install -m 0644 "$UBOOT" "$OUT/u-boot.bin"
install -m 0644 "$TRAILER" "$OUT/u-boot.trailer"
install -m 0644 "$BOOT_UBI" "$OUT/boot.ubi"
install -m 0644 "$ROOT_UBI" "$OUT/rootfs.ubi"

cat > "$OUT/layout.env" <<EOF
NEXTGEN_PROVISION_BUNDLE=2
NEXTGEN_STORAGE_SCHEMA=ro-persist-v1
NEXTGEN_STORAGE_BACKEND=nand-ubi
NEXTGEN_PRODUCT=$PRODUCT
NOR_AT91_SIZE=0x00008000
NOR_UBOOT_SIZE=0x00138000
NOR_UBOOT_TRAILER_OFFSET=0x00137ff0
NOR_ENV_SIZE=0x00020000
NAND_BOOT_SIZE=0x00880000
NAND_ROOTFS_SIZE=0x08000000
UBOOT_LENGTH=$UBOOT_BYTES
EOF

(
    cd "$OUT"
    sha256sum         at91bootstrap.bin u-boot.bin u-boot.trailer         boot.ubi rootfs.ubi layout.env > manifest.sha256
)

echo "NextGen production provisioning bundle: $OUT"
cat "$OUT/manifest.sha256"
