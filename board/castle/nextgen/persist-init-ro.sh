#!/bin/sh
set -eu

SCHEMA_FILE="/etc/nextgen-storage-schema"
BACKEND_FILE="/etc/nextgen-storage-backend"
PERSIST="/persist"
READY="/run/nextgen-persist-ready"
PRODUCT="$(cat /etc/nextgen-product 2>/dev/null || true)"
BACKEND="$(cat "$BACKEND_FILE" 2>/dev/null || true)"

[ "$(cat "$SCHEMA_FILE" 2>/dev/null || true)" = "ro-persist-v1" ] || exit 0
case "$BACKEND" in sd-ext4|nand-ubi) ;; *)
    echo "NextGen persist: invalid storage backend '$BACKEND'" >&2
    exit 1
    ;;
esac
case "$PRODUCT" in sound|vibra) ;; *)
    echo "NextGen persist: invalid product '$PRODUCT'" >&2
    exit 1
    ;;
esac
rm -f "$READY"

is_mounted()
{
    awk -v p="$1" '$2 == p { found = 1 } END { exit found ? 0 : 1 }' /proc/mounts
}

persist_is_rw()
{
    awk -v p="$PERSIST" '
        $2 == p {
            found = 1
            n = split($4, opts, ",")
            for (i = 1; i <= n; i++)
                if (opts[i] == "rw") writable = 1
        }
        END { exit (found && writable) ? 0 : 1 }
    ' /proc/mounts
}

ubi_volume_by_name()
{
    wanted="$1"
    for path in /sys/class/ubi/ubi[0-9]*_[0-9]*
    do
        [ -f "$path/name" ] || continue
        [ "$(cat "$path/name" 2>/dev/null || true)" = "$wanted" ] || continue
        printf '/dev/%s\n' "$(basename "$path")"
        return 0
    done
    return 1
}

recover_ext4_persist()
{
    device="$(awk -v p="$PERSIST" '$2 == p { print $1; exit }' /etc/fstab)"
    [ -n "$device" ] && [ -b "$device" ] || return 1
    command -v e2fsck >/dev/null 2>&1 || return 1

    if is_mounted "$PERSIST"; then
        umount "$PERSIST" || return 1
    fi

    rc=0
    e2fsck -p "$device" || rc=$?
    case "$rc" in 0|1) ;; *) return 1 ;; esac

    mount "$PERSIST" || return 1
    persist_is_rw
}

recover_ubifs_persist()
{
    device="$(ubi_volume_by_name persist)" || return 1
    [ -c "$device" ] || return 1
    command -v fsck.ubifs >/dev/null 2>&1 || return 1

    if is_mounted "$PERSIST"; then
        umount "$PERSIST" || return 1
    fi

    rc=0
    fsck.ubifs -a "$device" || rc=$?
    case "$rc" in 0|1) ;; *) return 1 ;; esac

    mount "$PERSIST" || return 1
    persist_is_rw
}

recover_persist()
{
    case "$BACKEND" in
        sd-ext4) recover_ext4_persist ;;
        nand-ubi) recover_ubifs_persist ;;
        *) return 1 ;;
    esac
}

if ! persist_is_rw; then
    echo "NextGen persist: initial $PERSIST mount unavailable on $BACKEND; attempting repair" >&2
    recover_persist || {
        echo "NextGen persist: $PERSIST is not safely mounted read-write" >&2
        exit 1
    }
fi

mkdir -p     "$PERSIST/app/$PRODUCT/active"     "$PERSIST/data/$PRODUCT/Templates"     "$PERSIST/state/$PRODUCT"     "$PERSIST/state/platform"     "$PERSIST/common-state"     "$PERSIST/os/NetworkManager/system-connections"     "$PERSIST/os/NetworkManager/state"     "$PERSIST/os/dbus"     "$PERSIST/os/chrony"     "$PERSIST/os/ssh/root"     "$PERSIST/os/seedrng"
chmod 0700 "$PERSIST/os/ssh/root"

mkdir -p     /var/lib/dbus     /var/lib/NetworkManager     /var/lib/chrony     /var/log     /var/cache     /var/tmp

bind_one()
{
    source="$1"
    target="$2"

    if is_mounted "$target"; then
        return 0
    fi

    mount -o bind "$source" "$target"
}

bind_one "$PERSIST/app" /opt/nextgen/app
bind_one "$PERSIST/data" /opt/nextgen/data
bind_one "$PERSIST/state" /opt/nextgen/state
bind_one "$PERSIST/common-state" /opt/nextgen/common/state
bind_one "$PERSIST/os/NetworkManager/system-connections"     /etc/NetworkManager/system-connections
bind_one "$PERSIST/os/NetworkManager/state" /var/lib/NetworkManager
bind_one "$PERSIST/os/dbus" /var/lib/dbus
bind_one "$PERSIST/os/chrony" /var/lib/chrony

# /etc/localtime and /etc/timezone are immutable symlinks into /run. Seed a
# valid UTC view before the Application loads Settings and replaces both files.
mkdir -p /run/nextgen
if [ ! -e /run/nextgen/localtime ]; then
    ln -s /usr/share/zoneinfo/Etc/UTC /run/nextgen/localtime
fi
if [ ! -e /run/nextgen/timezone ]; then
    printf '%s\n' Etc/UTC > /run/nextgen/timezone
fi

touch "$READY"
