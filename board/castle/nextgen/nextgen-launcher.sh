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

mkdir -p "$STATE_ROOT"

valid_slot()
{
    case "$1" in
        slotA|slotB) return 0 ;;
        *) return 1 ;;
    esac
}

slot_app_valid()
{
    valid_slot "$1" &&
    [ -x "$APP_ROOT/$1/NextGen" ] &&
    [ -r "$APP_ROOT/$1/Translations.csv" ]
}

atomic_link()
{
    target="$1"
    link="$2"
    tmp="$APP_ROOT/.link.$$"
    rm -f "$tmp"
    ln -s "$target" "$tmp"
    mv -Tf "$tmp" "$link"
    sync
}

ACTIVE="$(readlink "$APP_ROOT/active" 2>/dev/null || true)"

if [ -f "$PENDING" ]; then
    new=
    old=
    version=
    extra=
    IFS=' ' read -r new old version extra < "$PENDING" || true

    if ! valid_slot "$new" || ! valid_slot "$old" || [ -n "$extra" ]; then
        echo "NextGen launcher: discarding malformed pending update"
        rm -f "$PENDING" "$BOOTING"
        sync
    elif [ "$ACTIVE" != "$new" ]; then
        echo "NextGen launcher: incomplete slot switch, keeping $ACTIVE"
        rm -f "$PENDING" "$BOOTING"
        sync
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
                rm -f "$PENDING" "$BOOTING"
                sync
            else
                echo "NextGen launcher: previous slot $old is invalid; retaining $new" >&2
                rm -f "$BOOTING"
            fi
        else
            printf '%s\n' "$new" > "$STATE_ROOT/.booting.$"
            sync
            mv -f "$STATE_ROOT/.booting.$" "$BOOTING"
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

if [ -x "$APP_ROOT/factory/NextGen" ] && [ -r "$APP_ROOT/factory/Translations.csv" ]; then
    echo "NextGen launcher: both update slots invalid; launching factory image"
    exec "$APP_ROOT/factory/NextGen"
fi

echo "NextGen launcher: no valid application image" >&2
exit 111
