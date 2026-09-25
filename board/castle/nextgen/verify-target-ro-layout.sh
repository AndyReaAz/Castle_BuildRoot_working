#!/bin/sh
set -eu

[ "$#" -eq 4 ] || {
    echo "Usage: $0 <target-dir> <persist-seed> <slot-source> <sound|vibra>" >&2
    exit 2
}

TARGET_DIR="$1"
PERSIST_SEED="$2"
SLOT_SOURCE="$3"
PRODUCT="$4"
ROOT="$TARGET_DIR/opt/nextgen"

fail()
{
    echo "error: NextGen RO target layout: $*" >&2
    exit 1
}

[ "$(cat "$TARGET_DIR/etc/nextgen-storage-schema" 2>/dev/null || true)" = ro-persist-v1 ] ||
    fail "storage schema marker missing"
[ "$(cat "$TARGET_DIR/etc/nextgen-platform-abi" 2>/dev/null || true)" = 1 ] ||
    fail "platform ABI marker missing"

for mountpoint in app data state common/state; do
    [ -d "$ROOT/$mountpoint" ] || fail "mount point $mountpoint missing"
done

[ -d "$ROOT/factory/$PRODUCT" ] || fail "factory Application missing"
[ -x "$ROOT/factory/$PRODUCT/NextGen" ] || fail "factory NextGen missing"
[ -r "$ROOT/factory/$PRODUCT/Translations.csv" ] || fail "factory translations missing"
grep -qx 'format=4' "$ROOT/factory/$PRODUCT/bundle.info" ||
    fail "factory metadata is not image-slot format"
grep -qx 'platform_abi=1' "$ROOT/factory/$PRODUCT/bundle.info" ||
    fail "factory platform ABI mismatch"

[ -d "$SLOT_SOURCE" ] || fail "slot source missing"
[ -x "$SLOT_SOURCE/NextGen" ] || fail "slot-source NextGen missing"
[ -r "$SLOT_SOURCE/Translations.csv" ] || fail "slot-source translations missing"
grep -qx 'format=4' "$SLOT_SOURCE/bundle.info" ||
    fail "slot-source metadata is not image-slot format"

[ -d "$PERSIST_SEED/app/$PRODUCT/active" ] ||
    fail "persistent active mountpoint missing"
[ -d "$PERSIST_SEED/data/$PRODUCT" ] ||
    fail "persistent product data missing"
[ -d "$PERSIST_SEED/state/$PRODUCT" ] ||
    fail "persistent update state missing"
[ -r "$PERSIST_SEED/state/$PRODUCT/accepted" ] ||
    fail "initial accepted state missing"
[ -d "$PERSIST_SEED/os/chrony" ] ||
    fail "persistent chrony state directory missing"
for osdir in NetworkManager/system-connections NetworkManager/state dbus chrony ssh seedrng; do
    [ -d "$PERSIST_SEED/os/$osdir" ] || fail "persistent OS state $osdir missing"
done
grep -q 'bind_one "\$PERSIST/os/chrony" /var/lib/chrony' "$ROOT/platform/bin/persist-init.sh" ||
    fail "chrony state is not rebound to persistent storage"

if [ "$PRODUCT" = sound ]; then
    [ -r "$PERSIST_SEED/data/sound/HPD/hpdc.csv" ] ||
        fail "persistent live HPD seed missing"
    [ -r "$ROOT/factory/sound/BaseHPD/hpdc.csv" ] ||
        fail "factory fallback HPD missing"
    [ -d "$SLOT_SOURCE/Templates" ] ||
        fail "release template directory is missing from slot source"
    [ -d "$ROOT/factory/sound/Templates" ] ||
        fail "release template directory is missing from factory fallback"
    [ -d "$PERSIST_SEED/data/sound/Templates" ] ||
        fail "persistent user-template directory is missing"
    [ -z "$(find "$PERSIST_SEED/data/sound/Templates" -mindepth 1 -maxdepth 1 -type f -name '*.tpl' -print -quit)" ] ||
        fail "release templates leaked into persistent user-template storage"
else
    [ ! -e "$SLOT_SOURCE/Templates" ] ||
        fail "sound release templates leaked into vibration slot source"
    [ ! -e "$ROOT/factory/vibra/Templates" ] ||
        fail "sound release templates leaked into vibration factory"
fi

[ -L "$TARGET_DIR/etc/localtime" ] &&
[ "$(readlink "$TARGET_DIR/etc/localtime")" = ../run/nextgen/localtime ] ||
    fail "localtime is not runtime-backed"
[ -L "$TARGET_DIR/etc/timezone" ] &&
[ "$(readlink "$TARGET_DIR/etc/timezone")" = ../run/nextgen/timezone ] ||
    fail "timezone is not runtime-backed"
[ -L "$TARGET_DIR/etc/umtprd/umtprd.conf" ] &&
[ "$(readlink "$TARGET_DIR/etc/umtprd/umtprd.conf")" = /run/umtprd/umtprd.conf ] ||
    fail "uMTPrd configuration is not runtime-backed"

grep -q '^/dev/root[[:space:]]\+/[[:space:]]\+squashfs[[:space:]]\+ro'     "$TARGET_DIR/etc/fstab" || fail "root is not declared read-only SquashFS"
grep -q '^/dev/mmcblk0p3[[:space:]]\+/persist[[:space:]]\+ext4'     "$TARGET_DIR/etc/fstab" || fail "SD persist partition is missing"
! grep -q '^[^#].*[[:space:]]/sdcard[[:space:]]' "$TARGET_DIR/etc/fstab" ||
    fail "/sdcard must remain Application-mounted for fsck/identity recovery"
grep -q '/opt/nextgen/platform/bin/persist-init.sh' "$TARGET_DIR/etc/inittab" ||
    fail "persist init is not in sysinit"
! grep -q '^[^#].*-o remount,rw /$' "$TARGET_DIR/etc/inittab" ||
    fail "root remount-rw remains enabled"

for helper in persist-init.sh nextgen-slot-common.sh nextgen-update-install nextgen-update-accept; do
    [ -x "$ROOT/platform/bin/$helper" ] || fail "platform helper $helper missing"
done

[ ! -e "$ROOT/app/$PRODUCT/slotA" ] ||
    fail "directory slot leaked into immutable root"
[ ! -e "$ROOT/data/$PRODUCT/SettingsJSON0.dat" ] ||
    fail "mutable settings leaked into immutable root"

echo "NextGen RO target layout OK: product=$PRODUCT"
