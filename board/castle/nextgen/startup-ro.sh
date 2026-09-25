#!/bin/sh
set -eu

PRODUCT_FILE="${NEXTGEN_PRODUCT_FILE:-/etc/nextgen-product}"
ROOT="${NEXTGEN_ROOT:-/opt/nextgen}"
READY="${NEXTGEN_PERSIST_READY:-/run/nextgen-persist-ready}"
PLATFORM_ABI="$(cat /etc/nextgen-platform-abi 2>/dev/null || true)"

[ -r "$PRODUCT_FILE" ] || { echo "NextGen launcher: missing product" >&2; exit 111; }
PRODUCT="$(cat "$PRODUCT_FILE")"
case "$PRODUCT" in sound|vibra) ;; *) echo "NextGen launcher: invalid product" >&2; exit 111 ;; esac
case "$PLATFORM_ABI" in ''|*[!0-9]*) echo "NextGen launcher: invalid platform ABI" >&2; exit 111 ;; esac
[ -e "$READY" ] || { echo "NextGen launcher: persistent storage unavailable" >&2; exit 111; }

APP_ROOT="$ROOT/app/$PRODUCT"
FACTORY_ROOT="$ROOT/factory/$PRODUCT"
STATE_ROOT="$ROOT/state/$PRODUCT"
ACTIVE_MOUNT="$APP_ROOT/active"
PENDING="$STATE_ROOT/pending"
BOOTING="$STATE_ROOT/booting"
ROLLBACK="$STATE_ROOT/rollback"
ACCEPTED="$STATE_ROOT/accepted"
PREVIOUS="$STATE_ROOT/previous"
RUN_LOOP="${NEXTGEN_RUN_LOOP:-/run/nextgen-app-loop}"
RUN_REF="${NEXTGEN_RUN_REF:-/run/nextgen-app-ref}"
MOUNTS_FILE="${NEXTGEN_MOUNTS_FILE:-/proc/mounts}"

. "$ROOT/platform/bin/nextgen-slot-common.sh"

mkdir -p "$STATE_ROOT" "$ACTIVE_MOUNT"

read_state_ref()
{
    file="$1"
    ref=
    version=
    extra=
    [ -r "$file" ] || return 1
    IFS=' ' read -r ref version extra < "$file" || return 1
    nextgen_valid_ref "$ref" || return 1
    case "$version" in ''|*[!0-9]*) return 1 ;; esac
    [ -z "$extra" ] || return 1
    [ "$(nextgen_slot_version "$ref" 2>/dev/null || true)" = "$version" ] || return 1
    nextgen_slot_valid "$ref" || return 1
    printf '%s %s\n' "$ref" "$version"
}

mark_rollback()
{
    printf '%s\n' rollback > "$STATE_ROOT/.rollback.tmp"
    sync
    mv -f "$STATE_ROOT/.rollback.tmp" "$ROLLBACK"
    rm -f "$PENDING" "$BOOTING"
    sync
}

mounted_here()
{
    awk -v p="$ACTIVE_MOUNT" '$2 == p { found = 1 } END { exit found ? 0 : 1 }' "$MOUNTS_FILE"
}

drop_active_mount()
{
    if mounted_here; then
        umount "$ACTIVE_MOUNT" || return 1
    fi

    if [ -r "$RUN_LOOP" ]; then
        loop="$(cat "$RUN_LOOP" 2>/dev/null || true)"
        [ -z "$loop" ] || losetup -d "$loop" 2>/dev/null || true
    fi

    rm -f "$RUN_LOOP" "$RUN_REF"
}

mount_ref()
{
    ref="$1"
    version="$2"

    if mounted_here &&
       [ "$(cat "$RUN_REF" 2>/dev/null || true)" = "$ref $version" ] &&
       nextgen_mounted_app_valid "$version"; then
        return 0
    fi

    drop_active_mount || return 1

    if [ "$ref" = factory ]; then
        mount -o bind "$FACTORY_ROOT" "$ACTIVE_MOUNT" || return 1
    else
        image="$(nextgen_slot_image "$ref")" || return 1
        loop="$(losetup -f)" || return 1
        if ! losetup "$loop" "$image"; then
            return 1
        fi
        if ! mount -t squashfs -o ro "$loop" "$ACTIVE_MOUNT"; then
            losetup -d "$loop" 2>/dev/null || true
            return 1
        fi
        printf '%s\n' "$loop" > "$RUN_LOOP"
    fi

    if ! nextgen_mounted_app_valid "$version"; then
        drop_active_mount || true
        return 1
    fi

    printf '%s %s\n' "$ref" "$version" > "$RUN_REF"
    return 0
}

choose_known_good()
{
    preferred="$1"
    exclude="$2"

    if [ "$preferred" != "$exclude" ] &&
       nextgen_valid_ref "$preferred" &&
       nextgen_slot_valid "$preferred"; then
        version="$(nextgen_slot_version "$preferred")"
        printf '%s %s\n' "$preferred" "$version"
        return 0
    fi

    accepted="$(read_state_ref "$ACCEPTED" 2>/dev/null || true)"
    if [ -n "$accepted" ]; then
        set -- $accepted
        if [ "$1" != "$exclude" ]; then
            printf '%s\n' "$accepted"
            return 0
        fi
    fi

    previous="$(read_state_ref "$PREVIOUS" 2>/dev/null || true)"
    if [ -n "$previous" ]; then
        set -- $previous
        if [ "$1" != "$exclude" ]; then
            printf '%s\n' "$previous"
            return 0
        fi
    fi

    if [ "$exclude" != factory ] && nextgen_slot_valid factory; then
        printf 'factory %s\n' "$(nextgen_slot_version factory)"
        return 0
    fi

    return 1
}

choice=
old=
new=

if [ -f "$ROLLBACK" ]; then
    rm -f "$PENDING" "$BOOTING"
    sync
    choice="$(choose_known_good "" "" 2>/dev/null || true)"
elif [ -f "$PENDING" ]; then
    new=
    old=
    version=
    extra=
    IFS=' ' read -r new old version extra < "$PENDING" || true

    pending_ok=1
    case "$new" in slotA|slotB) ;; *) pending_ok=0 ;; esac
    nextgen_valid_ref "$old" || pending_ok=0
    case "$version" in ''|*[!0-9]*) pending_ok=0 ;; esac
    [ -z "$extra" ] || pending_ok=0

    if [ "$pending_ok" -eq 1 ]; then
        [ "$(nextgen_slot_version "$new" 2>/dev/null || true)" = "$version" ] ||
            pending_ok=0
        nextgen_slot_valid "$new" || pending_ok=0
    fi

    if [ "$pending_ok" -ne 1 ]; then
        echo "NextGen launcher: invalid pending image; rolling back"
        mark_rollback
        choice="$(choose_known_good "$old" "$new" 2>/dev/null || true)"
    else
        accepted_line="$(cat "$ACCEPTED" 2>/dev/null || true)"
        booting="$(cat "$BOOTING" 2>/dev/null || true)"

        if [ "$accepted_line" = "$new $version" ]; then
            rm -f "$PENDING" "$BOOTING" "$ROLLBACK"
            sync
            choice="$new $version"
        elif [ -z "$booting" ]; then
            printf '%s\n' "$new" > "$STATE_ROOT/.booting.tmp"
            sync
            mv -f "$STATE_ROOT/.booting.tmp" "$BOOTING"
            sync
            echo "NextGen launcher: trying pending image $new version $version"
            choice="$new $version"
        elif [ "$booting" = "$new" ]; then
            echo "NextGen launcher: candidate did not accept; rolling back"
            mark_rollback
            choice="$(choose_known_good "$old" 2>/dev/null || true)"
        else
            echo "NextGen launcher: inconsistent boot marker; rolling back"
            mark_rollback
            choice="$(choose_known_good "$old" 2>/dev/null || true)"
        fi
    fi
else
    rm -f "$BOOTING"
    choice="$(choose_known_good "" "" 2>/dev/null || true)"
fi

[ -n "$choice" ] || {
    echo "NextGen launcher: no valid application image" >&2
    exit 111
}

set -- $choice
ref="$1"
version="$2"

if ! mount_ref "$ref" "$version"; then
    echo "NextGen launcher: failed to mount $ref; selecting fallback" >&2
    if [ -f "$PENDING" ]; then
        mark_rollback
    fi

    fallback="$(choose_known_good "$old" "$ref" 2>/dev/null || true)"
    [ -n "$fallback" ] || {
        echo "NextGen launcher: no fallback application" >&2
        exit 111
    }
    set -- $fallback
    ref="$1"
    version="$2"
    mount_ref "$ref" "$version" || {
        echo "NextGen launcher: fallback $ref is not mountable" >&2
        exit 111
    }
fi

echo "Launching NextGen $PRODUCT $ref version $version"
exec "$ACTIVE_MOUNT/NextGen"
