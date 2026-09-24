#!/bin/sh
set -eu

# Production uses the fixed image paths below.  Environment overrides exist only
# so the real launcher can be exercised against an isolated host-side fixture.
PRODUCT_FILE="${NEXTGEN_PRODUCT_FILE:-/etc/nextgen-product}"
ROOT="${NEXTGEN_ROOT:-/opt/nextgen}"

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
ACCEPTED="$STATE_ROOT/accepted"

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
    valid_app_ref "$1" || return 1
    slot_info="$APP_ROOT/$1/bundle.info"
    [ -r "$slot_info" ] || return 1
    [ "$(sed -n 's/^format=//p' "$slot_info")" = 3 ] || return 1
    [ "$(sed -n 's/^product=//p' "$slot_info")" = "$PRODUCT" ] || return 1
    slot_meta_version="$(sed -n 's/^version=//p' "$slot_info")"
    case "$slot_meta_version" in ''|*[!0-9]*) return 1 ;; esac
    [ "$slot_meta_version" -gt 0 ] &&
        [ "$slot_meta_version" -le 2147483647 ] || return 1
    printf '%s\n' "$slot_meta_version"
}

slot_app_valid()
{
    valid_app_ref "$1" &&
    slot_version "$1" >/dev/null 2>&1 &&
    [ -x "$APP_ROOT/$1/NextGen" ] &&
    [ -r "$APP_ROOT/$1/Translations.csv" ] &&
    { [ "$PRODUCT" != sound ] || [ -r "$APP_ROOT/$1/BaseHPD/hpdc.csv" ]; }
}

atomic_link()
{
    link_target="$1"
    link_path="$2"
    link_tmp="$APP_ROOT/.link.tmp"
    rm -f "$link_tmp"
    ln -s "$link_target" "$link_tmp"
    mv -Tf "$link_tmp" "$link_path"
    sync
}

accepted_ref()
{
    accepted_slot=
    accepted_version=
    accepted_extra=
    [ -r "$ACCEPTED" ] || return 1
    IFS=' ' read -r accepted_slot accepted_version accepted_extra < "$ACCEPTED" ||
        return 1
    valid_app_ref "$accepted_slot" || return 1
    case "$accepted_version" in ''|*[!0-9]*) return 1 ;; esac
    [ -z "$accepted_extra" ] || return 1
    [ "$(slot_version "$accepted_slot" 2>/dev/null || true)" = "$accepted_version" ] ||
        return 1
    slot_app_valid "$accepted_slot" || return 1
    printf '%s\n' "$accepted_slot"
}

recover_known_good()
{
    preferred="$1"

    if valid_app_ref "$preferred" && slot_app_valid "$preferred"; then
        atomic_link "$preferred" "$APP_ROOT/active"
        atomic_link "$preferred" "$APP_ROOT/previous"
        return 0
    fi

    known_good="$(accepted_ref 2>/dev/null || true)"
    if [ -n "$known_good" ] && slot_app_valid "$known_good"; then
        atomic_link "$known_good" "$APP_ROOT/active"
        atomic_link "$known_good" "$APP_ROOT/previous"
        return 0
    fi

    previous="$(readlink "$APP_ROOT/previous" 2>/dev/null || true)"
    if valid_app_ref "$previous" && slot_app_valid "$previous"; then
        atomic_link "$previous" "$APP_ROOT/active"
        atomic_link "$previous" "$APP_ROOT/previous"
        return 0
    fi

    if slot_app_valid factory; then
        atomic_link factory "$APP_ROOT/active"
        atomic_link factory "$APP_ROOT/previous"
        return 0
    fi

    return 1
}

mark_rollback()
{
    printf '%s\n' rollback > "$STATE_ROOT/.rollback.tmp"
    sync
    mv -f "$STATE_ROOT/.rollback.tmp" "$ROLLBACK"
    sync
    rm -f "$PENDING" "$BOOTING"
    sync
}

# A durable rollback marker is authoritative. A power cut may have happened
# after it was written but before pending/booting were removed. Recover the
# last accepted slot first and leave the marker for the Application helper,
# which repairs the removable-media download state after /sdcard is mounted.
if [ -f "$ROLLBACK" ]; then
    recover_known_good "" || true
    rm -f "$PENDING" "$BOOTING"
    sync
fi

if [ -f "$PENDING" ] && [ ! -f "$ROLLBACK" ]; then
    new=
    old=
    version=
    extra=
    IFS=' ' read -r new old version extra < "$PENDING" || true

    pending_valid=1
    valid_update_slot "$new" || pending_valid=0
    valid_app_ref "$old" || pending_valid=0
    case "$version" in ''|*[!0-9]*) pending_valid=0 ;; esac
    [ -z "$extra" ] || pending_valid=0

    if [ "$pending_valid" -eq 1 ]; then
        [ "$version" -gt 0 ] && [ "$version" -le 2147483647 ] ||
            pending_valid=0
    fi

    if [ "$pending_valid" -eq 1 ]; then
        candidate_version="$(slot_version "$new" 2>/dev/null || true)"
        [ "$candidate_version" = "$version" ] || pending_valid=0
        slot_app_valid "$new" || pending_valid=0
        slot_app_valid "$old" || pending_valid=0
    fi

    if [ "$pending_valid" -ne 1 ]; then
        echo "NextGen launcher: malformed/inconsistent pending update; rolling back"
        recover_known_good "$old" || true
        mark_rollback
    else
        active="$(readlink "$APP_ROOT/active" 2>/dev/null || true)"
        boot_slot="$(cat "$BOOTING" 2>/dev/null || true)"
        accepted_line="$(cat "$ACCEPTED" 2>/dev/null || true)"

        if [ "$accepted_line" = "$new $version" ] && [ "$active" = "$new" ]; then
            # Acceptance was already durable; only transient state cleanup was
            # interrupted. The Application helper will retry package cleanup.
            echo "NextGen launcher: finalising accepted slot $new version $version"
            rm -f "$PENDING" "$BOOTING" "$ROLLBACK"
            sync

        elif [ "$active" = "$old" ]; then
            # First attempt: OLD is still the running/known-good release.
            atomic_link "$old" "$APP_ROOT/previous"
            atomic_link "$new" "$APP_ROOT/active"
            printf '%s\n' "$new" > "$STATE_ROOT/.booting.tmp"
            sync
            mv -f "$STATE_ROOT/.booting.tmp" "$BOOTING"
            sync
            echo "NextGen launcher: trying pending slot $new version $version"

        elif [ "$active" = "$new" ]; then
            if [ "$boot_slot" = "$new" ]; then
                # The candidate was launched once but never accepted.
                echo "NextGen launcher: update $version failed acceptance; rolling back"
                recover_known_good "$old" || true
                mark_rollback
            elif [ -z "$boot_slot" ]; then
                # Power disappeared after active was switched but before the
                # first-boot marker became durable. This is still attempt one.
                printf '%s\n' "$new" > "$STATE_ROOT/.booting.tmp"
                sync
                mv -f "$STATE_ROOT/.booting.tmp" "$BOOTING"
                sync
                echo "NextGen launcher: resuming first try of slot $new version $version"
            else
                echo "NextGen launcher: inconsistent boot marker; rolling back"
                recover_known_good "$old" || true
                mark_rollback
            fi

        else
            echo "NextGen launcher: unexpected active slot '$active'; rolling back"
            recover_known_good "$old" || true
            mark_rollback
        fi
    fi
elif [ -e "$BOOTING" ]; then
    rm -f "$BOOTING"
    sync
fi

active="$(readlink "$APP_ROOT/active" 2>/dev/null || true)"
if slot_app_valid "$active"; then
    echo "Launching NextGen $PRODUCT $active"
    exec "$APP_ROOT/$active/NextGen"
fi

known_good="$(accepted_ref 2>/dev/null || true)"
if [ -n "$known_good" ] && slot_app_valid "$known_good"; then
    echo "NextGen launcher: active slot invalid; recovering accepted $known_good"
    atomic_link "$known_good" "$APP_ROOT/active"
    atomic_link "$known_good" "$APP_ROOT/previous"
    exec "$APP_ROOT/$known_good/NextGen"
fi

previous="$(readlink "$APP_ROOT/previous" 2>/dev/null || true)"
if valid_app_ref "$previous" && slot_app_valid "$previous"; then
    echo "NextGen launcher: active slot invalid; recovering $previous"
    atomic_link "$previous" "$APP_ROOT/active"
    exec "$APP_ROOT/$previous/NextGen"
fi

if slot_app_valid factory; then
    echo "NextGen launcher: no update slot valid; recovering factory image"
    atomic_link factory "$APP_ROOT/active"
    atomic_link factory "$APP_ROOT/previous"
    [ ! -f "$PENDING" ] || mark_rollback
    exec "$APP_ROOT/factory/NextGen"
fi

echo "NextGen launcher: no valid application image" >&2
exit 111
