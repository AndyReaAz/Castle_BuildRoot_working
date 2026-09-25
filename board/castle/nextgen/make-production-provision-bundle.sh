#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <bundle-dir> <nor-at91bootstrap.bin> <prod-u-boot.bin> <rootfs.ubi>" >&2
    exit 2
fi

OUT="$1"
AT91="$2"
UBOOT="$3"
UBI="$4"

for f in "$AT91" "$UBOOT" "$UBI"; do
    [ -f "$f" ] || {
        echo "error: missing production artifact: $f" >&2
        exit 1
    }
done

command -v python3 >/dev/null 2>&1 || {
    echo "error: python3 is required to build the U-Boot length trailer" >&2
    exit 1
}

AT91_BYTES="$(wc -c < "$AT91" | tr -d '[:space:]')"
UBOOT_BYTES="$(wc -c < "$UBOOT" | tr -d '[:space:]')"
UBI_BYTES="$(wc -c < "$UBI" | tr -d '[:space:]')"

[ "$AT91_BYTES" -le $((0x8000)) ] || {
    echo "error: AT91Bootstrap exceeds its 32 KiB NOR partition: $AT91_BYTES" >&2
    exit 1
}

# Keep compatibility with the legacy bootstrap's fixed 0xA0000 read so a
# power loss between U-Boot and bootstrap programming remains recoverable.
[ "$UBOOT_BYTES" -le $((0x0a0000)) ] || {
    echo "error: production U-Boot exceeds 640 KiB migration window: $UBOOT_BYTES" >&2
    exit 1
}

[ "$UBI_BYTES" -le $((0x08000000)) ] || {
    echo "error: production UBI image exceeds the 128 MiB rootfs partition: $UBI_BYTES" >&2
    exit 1
}

rm -rf "$OUT"
mkdir -p "$OUT"
install -m 0644 "$AT91" "$OUT/at91bootstrap.bin"
install -m 0644 "$UBOOT" "$OUT/u-boot.bin"
install -m 0644 "$UBI" "$OUT/rootfs.ubi"

python3 - "$UBOOT_BYTES" "$OUT/u-boot.trailer" <<'PY'
import struct
import sys

length = int(sys.argv[1], 0)
path = sys.argv[2]
if not (0 < length <= 0x0A0000):
    raise SystemExit("invalid U-Boot length")
trailer = struct.pack("<4sIII", b"NGUB", length, length ^ 0xFFFFFFFF, 0)
with open(path, "wb") as f:
    f.write(trailer)
PY

[ "$(wc -c < "$OUT/u-boot.trailer" | tr -d '[:space:]')" -eq 16 ] || {
    echo "error: generated U-Boot trailer is not 16 bytes" >&2
    exit 1
}

cat > "$OUT/layout.env" <<EOF
NEXTGEN_PROVISION_BUNDLE=1
NOR_AT91_SIZE=0x00008000
NOR_UBOOT_SIZE=0x00138000
NOR_UBOOT_TRAILER_OFFSET=0x00137ff0
NOR_ENV_SIZE=0x00020000
NAND_ROOTFS_SIZE=0x08000000
UBOOT_LENGTH=$UBOOT_BYTES
EOF

(
    cd "$OUT"
    sha256sum at91bootstrap.bin u-boot.bin u-boot.trailer rootfs.ubi layout.env > manifest.sha256
)

echo "NextGen production provisioning bundle: $OUT"
cat "$OUT/manifest.sha256"
