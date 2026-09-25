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
