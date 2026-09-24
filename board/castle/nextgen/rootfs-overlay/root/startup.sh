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

slot_version()
{
    ref="$1"
    valid_app_ref "$ref" || return 1
    info="$APP_ROOT/$ref/bundle.info"
    [ -r "$info" ] || return 1
    [ "$(sed -n 's/^format=//p' "$info")" = 3 ] || return 1
    [ "$(sed -n 's/^product=//p' "$info")" = "$PRODUCT" ] || return 1
    value="$(sed -n 's/^version=//p' "$info")"
    case "$value" in ''|*[!0-9]*) return 1 ;; esac
    [ "$value" -gt 0 ] && [ "$value" -le 2147483647 ] || return 1
    printf '%s\n' "$value"
}

slot_app_valid()
{
    ref="$1"
    slot_version "$ref" >/dev/null 2>&1 &&
    [ -x "$APP_ROOT/$ref/NextGen" ] &&
    [ -r "$APP_ROOT/$ref/Translations.csv" ] &&
    { [ "$PRODUCT" != sound ] || [ -r "$APP_ROOT/$ref/BaseHPD/hpdc.csv" ]; }
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

# Once rollback intent is durable it wins over any stale pending/booting files
# left by a power cut in mark_rollback(). Keep the marker for the application
# acceptance helper, which repairs the removable-media download state.
if [ -f "$ROLLBACK" ]; then
    rm -f "$PENDING" "$BOOTING"
    sync
fi

if [ -f "$PENDING" ]; then
    new=
    old=
    version=
    extra=
    IFS=' ' read -r new old version extra < "$PENDING" || true

    if ! valid_update_slot "$new" || ! valid_app_ref "$old" ||
       [ -n "$extra" ]; then
        echo "NextGen launcher: discarding malformed pending update"
        PREVIOUS="$(readlink "$APP_ROOT/previous" 2>/dev/null || true)"
        if slot_app_valid "$PREVIOUS"; then
            atomic_link "$PREVIOUS" "$APP_ROOT/active"
            ACTIVE="$PREVIOUS"
        elif slot_app_valid factory; then
            atomic_link factory "$APP_ROOT/active"
            atomic_link factory "$APP_ROOT/previous"
            ACTIVE=factory
        fi
        mark_rollback
    else
        case "$version" in ''|*[!0-9]*) version=0 ;; esac
        candidate_version="$(slot_version "$new" 2>/dev/null || echo 0)"
        if [ "$version" -le 0 ] || [ "$version" -gt 2147483647 ] ||
           [ "$candidate_version" != "$version" ]; then
            echo "NextGen launcher: pending metadata does not match candidate"
            if slot_app_valid "$old"; then
                atomic_link "$old" "$APP_ROOT/active"
                atomic_link "$old" "$APP_ROOT/previous"
                ACTIVE="$old"
            elif slot_app_valid factory; then
                atomic_link factory "$APP_ROOT/active"
                atomic_link factory "$APP_ROOT/previous"
                ACTIVE=factory
            fi
            mark_rollback
        else
        ACTIVE="$(readlink "$APP_ROOT/active" 2>/dev/null || true)"
        BOOT_SLOT="$(cat "$BOOTING" 2>/dev/null || true)"
        ACCEPTED="$(cat "$STATE_ROOT/accepted" 2>/dev/null || true)"

        if [ "$ACCEPTED" = "$new $version" ] && [ "$ACTIVE" = "$new" ]; then
            # Acceptance was durable; only transient cleanup was interrupted.
            echo "NextGen launcher: finalising accepted slot $new version $version"
            rm -f "$PENDING" "$BOOTING" "$ROLLBACK"
            sync

        elif [ "$ACTIVE" = "$old" ]; then
            # Normal first boot after installation: old release is still live.
            if slot_app_valid "$new" && slot_app_valid "$old"; then
                atomic_link "$old" "$APP_ROOT/previous"
                atomic_link "$new" "$APP_ROOT/active"
                printf '%s\n' "$new" > "$STATE_ROOT/.booting.tmp"
                sync
                mv -f "$STATE_ROOT/.booting.tmp" "$BOOTING"
                sync
                ACTIVE="$new"
                echo "NextGen launcher: trying pending slot $new version $version"
            else
                echo "NextGen launcher: staged or previous slot is invalid; keeping $old"
                mark_rollback
            fi

        elif [ "$ACTIVE" = "$new" ]; then
            if [ "$BOOT_SLOT" = "$new" ]; then
                # The candidate was already launched once and never accepted.
                if slot_app_valid "$old"; then
                    echo "NextGen launcher: update $version failed acceptance; rolling back $new -> $old"
                    atomic_link "$new" "$APP_ROOT/previous"
                    atomic_link "$old" "$APP_ROOT/active"
                    ACTIVE="$old"
                    mark_rollback
                elif slot_app_valid factory; then
                    echo "NextGen launcher: previous slot invalid; rolling back candidate to factory"
                    atomic_link factory "$APP_ROOT/active"
                    atomic_link factory "$APP_ROOT/previous"
                    ACTIVE=factory
                    mark_rollback
                else
                    echo "NextGen launcher: no rollback image is valid; retaining candidate" >&2
                    rm -f "$BOOTING"
                fi
            else
                # Power disappeared after the active rename but before the
                # first-boot marker was durable. Treat this as the first try.
                if slot_app_valid "$new"; then
                    printf '%s\n' "$new" > "$STATE_ROOT/.booting.tmp"
                    sync
                    mv -f "$STATE_ROOT/.booting.tmp" "$BOOTING"
                    sync
                    echo "NextGen launcher: resuming first try of slot $new version $version"
                else
                    echo "NextGen launcher: candidate became invalid before first boot"
                    if slot_app_valid "$old"; then
                        atomic_link "$old" "$APP_ROOT/active"
                        atomic_link "$old" "$APP_ROOT/previous"
                    fi
                    mark_rollback
                fi
            fi

        else
            # The active pointer does not correspond to either side of the
            # prepared transaction. Prefer the known previous image, then
            # factory, and mark the staged update for retry cleanup.
            echo "NextGen launcher: unexpected active slot '$ACTIVE' during update"
            if slot_app_valid "$old"; then
                atomic_link "$old" "$APP_ROOT/active"
                atomic_link "$old" "$APP_ROOT/previous"
                ACTIVE="$old"
            elif slot_app_valid factory; then
                atomic_link factory "$APP_ROOT/active"
                atomic_link factory "$APP_ROOT/previous"
                ACTIVE=factory
            fi
            mark_rollback
        fi
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
