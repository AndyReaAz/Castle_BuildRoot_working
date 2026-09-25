#!/bin/sh
set -eu

TARGET_DIR="$1"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BUILDROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE_DIR="$(CDPATH= cd -- "$BUILDROOT_DIR/.." && pwd)"
APP_DIR="${NEXTGEN_APP_DIR:-$WORKSPACE_DIR/app}"
OUT_DIR="$(dirname "$TARGET_DIR")"
PRODUCT="$(cat "$TARGET_DIR/etc/nextgen-product")"

case "$PRODUCT" in sound|vibra) ;; *) echo "error: invalid product $PRODUCT" >&2; exit 1 ;; esac

ROOT="$TARGET_DIR/opt/nextgen"
OLD_APP="$ROOT/app/$PRODUCT"
OLD_DATA="$ROOT/data"
OLD_STATE="$ROOT/state"
OLD_COMMON_STATE="$ROOT/common/state"
FACTORY="$ROOT/factory/$PRODUCT"
PERSIST_SEED="$OUT_DIR/nextgen-persist-seed"
SLOT_SOURCE="$OUT_DIR/nextgen-app-slot-source"

[ -d "$OLD_APP/slotA" ] || { echo "error: RO transform has no slotA" >&2; exit 1; }
[ -d "$OLD_APP/factory" ] || { echo "error: RO transform has no factory slot" >&2; exit 1; }

VERSION="$(sed -n 's/^version=//p' "$OLD_APP/slotA/bundle.info")"
case "$VERSION" in ''|*[!0-9]*) echo "error: invalid staged Application version" >&2; exit 1 ;; esac

rm -rf "$PERSIST_SEED" "$SLOT_SOURCE"
mkdir -p     "$PERSIST_SEED/app/$PRODUCT/active"     "$PERSIST_SEED/data"     "$PERSIST_SEED/state"     "$PERSIST_SEED/common-state"     "$PERSIST_SEED/os/NetworkManager/system-connections"     "$PERSIST_SEED/os/NetworkManager/state"     "$PERSIST_SEED/os/dbus"     "$PERSIST_SEED/os/ssh"     "$PERSIST_SEED/os/seedrng"

cp -a "$OLD_DATA/." "$PERSIST_SEED/data/"
cp -a "$OLD_STATE/." "$PERSIST_SEED/state/"
cp -a "$OLD_COMMON_STATE/." "$PERSIST_SEED/common-state/"
cp -a "$OLD_APP/slotA" "$SLOT_SOURCE"

# Certified/built-in templates are Application-release content. The old
# staging tree placed them in writable data for historical reasons; remove
# those copies from persist and put the authoritative set in the slot image.
rm -rf "$PERSIST_SEED/data/$PRODUCT/Templates"
mkdir -p "$PERSIST_SEED/data/$PRODUCT/Templates"
if [ "$PRODUCT" = sound ] && [ -d "$APP_DIR/Application/Files/SystemTemplates" ]; then
    mkdir -p "$SLOT_SOURCE/Templates"
    cp -a "$APP_DIR/Application/Files/SystemTemplates/." "$SLOT_SOURCE/Templates/"
fi

rm -rf "$ROOT/factory"
mkdir -p "$FACTORY"
cp -a "$OLD_APP/factory/." "$FACTORY/"
if [ "$PRODUCT" = sound ] && [ -d "$APP_DIR/Application/Files/SystemTemplates" ]; then
    mkdir -p "$FACTORY/Templates"
    cp -a "$APP_DIR/Application/Files/SystemTemplates/." "$FACTORY/Templates/"
fi

for appdir in "$SLOT_SOURCE" "$FACTORY"; do
    cat > "$appdir/bundle.info" <<EOF
format=4
product=$PRODUCT
version=$VERSION
platform_abi=1
EOF
done

# Seed the independently-managed live HPD database once. Future Application
# image changes never overwrite this file.
if [ "$PRODUCT" = sound ] && [ -r "$SLOT_SOURCE/BaseHPD/hpdc.csv" ]; then
    mkdir -p "$PERSIST_SEED/data/sound/HPD"
    install -m 0644 "$SLOT_SOURCE/BaseHPD/hpdc.csv"         "$PERSIST_SEED/data/sound/HPD/hpdc.csv"
fi

# NetworkManager profiles are device state, not immutable system content.
for connection in "$TARGET_DIR"/etc/NetworkManager/system-connections/*.nmconnection; do
    [ -f "$connection" ] || continue
    install -m 0600 "$connection"         "$PERSIST_SEED/os/NetworkManager/system-connections/$(basename "$connection")"
done
rm -rf "$TARGET_DIR/etc/NetworkManager/system-connections"
mkdir -p "$TARGET_DIR/etc/NetworkManager/system-connections"

# Remove mutable trees from the system image and leave only mount points.
rm -rf "$ROOT/app" "$ROOT/data" "$ROOT/state" "$ROOT/common/state"
mkdir -p     "$ROOT/app"     "$ROOT/data"     "$ROOT/state"     "$ROOT/common/state"     "$TARGET_DIR/persist"     "$TARGET_DIR/var/lib"     "$TARGET_DIR/var/log"     "$TARGET_DIR/var/cache"     "$TARGET_DIR/var/tmp"

install -m 0755 "$SCRIPT_DIR/persist-init-ro.sh"     "$ROOT/platform/bin/persist-init.sh"
install -m 0755 "$SCRIPT_DIR/startup-ro.sh"     "$TARGET_DIR/root/startup.sh"
install -m 0755 "$SCRIPT_DIR/nextgen-slot-common-ro.sh"     "$ROOT/platform/bin/nextgen-slot-common.sh"
install -m 0755 "$SCRIPT_DIR/nextgen-update-install-ro"     "$ROOT/platform/bin/nextgen-update-install"
install -m 0755 "$SCRIPT_DIR/nextgen-update-accept-ro"     "$ROOT/platform/bin/nextgen-update-accept"

printf '%s\n' ro-persist-v1 > "$TARGET_DIR/etc/nextgen-storage-schema"
printf '%s\n' 1 > "$TARGET_DIR/etc/nextgen-platform-abi"

# Timezone selection is Settings-owned. Immutable /etc points at runtime
# files rebuilt by the Application under /run.
rm -f "$TARGET_DIR/etc/localtime" "$TARGET_DIR/etc/timezone"
ln -s ../run/nextgen/localtime "$TARGET_DIR/etc/localtime"
ln -s ../run/nextgen/timezone "$TARGET_DIR/etc/timezone"

mkdir -p "$TARGET_DIR/etc/default"
cat > "$TARGET_DIR/etc/default/seedrng" <<'EOF'
SEEDRNG_ARGS="--seed-dir=/persist/os/seedrng"
EOF

cat > "$TARGET_DIR/etc/fstab" <<'EOF'
# NextGen RO-root test layout
/dev/root       /           squashfs ro,noauto                                      0 0
proc            /proc       proc     defaults                                       0 0
devpts          /dev/pts    devpts   defaults,gid=5,mode=620,ptmxmode=0666          0 0
tmpfs           /dev/shm    tmpfs    mode=1777                                      0 0
tmpfs           /tmp        tmpfs    mode=1777                                      0 0
tmpfs           /run        tmpfs    mode=0755,nosuid,nodev                         0 0
tmpfs           /var/lib    tmpfs    mode=0755,nosuid,nodev                         0 0
tmpfs           /var/log    tmpfs    mode=0755,nosuid,nodev                         0 0
tmpfs           /var/cache  tmpfs    mode=0755,nosuid,nodev                         0 0
tmpfs           /var/tmp    tmpfs    mode=1777,nosuid,nodev                         0 0
sysfs           /sys        sysfs    defaults                                       0 0
/dev/mmcblk0p3  /persist    ext4     rw,noatime,nosuid,nodev,errors=remount-ro       0 2
/dev/mmcblk0p1  /boot       vfat     defaults,noauto                                0 2
EOF

# Buildroot's RO-root Kconfig must have commented the generic remount-rw line.
if grep -q '^[^#].*-o remount,rw /$' "$TARGET_DIR/etc/inittab"; then
    echo "error: RO image still remounts / read-write" >&2
    exit 1
fi

if ! grep -q '/opt/nextgen/platform/bin/persist-init.sh' "$TARGET_DIR/etc/inittab"; then
    sed -i '\|::sysinit:/bin/mount -a|a::sysinit:/opt/nextgen/platform/bin/persist-init.sh'         "$TARGET_DIR/etc/inittab"
fi

for script in     "$ROOT/platform/bin/persist-init.sh"     "$TARGET_DIR/root/startup.sh"     "$ROOT/platform/bin/nextgen-slot-common.sh"     "$ROOT/platform/bin/nextgen-update-install"     "$ROOT/platform/bin/nextgen-update-accept"
do
    /bin/sh -n "$script" || {
        echo "error: invalid RO-root helper $script" >&2
        exit 1
    }
done

/bin/sh "$SCRIPT_DIR/verify-target-ro-layout.sh"     "$TARGET_DIR" "$PERSIST_SEED" "$SLOT_SOURCE" "$PRODUCT"

echo "NextGen RO-root staging complete: product=$PRODUCT version=$VERSION"
