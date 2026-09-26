#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BUILDROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"

: "${BINARIES_DIR:?Buildroot did not provide BINARIES_DIR}"
: "${HOST_DIR:?Buildroot did not provide HOST_DIR}"

OUTPUT_DIR="$(CDPATH= cd -- "$BINARIES_DIR/.." && pwd)"
PERSIST_SEED="$OUTPUT_DIR/nextgen-persist-seed"
SLOT_SOURCE="$OUTPUT_DIR/nextgen-app-slot-source"
BACKEND="${NEXTGEN_STORAGE_BACKEND:-}"

case "$BACKEND" in
    sd-ext4|nand-ubi) ;;
    *) echo "error: invalid RO storage backend '$BACKEND'" >&2; exit 1 ;;
esac

# Output trees are incremental. Remove every backend-derived deployable first so
# a failed run cannot leave a stale complete image set that looks usable.
rm -f     "$BINARIES_DIR/rootfs.ext2" "$BINARIES_DIR/rootfs.ext3"     "$BINARIES_DIR/rootfs.ext4" "$BINARIES_DIR/persist.ext4"     "$BINARIES_DIR/persist.ubifs" "$BINARIES_DIR/rootfs.ubi"     "$BINARIES_DIR/boot.ubi" "$BINARIES_DIR/sdcard.img"     "$BINARIES_DIR/nor-at91bootstrap.bin" "$BINARIES_DIR/nor-uboot.bin"     "$BINARIES_DIR/nor-uboot-env.bin" "$BINARIES_DIR/nor.img"     "$BINARIES_DIR/nextgen-image-manifest.sha256"     "$BINARIES_DIR/nextgen-flash-manifest.sha256"     "$BINARIES_DIR/write-sd-card.sh" "$BINARIES_DIR/program-nextgen-flash.sh"
rm -rf "$BINARIES_DIR/production-provision"

STAGED_PRODUCT="$(sed -n 's/^product=//p' "$SLOT_SOURCE/bundle.info" 2>/dev/null || true)"
case "$STAGED_PRODUCT" in sound|vibra) ;; *)
    echo "error: invalid or missing staged Application product: '$STAGED_PRODUCT'" >&2
    exit 1
    ;;
esac

PRODUCT="${NEXTGEN_PRODUCT:-$STAGED_PRODUCT}"
[ "$PRODUCT" = "$STAGED_PRODUCT" ] || {
    echo "error: NEXTGEN_PRODUCT '$PRODUCT' disagrees with staged '$STAGED_PRODUCT'" >&2
    exit 1
}

APP_DIR="$PERSIST_SEED/app/$PRODUCT"
STATE_DIR="$PERSIST_SEED/state/$PRODUCT"
SLOT_IMAGE="$APP_DIR/slotA.sqfs"
MKSQUASHFS="$HOST_DIR/bin/mksquashfs"
UNSQUASHFS="$HOST_DIR/bin/unsquashfs"
FAKEROOT="$HOST_DIR/bin/fakeroot"

for image in rootfs.squashfs; do
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
for tool in "$MKSQUASHFS" "$UNSQUASHFS" "$FAKEROOT"; do
    [ -x "$tool" ] || {
        echo "error: RO image host tool is missing: $tool" >&2
        exit 1
    }
done

VERSION="$(sed -n 's/^version=//p' "$SLOT_SOURCE/bundle.info")"
case "$VERSION" in
    ''|*[!0-9]*) echo "error: invalid staged Application version" >&2; exit 1 ;;
esac

# Create the immutable initial Application image identically for every storage
# backend. Future updates use the same format-4 slot files on ext4 or UBIFS.
mkdir -p "$APP_DIR" "$STATE_DIR"
rm -f     "$APP_DIR/slotA.sqfs" "$APP_DIR/slotA.meta" "$APP_DIR/slotA.sig"     "$APP_DIR/slotB.sqfs" "$APP_DIR/slotB.meta" "$APP_DIR/slotB.sig"

(
    # Recent squashfs-tools rejects combining SOURCE_DATE_EPOCH with explicit
    # timestamp options. Keep the image deterministic using the command-line
    # epoch controls and isolate ourselves from Buildroot's reproducibility env.
    unset SOURCE_DATE_EPOCH
    "$MKSQUASHFS" "$SLOT_SOURCE" "$SLOT_IMAGE" \
        -noappend -all-root -no-xattrs -comp lzo -b 131072 \
        -no-progress -mkfs-time 0 -all-time 0 >/dev/null
)

chmod 0444 "$SLOT_IMAGE"
SLOT_BYTES="$(wc -c < "$SLOT_IMAGE" | tr -d '[:space:]')"
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
rm -f     "$STATE_DIR/previous" "$STATE_DIR/pending" "$STATE_DIR/booting"     "$STATE_DIR/rollback" "$STATE_DIR/cleanup"

# Verify the system image that will actually be written.
SYSTEM_SCHEMA="$("$UNSQUASHFS" -cat "$BINARIES_DIR/rootfs.squashfs"     etc/nextgen-storage-schema 2>/dev/null || true)"
SYSTEM_BACKEND="$("$UNSQUASHFS" -cat "$BINARIES_DIR/rootfs.squashfs"     etc/nextgen-storage-backend 2>/dev/null || true)"
SYSTEM_ABI="$("$UNSQUASHFS" -cat "$BINARIES_DIR/rootfs.squashfs"     etc/nextgen-platform-abi 2>/dev/null || true)"
SYSTEM_FSTAB="$("$UNSQUASHFS" -cat "$BINARIES_DIR/rootfs.squashfs"     etc/fstab 2>/dev/null || true)"

[ "$SYSTEM_SCHEMA" = ro-persist-v1 ] || {
    echo "error: generated SquashFS has wrong storage schema: '$SYSTEM_SCHEMA'" >&2
    exit 1
}
[ "$SYSTEM_BACKEND" = "$BACKEND" ] || {
    echo "error: generated SquashFS backend '$SYSTEM_BACKEND' != '$BACKEND'" >&2
    exit 1
}
[ "$SYSTEM_ABI" = 1 ] || {
    echo "error: generated SquashFS has wrong platform ABI: '$SYSTEM_ABI'" >&2
    exit 1
}
printf '%s\n' "$SYSTEM_FSTAB" |
    grep -q '^/dev/root[[:space:]]\+/[[:space:]]\+squashfs[[:space:]]\+ro' || {
        echo "error: generated SquashFS fstab does not declare read-only root" >&2
        exit 1
    }
if printf '%s\n' "$SYSTEM_FSTAB" | grep -q '^[^#].*[[:space:]]/sdcard[[:space:]]'; then
    echo "error: generated SquashFS fstab must not mount /sdcard" >&2
    exit 1
fi

case "$BACKEND" in
sd-ext4)
    for image in boot.vfat data.ext4 uboot.env; do
        [ -f "$BINARIES_DIR/$image" ] || {
            echo "error: SD RO-root image is missing $BINARIES_DIR/$image" >&2
            exit 1
        }
    done
    printf '%s\n' "$SYSTEM_FSTAB" |
        grep -q '^/dev/mmcblk0p3[[:space:]]\+/persist[[:space:]]\+ext4' || {
            echo "error: generated SquashFS fstab has no p3 /persist mount" >&2
            exit 1
        }

    PERSIST_IMAGE="$BINARIES_DIR/persist.ext4"
    PERSIST_SIZE="${NEXTGEN_PERSIST_IMAGE_SIZE:-128M}"
    MKFS_EXT4="$HOST_DIR/sbin/mkfs.ext4"
    E2FSCK="$HOST_DIR/sbin/e2fsck"
    DEBUGFS="$HOST_DIR/sbin/debugfs"
    for tool in "$MKFS_EXT4" "$E2FSCK" "$DEBUGFS"; do
        [ -x "$tool" ] || {
            echo "error: SD RO image tool is missing: $tool" >&2
            exit 1
        }
    done

    "$FAKEROOT" -- /bin/sh -eu -c '
        seed=$1
        image=$2
        size=$3
        mkfs=$4
        chown -h -R 0:0 "$seed"
        truncate -s "$size" "$image"
        "$mkfs" -F -L persist -m 0             -E lazy_itable_init=0,lazy_journal_init=0             -d "$seed" "$image" >/dev/null
    ' sh "$PERSIST_SEED" "$PERSIST_IMAGE" "$PERSIST_SIZE" "$MKFS_EXT4"

    [ -s "$PERSIST_IMAGE" ] || {
        echo "error: persistent ext4 image was not created" >&2
        exit 1
    }
    "$E2FSCK" -fn "$PERSIST_IMAGE" >/dev/null 2>&1 || {
        rc=$?
        echo "error: generated persist.ext4 failed read-only fsck (rc=$rc)" >&2
        exit 1
    }
    "$DEBUGFS" -R "stat /app/$PRODUCT/slotA.sqfs" "$PERSIST_IMAGE" 2>/dev/null |
        grep -q '^Inode:' || {
            echo "error: persist.ext4 has no slotA Application image" >&2
            exit 1
        }
    "$DEBUGFS" -R "stat /app/$PRODUCT/slotA.meta" "$PERSIST_IMAGE" 2>/dev/null |
        grep -q '^Inode:' || {
            echo "error: persist.ext4 has no slotA metadata" >&2
            exit 1
        }
    PERSIST_ACCEPTED="$("$DEBUGFS" -R "cat /state/$PRODUCT/accepted"         "$PERSIST_IMAGE" 2>/dev/null | tr -d '\r\n')"
    [ "$PERSIST_ACCEPTED" = "slotA $VERSION" ] || {
        echo "error: persist.ext4 accepted state is '$PERSIST_ACCEPTED'" >&2
        exit 1
    }

    # Verify the environment actually copied into the FAT image.
    BOOT_ENV_CHECK="$OUTPUT_DIR/.nextgen-boot-env-check"
    rm -f "$BOOT_ENV_CHECK"
    "$HOST_DIR/bin/mcopy" -i "$BINARIES_DIR/boot.vfat"         "::/uboot.env" "$BOOT_ENV_CHECK" >/dev/null 2>&1 || {
            echo "error: boot.vfat does not contain uboot.env" >&2
            exit 1
        }
    cmp -s "$BOOT_ENV_CHECK" "$BINARIES_DIR/uboot.env" || {
        rm -f "$BOOT_ENV_CHECK"
        echo "error: boot.vfat uboot.env differs from staged environment" >&2
        exit 1
    }
    rm -f "$BOOT_ENV_CHECK"

    rm -f "$BINARIES_DIR/sdcard.img"
    "$BUILDROOT_DIR/support/scripts/genimage.sh" -c "$SCRIPT_DIR/genimage-ro.cfg"

    (
        cd "$BINARIES_DIR"
        sha256sum             boot.bin u-boot.bin zImage nextgen.dtb uboot.env             boot.vfat rootfs.squashfs persist.ext4             > nextgen-image-manifest.sha256
    )

    install -m 0755 "$SCRIPT_DIR/write-sd-card-ro.sh"         "$BINARIES_DIR/write-sd-card.sh"

    echo "NextGen RO image verification: SD boot + system + persist OK"
    echo "NextGen initial app image: $SLOT_IMAGE ($SLOT_BYTES bytes)"
    echo "NextGen RO system image:   $BINARIES_DIR/rootfs.squashfs"
    echo "NextGen persist image:     $PERSIST_IMAGE"
    echo "NextGen RO full SD image:  $BINARIES_DIR/sdcard.img"
    echo "NextGen RO SD writer:      $BINARIES_DIR/write-sd-card.sh"
    ;;

nand-ubi)
    printf '%s\n' "$SYSTEM_FSTAB" |
        grep -q '^ubi0:persist[[:space:]]\+/persist[[:space:]]\+ubifs' || {
            echo "error: generated SquashFS fstab has no UBI persist mount" >&2
            exit 1
        }

    for image in boot.bin u-boot.bin u-boot.nor-trailer uboot.env zImage nextgen.dtb; do
        [ -f "$BINARIES_DIR/$image" ] || {
            echo "error: NAND RO-root image is missing $BINARIES_DIR/$image" >&2
            exit 1
        }
    done

    MKFS_UBIFS="$HOST_DIR/sbin/mkfs.ubifs"
    UBINIZE="$HOST_DIR/sbin/ubinize"
    for tool in "$MKFS_UBIFS" "$UBINIZE"; do
        [ -x "$tool" ] || {
            echo "error: NAND RO image tool is missing: $tool" >&2
            exit 1
        }
    done

    # Winbond SPI-NAND geometry already proven by the existing UBI profile.
    NAND_MIN_IO=2048
    NAND_PEB=131072
    NAND_LEB=126976
    NAND_MAX_LEBS=1000
    SYSTEM_MAX_BYTES=$((64 * 1024 * 1024))

    SYSTEM_BYTES="$(wc -c < "$BINARIES_DIR/rootfs.squashfs" | tr -d '[:space:]')"
    [ "$SYSTEM_BYTES" -le "$SYSTEM_MAX_BYTES" ] || {
        echo "error: immutable system SquashFS exceeds 64 MiB NAND budget: $SYSTEM_BYTES" >&2
        exit 1
    }

    PERSIST_UBIFS="$BINARIES_DIR/persist.ubifs"
    "$FAKEROOT" -- /bin/sh -eu -c '
        seed=$1
        image=$2
        mkfs=$3
        minio=$4
        leb=$5
        maxlebs=$6
        chown -h -R 0:0 "$seed"
        "$mkfs" -q -r "$seed" -o "$image"             -m "$minio" -e "$leb" -c "$maxlebs" -x lzo
    ' sh "$PERSIST_SEED" "$PERSIST_UBIFS" "$MKFS_UBIFS"         "$NAND_MIN_IO" "$NAND_LEB" "$NAND_MAX_LEBS"

    [ -s "$PERSIST_UBIFS" ] || {
        echo "error: persist.ubifs was not created" >&2
        exit 1
    }

    ROOT_CFG="$OUTPUT_DIR/.nextgen-rootfs-ubinize.cfg"
    cat > "$ROOT_CFG" <<EOF
[system]
mode=ubi
image=$BINARIES_DIR/rootfs.squashfs
vol_id=0
vol_type=static
vol_name=system
vol_alignment=1

[persist]
mode=ubi
image=$PERSIST_UBIFS
vol_id=1
vol_type=dynamic
vol_name=persist
vol_alignment=1
vol_flags=autoresize
EOF

    "$UBINIZE" -m "$NAND_MIN_IO" -p "$NAND_PEB"         -o "$BINARIES_DIR/rootfs.ubi" "$ROOT_CFG"
    rm -f "$ROOT_CFG"

    ROOT_UBI_BYTES="$(wc -c < "$BINARIES_DIR/rootfs.ubi" | tr -d '[:space:]')"
    [ "$ROOT_UBI_BYTES" -le $((0x08000000)) ] || {
        echo "error: rootfs.ubi exceeds 128 MiB NAND partition: $ROOT_UBI_BYTES" >&2
        exit 1
    }

    DTB_BYTES="$(wc -c < "$BINARIES_DIR/nextgen.dtb" | tr -d '[:space:]')"
    KERNEL_BYTES="$(wc -c < "$BINARIES_DIR/zImage" | tr -d '[:space:]')"
    [ "$DTB_BYTES" -gt 0 ] && [ "$KERNEL_BYTES" -gt 0 ] || {
        echo "error: empty production kernel/DTB artifact" >&2
        exit 1
    }

    BOOT_CFG="$OUTPUT_DIR/.nextgen-boot-ubinize.cfg"
    cat > "$BOOT_CFG" <<EOF
[device-tree]
mode=ubi
vol_id=0
vol_type=static
vol_name=device-tree
vol_alignment=1
image=$BINARIES_DIR/nextgen.dtb

[kernel]
mode=ubi
vol_id=1
vol_type=static
vol_name=kernel
vol_alignment=1
image=$BINARIES_DIR/zImage
EOF

    "$UBINIZE" -m "$NAND_MIN_IO" -p "$NAND_PEB"         -o "$BINARIES_DIR/boot.ubi" "$BOOT_CFG"
    rm -f "$BOOT_CFG"

    BOOT_UBI_BYTES="$(wc -c < "$BINARIES_DIR/boot.ubi" | tr -d '[:space:]')"
    [ "$BOOT_UBI_BYTES" -le $((0x00800000)) ] || {
        echo "error: boot.ubi exceeds 8 MiB budget: $BOOT_UBI_BYTES" >&2
        exit 1
    }

    UBOOT_BYTES="$(wc -c < "$BINARIES_DIR/u-boot.bin" | tr -d '[:space:]')"
    [ "$UBOOT_BYTES" -le $((0x0a0000)) ] || {
        echo "error: production U-Boot exceeds migration-safe 640 KiB window: $UBOOT_BYTES" >&2
        exit 1
    }
    [ "$(wc -c < "$BINARIES_DIR/u-boot.nor-trailer" | tr -d '[:space:]')" -eq 16 ] || {
        echo "error: U-Boot NOR trailer is not 16 bytes" >&2
        exit 1
    }

    set -- $(od -An -tu1 -N16 "$BINARIES_DIR/u-boot.nor-trailer")
    [ "$1" -eq 78 ] && [ "$2" -eq 71 ] && [ "$3" -eq 85 ] && [ "$4" -eq 66 ] || {
        echo "error: U-Boot NOR trailer has invalid NGUB magic" >&2
        exit 1
    }
    TRAILER_LEN=$(( $5 | ($6 << 8) | ($7 << 16) | ($8 << 24) ))
    TRAILER_INV=$(( $9 | (${10} << 8) | (${11} << 16) | (${12} << 24) ))
    TRAILER_VER=$(( ${13} | (${14} << 8) | (${15} << 16) | (${16} << 24) ))
    [ "$TRAILER_LEN" -eq "$UBOOT_BYTES" ] &&
    [ $(( (TRAILER_LEN ^ TRAILER_INV) & 0xffffffff )) -eq $((0xffffffff)) ] &&
    [ "$TRAILER_VER" -eq 1 ] || {
        echo "error: U-Boot NOR trailer does not match production U-Boot" >&2
        exit 1
    }

    make_erased_image()
    {
        output="$1"
        bytes="$2"
        rm -f "$output"
        dd if=/dev/zero bs="$bytes" count=1 2>/dev/null |
            tr '\000' '\377' > "$output"
    }

    NOR_AT91="$BINARIES_DIR/nor-at91bootstrap.bin"
    NOR_UBOOT="$BINARIES_DIR/nor-uboot.bin"
    NOR_ENV="$BINARIES_DIR/nor-uboot-env.bin"
    NOR_IMAGE="$BINARIES_DIR/nor.img"

    [ "$(wc -c < "$BINARIES_DIR/boot.bin" | tr -d '[:space:]')" -le $((0x8000)) ] || {
        echo "error: AT91Bootstrap exceeds 32 KiB NOR partition" >&2
        exit 1
    }

    make_erased_image "$NOR_AT91" $((0x8000))
    dd if="$BINARIES_DIR/boot.bin" of="$NOR_AT91" bs=1 conv=notrunc 2>/dev/null

    make_erased_image "$NOR_UBOOT" $((0x138000))
    dd if="$BINARIES_DIR/u-boot.bin" of="$NOR_UBOOT" bs=1 conv=notrunc 2>/dev/null
    dd if="$BINARIES_DIR/u-boot.nor-trailer" of="$NOR_UBOOT"         bs=1 seek=$((0x137ff0)) conv=notrunc 2>/dev/null

    # Production provisioning deliberately invalidates any old/test U-Boot
    # environment. Compiled defaults boot the new NAND image and the normal
    # factory-identity path creates redundant copies when identity is saved.
    make_erased_image "$NOR_ENV" $((0x20000))

    make_erased_image "$NOR_IMAGE" $((0x200000))
    dd if="$NOR_AT91" of="$NOR_IMAGE" bs=1 conv=notrunc 2>/dev/null
    dd if="$NOR_UBOOT" of="$NOR_IMAGE" bs=1 seek=$((0x8000)) conv=notrunc 2>/dev/null
    dd if="$NOR_ENV" of="$NOR_IMAGE" bs=1 seek=$((0x140000)) conv=notrunc 2>/dev/null

    install -m 0755 "$SCRIPT_DIR/program-nextgen-flash.sh"         "$BINARIES_DIR/program-nextgen-flash.sh"

    (
        cd "$BINARIES_DIR"
        sha256sum             boot.bin u-boot.bin u-boot.nor-trailer uboot.env             zImage nextgen.dtb rootfs.squashfs persist.ubifs             boot.ubi rootfs.ubi             nor-at91bootstrap.bin nor-uboot.bin nor-uboot-env.bin nor.img             > nextgen-flash-manifest.sha256
    )

    /bin/sh "$SCRIPT_DIR/make-production-provision-bundle.sh"         "$BINARIES_DIR/production-provision"         "$BINARIES_DIR/boot.bin"         "$BINARIES_DIR/u-boot.bin"         "$BINARIES_DIR/u-boot.nor-trailer"         "$BINARIES_DIR/boot.ubi"         "$BINARIES_DIR/rootfs.ubi"         "$PRODUCT"

    echo "NextGen RO image verification: NAND boot + system + persist sources OK"
    echo "NextGen initial app image:       $SLOT_IMAGE ($SLOT_BYTES bytes)"
    echo "NextGen RO system image:         $BINARIES_DIR/rootfs.squashfs"
    echo "NextGen UBIFS persist seed:      $PERSIST_UBIFS"
    echo "NextGen NAND boot UBI:           $BINARIES_DIR/boot.ubi"
    echo "NextGen NAND system/persist UBI: $BINARIES_DIR/rootfs.ubi"
    echo "NextGen NOR image:               $NOR_IMAGE"
    echo "NextGen provision bundle:        $BINARIES_DIR/production-provision"
    ;;
esac
