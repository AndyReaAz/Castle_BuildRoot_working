#!/bin/sh
set -eu

SCHEMA_FILE="/etc/nextgen-storage-schema"
PERSIST="/persist"
READY="/run/nextgen-persist-ready"
PRODUCT="$(cat /etc/nextgen-product 2>/dev/null || true)"

[ "$(cat "$SCHEMA_FILE" 2>/dev/null || true)" = "ro-persist-v1" ] || exit 0
case "$PRODUCT" in sound|vibra) ;; *)
    echo "NextGen persist: invalid product '$PRODUCT'" >&2
    exit 1
    ;;
esac
rm -f "$READY"

awk -v p="$PERSIST" '
    $2 == p {
        found = 1
        n = split($4, opts, ",")
        for (i = 1; i <= n; i++)
            if (opts[i] == "rw") writable = 1
    }
    END { exit (found && writable) ? 0 : 1 }
' /proc/mounts || {
    echo "NextGen persist: $PERSIST is not mounted read-write" >&2
    exit 1
}

mkdir -p     "$PERSIST/app/$PRODUCT/active"     "$PERSIST/data/$PRODUCT/Templates"     "$PERSIST/state/$PRODUCT"     "$PERSIST/state/platform"     "$PERSIST/common-state"     "$PERSIST/os/NetworkManager/system-connections"     "$PERSIST/os/NetworkManager/state"     "$PERSIST/os/dbus"     "$PERSIST/os/chrony"     "$PERSIST/os/ssh"     "$PERSIST/os/seedrng"

mkdir -p     /var/lib/dbus     /var/lib/NetworkManager     /var/lib/chrony     /var/log     /var/cache     /var/tmp

is_mounted()
{
    awk -v p="$1" '$2 == p { found = 1 } END { exit found ? 0 : 1 }' /proc/mounts
}

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

touch "$READY"
