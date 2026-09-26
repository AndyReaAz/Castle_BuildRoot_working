#!/bin/sh
set -eu

[ "$#" -eq 5 ] || {
    echo "Usage: $0 <target-dir> <persist-seed> <slot-source> <sound|vibra> <sd-ext4|nand-ubi>" >&2
    exit 2
}

TARGET_DIR="$1"
PERSIST_SEED="$2"
SLOT_SOURCE="$3"
PRODUCT="$4"
BACKEND="$5"
ROOT="$TARGET_DIR/opt/nextgen"

fail()
{
    echo "error: NextGen RO target layout: $*" >&2
    exit 1
}

[ "$(cat "$TARGET_DIR/etc/nextgen-storage-schema" 2>/dev/null || true)" = ro-persist-v1 ] ||
    fail "storage schema marker missing"
[ "$(cat "$TARGET_DIR/etc/nextgen-storage-backend" 2>/dev/null || true)" = "$BACKEND" ] ||
    fail "storage backend marker mismatch"
[ "$(cat "$TARGET_DIR/etc/nextgen-platform-abi" 2>/dev/null || true)" = 1 ] ||
    fail "platform ABI marker missing"

for mountpoint in app data state common/state; do
    [ -d "$ROOT/$mountpoint" ] || fail "mount point $mountpoint missing"
done
[ -d "$TARGET_DIR/sdcard" ] && [ ! -L "$TARGET_DIR/sdcard" ] ||
    fail "immutable /sdcard mount point missing"
[ -z "$(find "$TARGET_DIR/sdcard" -mindepth 1 -print -quit)" ] ||
    fail "immutable /sdcard mount point is not empty"
[ -d "$TARGET_DIR/persist" ] && [ ! -L "$TARGET_DIR/persist" ] ||
    fail "immutable /persist mount point missing"
[ -z "$(find "$TARGET_DIR/persist" -mindepth 1 -print -quit)" ] ||
    fail "immutable /persist mount point is not empty"

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
[ -d "$PERSIST_SEED/os/ssh/root" ] ||
    fail "persistent root SSH state directory missing"
[ -L "$TARGET_DIR/root/.ssh" ] &&
[ "$(readlink "$TARGET_DIR/root/.ssh")" = /persist/os/ssh/root ] ||
    fail "root SSH authorized_keys path is not persistent"
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

    for seed in Settings0.json Settings1.json CalFile.json FacCalFile.json FTPQueue.json; do
        [ -s "$PERSIST_SEED/data/sound/$seed" ] ||
            fail "persistent sound JSON seed $seed is missing"
    done

    for template_dir in "$SLOT_SOURCE/Templates" "$ROOT/factory/sound/Templates"; do
        [ -n "$(find "$template_dir" -mindepth 1 -maxdepth 1 -type f -name '*.json' -print -quit)" ] ||
            fail "$template_dir has no JSON release templates"
        for template in "$template_dir"/*.json; do
            [ -f "$template" ] || continue
            grep -Eq '"FileFormat"[[:space:]]*:[[:space:]]*"NextGenTemplate"' "$template" ||
                fail "release template lacks NextGenTemplate metadata: $template"
            grep -Eq '"SchemaVersion"[[:space:]]*:[[:space:]]*1([,[:space:]}]|$)' "$template" ||
                fail "release template lacks schema version 1: $template"
            grep -Eq '"Product"[[:space:]]*:[[:space:]]*"sound"' "$template" ||
                fail "non-sound release template leaked into sound slot: $template"
            grep -Eq '"ModelTypeCompatibility"[[:space:]]*:[[:space:]]*[1-9][0-9]*' "$template" ||
                fail "certified release template lacks explicit model-type compatibility: $template"
        done

        for canonical in BS4142_3RD ENV_3RD NAW_OCT; do
            [ -s "$template_dir/$canonical.json" ] ||
                fail "canonical release template is missing: $template_dir/$canonical.json"
            grep -Eq "\"FileName\"[[:space:]]*:[[:space:]]*\"$canonical\"" "$template_dir/$canonical.json" ||
                fail "release template FileName does not match canonical filename: $template_dir/$canonical.json"
        done
        for obsolete in BS4142_1-3.json ENV3RD.json NAWOCT.json; do
            [ ! -e "$template_dir/$obsolete" ] ||
                fail "obsolete release template filename survived staging: $template_dir/$obsolete"
        done
    done

    [ -z "$(find "$SLOT_SOURCE/Templates" "$ROOT/factory/sound/Templates" "$PERSIST_SEED/data/sound/Templates" -type f -name '*.tpl' -print -quit)" ] ||
        fail "obsolete .tpl template survived RO staging"
    for obsolete in SettingsJSON0.dat SettingsJSON1.dat CalFile.dat FacCalFile.dat FTPQueue.dat; do
        [ ! -e "$PERSIST_SEED/data/sound/$obsolete" ] ||
            fail "obsolete mutable state survived RO staging: $obsolete"
    done
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


NM_CONF="$TARGET_DIR/etc/NetworkManager/conf.d/10-nextgen-unmanaged.conf"
grep -Eq '^[[:space:]]*hostname-mode[[:space:]]*=[[:space:]]*none[[:space:]]*$' "$NM_CONF" ||
    fail "NetworkManager may overwrite the Application-owned hostname"

grep -q '^/dev/root[[:space:]]\+/[[:space:]]\+squashfs[[:space:]]\+ro' "$TARGET_DIR/etc/fstab" ||
    fail "root is not declared read-only SquashFS"
case "$BACKEND" in
    sd-ext4)
        grep -q '^/dev/mmcblk0p3[[:space:]]\+/persist[[:space:]]\+ext4' "$TARGET_DIR/etc/fstab" ||
            fail "SD persist partition is missing"
        [ ! -e "$TARGET_DIR/etc/nextgen-sd-data-only" ] ||
            fail "SD-root image incorrectly declares SD data-only mode"
        ;;
    nand-ubi)
        grep -q '^ubi0:persist[[:space:]]\+/persist[[:space:]]\+ubifs' "$TARGET_DIR/etc/fstab" ||
            fail "NAND persist UBI volume is missing"
        [ -f "$TARGET_DIR/etc/nextgen-sd-data-only" ] ||
            fail "flash-root image does not declare SD data-only mode"
        ;;
    *) fail "unknown storage backend $BACKEND" ;;
esac

! grep -q '^[^#].*[[:space:]]/sdcard[[:space:]]' "$TARGET_DIR/etc/fstab" ||
    fail "/sdcard must remain Application-mounted for fsck/identity recovery"
grep -q '/opt/nextgen/platform/bin/persist-init.sh' "$TARGET_DIR/etc/inittab" ||
    fail "persist init is not in sysinit"
! grep -q '^[^#].*-o remount,rw /$' "$TARGET_DIR/etc/inittab" ||
    fail "root remount-rw remains enabled"

for helper in persist-init.sh nextgen-slot-common.sh nextgen-update-install nextgen-update-accept; do
    [ -x "$ROOT/platform/bin/$helper" ] || fail "platform helper $helper missing"
done

case "$BACKEND" in
    sd-ext4)
        [ -x "$TARGET_DIR/sbin/e2fsck" ] ||
            fail "target e2fsck missing for ext4 persist recovery"
        ;;
    nand-ubi)
        [ -x "$TARGET_DIR/usr/sbin/fsck.ubifs" ] || [ -x "$TARGET_DIR/sbin/fsck.ubifs" ] ||
            fail "target fsck.ubifs missing for NAND persist recovery"
        ;;
esac

[ ! -e "$ROOT/app/$PRODUCT/slotA" ] ||
    fail "directory slot leaked into immutable root"
[ ! -e "$ROOT/data/$PRODUCT/Settings0.json" ] ||
    fail "mutable settings leaked into immutable root"
[ ! -e "$ROOT/data/$PRODUCT/SettingsJSON0.dat" ] ||
    fail "obsolete settings format leaked into immutable root"

echo "NextGen RO target layout OK: product=$PRODUCT backend=$BACKEND"
