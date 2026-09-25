#!/bin/sh
set -eu

TARGET_DIR="$1"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PLATFORM_BIN="$TARGET_DIR/opt/nextgen/platform/bin"

mkdir -p "$PLATFORM_BIN"

# A bring-up card must never start the measurement Application. It owns the
# display and storage while provisioning is in progress.
rm -f "$TARGET_DIR/etc/init.d/S00NextGen"

install -m 0755 "$SCRIPT_DIR/nextgen-bringup-screen" \
    "$PLATFORM_BIN/nextgen-bringup-screen"
install -m 0755 "$SCRIPT_DIR/nextgen-bringup.sh" \
    "$PLATFORM_BIN/nextgen-bringup.sh"
install -m 0755 "$SCRIPT_DIR/nextgen-provision-storage" \
    "$PLATFORM_BIN/nextgen-provision-storage"
install -m 0755 "$SCRIPT_DIR/S01NextGenBringup" \
    "$TARGET_DIR/etc/init.d/S01NextGenBringup"

printf '%s\n' bringup-sd-v1 > "$TARGET_DIR/etc/nextgen-storage-schema"
printf '%s\n' bringup-sd > "$TARGET_DIR/etc/nextgen-storage-backend"
printf '%s\n' 1 > "$TARGET_DIR/etc/nextgen-bringup-image"

for script in \
    "$PLATFORM_BIN/nextgen-bringup-screen" \
    "$PLATFORM_BIN/nextgen-bringup.sh" \
    "$PLATFORM_BIN/nextgen-provision-storage" \
    "$TARGET_DIR/etc/init.d/S01NextGenBringup"
do
    /bin/sh -n "$script" || {
        echo "error: invalid bring-up script: $script" >&2
        exit 1
    }
done

echo "NextGen bring-up rootfs staging complete"


# A bring-up card may carry a separately built production payload, but merely
# carrying it must never arm destructive writes.
rm -rf "$TARGET_DIR/opt/nextgen/provision"
rm -f "$TARGET_DIR/etc/nextgen-provision-armed"

BUNDLE_DIR="${NEXTGEN_PROVISION_BUNDLE_DIR:-}"
if [ -n "$BUNDLE_DIR" ]; then
    [ -d "$BUNDLE_DIR" ] || {
        echo "error: provisioning bundle directory does not exist: $BUNDLE_DIR" >&2
        exit 1
    }
    [ -f "$BUNDLE_DIR/manifest.sha256" ] || {
        echo "error: provisioning bundle has no manifest: $BUNDLE_DIR" >&2
        exit 1
    }
    (
        cd "$BUNDLE_DIR"
        sha256sum -c manifest.sha256 >/dev/null
    ) || {
        echo "error: provisioning bundle failed hash verification: $BUNDLE_DIR" >&2
        exit 1
    }

    mkdir -p "$TARGET_DIR/opt/nextgen/provision"
    for artifact in at91bootstrap.bin u-boot.bin u-boot.trailer boot.ubi rootfs.ubi layout.env manifest.sha256
    do
        [ -f "$BUNDLE_DIR/$artifact" ] || {
            echo "error: provisioning bundle is missing $artifact" >&2
            exit 1
        }
        install -m 0644 "$BUNDLE_DIR/$artifact" "$TARGET_DIR/opt/nextgen/provision/$artifact"
    done
    echo "NextGen production provisioning bundle staged from: $BUNDLE_DIR"
fi

ARM_TOKEN="${NEXTGEN_ARM_PROVISIONING:-}"
if [ -n "$ARM_TOKEN" ]; then
    [ "$ARM_TOKEN" = "YES-I-HAVE-HARDWARE-TESTED-NOR-UBI-BOOT" ] || {
        echo "error: refusing unknown NEXTGEN_ARM_PROVISIONING value" >&2
        exit 1
    }
    [ -n "$BUNDLE_DIR" ] || {
        echo "error: refusing to arm provisioning without a production bundle" >&2
        exit 1
    }
    printf '%s\n' "hardware-tested-nor-ubi-v1" > "$TARGET_DIR/etc/nextgen-provision-armed"
    echo "WARNING: destructive NextGen production provisioning is ARMED in this image"
else
    echo "NextGen production provisioning remains DISARMED"
fi
