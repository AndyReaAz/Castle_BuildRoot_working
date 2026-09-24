#!/bin/sh
set -eu

PRODUCT_FILE=/etc/nextgen-product
ROOT=/opt/nextgen

[ -r "$PRODUCT_FILE" ] || {
    echo "NextGen launcher: missing $PRODUCT_FILE" >&2
    exit 111
}
PRODUCT="$(cat "$PRODUCT_FILE")"
case "$PRODUCT" in
    sound|vibra) ;;
    *) echo "NextGen launcher: invalid product '$PRODUCT'" >&2; exit 111 ;;
esac

APP_ROOT="$ROOT/app/$PRODUCT"
STATE_ROOT="$ROOT/state/$PRODUCT"
PENDING="$STATE_ROOT/pending"
BOOTING="$STATE_ROOT/booting"
ROLLBACK="$STATE_ROOT/rollback"

mkdir -p "$STATE_ROOT"

valid_update_slot()
{
    case "$1" in
        slotA|slotB) return 0 ;;
        *) return 1 ;;
    esac
}

valid_app_ref()
{
    case "$1" in
        slotA|slotB|factory) return 0 ;;
        *) return 1 ;;
    esac
}

slot_app_valid()
{
    valid_app_ref "$1" &&
    [ -x "$APP_ROOT/$1/NextGen" ] &&
    [ -r "$APP_ROOT/$1/Translations.csv" ]
}

atomic_link()
{
    target="$1"
    link="$2"
    tmp="$APP_ROOT/.link.tmp"
    rm -f "$tmp"
    ln -s "$target" "$tmp"
    mv -Tf "$tmp" "$link"
    sync
}

mark_rollback()
{
    printf '%s\n' rollback > "$STATE_ROOT/.rollback.tmp"
    sync
    mv -f "$STATE_ROOT/.rollback.tmp" "$ROLLBACK"
    rm -f "$PENDING" "$BOOTING"
    sync
}

ACTIVE="$(readlink "$APP_ROOT/active" 2>/dev/null || true)"

if [ -f "$PENDING" ]; then
    new=
    old=
    version=
    extra=
    IFS=' ' read -r new old version extra < "$PENDING" || true

    if ! valid_update_slot "$new" || ! valid_app_ref "$old" || [ -n "$extra" ]; then
        echo "NextGen launcher: discarding malformed pending update"
        mark_rollback
    elif [ "$ACTIVE" != "$new" ]; then
        echo "NextGen launcher: incomplete slot switch, keeping $ACTIVE"
        mark_rollback
    else
        BOOT_SLOT="$(cat "$BOOTING" 2>/dev/null || true)"
        ACCEPTED="$(cat "$STATE_ROOT/accepted" 2>/dev/null || true)"
        if [ "$ACCEPTED" = "$new $version" ]; then
            # The application durably accepted the new slot but power may have
            # disappeared before it could clear the transient files.
            echo "NextGen launcher: finalising accepted slot $new version $version"
            rm -f "$PENDING" "$BOOTING"
            sync
        elif [ "$BOOT_SLOT" = "$new" ]; then
            if slot_app_valid "$old"; then
                echo "NextGen launcher: update $version failed acceptance; rolling back $new -> $old"
                atomic_link "$new" "$APP_ROOT/previous"
                atomic_link "$old" "$APP_ROOT/active"
                ACTIVE="$old"
                mark_rollback
            else
                echo "NextGen launcher: previous slot $old is invalid; retaining $new" >&2
                rm -f "$BOOTING"
            fi
        else
            printf '%s\n' "$new" > "$STATE_ROOT/.booting.tmp"
            sync
            mv -f "$STATE_ROOT/.booting.tmp" "$BOOTING"
            sync
            echo "NextGen launcher: trying pending slot $new version $version"
        fi
    fi
elif [ -e "$BOOTING" ]; then
    rm -f "$BOOTING"
fi

ACTIVE="$(readlink "$APP_ROOT/active" 2>/dev/null || true)"
if slot_app_valid "$ACTIVE"; then
    echo "Launching NextGen $PRODUCT $ACTIVE"
    exec "$APP_ROOT/$ACTIVE/NextGen"
fi

PREVIOUS="$(readlink "$APP_ROOT/previous" 2>/dev/null || true)"
if slot_app_valid "$PREVIOUS"; then
    echo "NextGen launcher: active slot invalid; recovering $PREVIOUS"
    atomic_link "$PREVIOUS" "$APP_ROOT/active"
    exec "$APP_ROOT/$PREVIOUS/NextGen"
fi

if slot_app_valid factory; then
    echo "NextGen launcher: both update slots invalid; recovering factory image"
    atomic_link factory "$APP_ROOT/active"
    atomic_link factory "$APP_ROOT/previous"
    if [ -f "$PENDING" ]; then
        mark_rollback
    else
        rm -f "$BOOTING"
        sync
    fi
    exec "$APP_ROOT/active/NextGen"
fi

echo "NextGen launcher: no valid application image" >&2
exit 111
