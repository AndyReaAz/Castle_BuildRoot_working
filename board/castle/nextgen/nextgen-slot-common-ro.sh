#!/bin/sh
# Shared validation helpers for RO-root Application image slots.
# Callers define PRODUCT, APP_ROOT, FACTORY_ROOT and PLATFORM_ABI first.
# These are read-only queries: stdout and exit status are their only outputs.
# Subshell bodies isolate scratch variables from the caller and nested helpers.
# In particular, validating an accepted slot must not replace the installer's
# candidate version, image name, byte count or digest.

nextgen_valid_ref()
{
    case "$1" in
        slotA|slotB|factory) return 0 ;;
        *) return 1 ;;
    esac
}

nextgen_meta_value()
(
    key="$1"
    file="$2"
    count="$(grep -c "^$key=" "$file" 2>/dev/null || true)"
    [ "$count" -eq 1 ] || return 1
    sed -n "s/^$key=//p" "$file"
)

nextgen_slot_image()
{
    case "$1" in
        slotA|slotB) printf '%s/%s.sqfs\n' "$APP_ROOT" "$1" ;;
        *) return 1 ;;
    esac
}

nextgen_slot_meta()
{
    case "$1" in
        slotA|slotB) printf '%s/%s.meta\n' "$APP_ROOT" "$1" ;;
        *) return 1 ;;
    esac
}

nextgen_factory_version()
(
    info="$FACTORY_ROOT/bundle.info"
    [ -r "$info" ] || return 1
    [ "$(nextgen_meta_value format "$info" 2>/dev/null || true)" = 4 ] || return 1
    [ "$(nextgen_meta_value product "$info" 2>/dev/null || true)" = "$PRODUCT" ] || return 1
    [ "$(nextgen_meta_value platform_abi "$info" 2>/dev/null || true)" = "$PLATFORM_ABI" ] || return 1
    value="$(nextgen_meta_value version "$info" 2>/dev/null || true)"
    case "$value" in ''|*[!0-9]*) return 1 ;; esac
    [ "$value" -gt 0 ] && [ "$value" -le 2147483647 ] || return 1
    printf '%s\n' "$value"
)

nextgen_slot_version()
(
    ref="$1"
    nextgen_valid_ref "$ref" || return 1

    if [ "$ref" = factory ]; then
        nextgen_factory_version
        return
    fi

    meta="$(nextgen_slot_meta "$ref")" || return 1
    [ -r "$meta" ] && [ ! -L "$meta" ] || return 1
    [ "$(nextgen_meta_value format "$meta" 2>/dev/null || true)" = 4 ] || return 1
    [ "$(nextgen_meta_value product "$meta" 2>/dev/null || true)" = "$PRODUCT" ] || return 1
    [ "$(nextgen_meta_value platform_abi "$meta" 2>/dev/null || true)" = "$PLATFORM_ABI" ] || return 1
    value="$(nextgen_meta_value version "$meta" 2>/dev/null || true)"
    case "$value" in ''|*[!0-9]*) return 1 ;; esac
    [ "$value" -gt 0 ] && [ "$value" -le 2147483647 ] || return 1
    printf '%s\n' "$value"
)

nextgen_slot_valid()
(
    ref="$1"
    nextgen_valid_ref "$ref" || return 1

    if [ "$ref" = factory ]; then
        version="$(nextgen_factory_version 2>/dev/null || true)"
        [ -n "$version" ] &&
        [ -x "$FACTORY_ROOT/NextGen" ] &&
        [ -r "$FACTORY_ROOT/Translations.csv" ] &&
        { [ "$PRODUCT" != sound ] || [ -r "$FACTORY_ROOT/BaseHPD/hpdc.csv" ]; }
        return
    fi

    image="$(nextgen_slot_image "$ref")" || return 1
    meta="$(nextgen_slot_meta "$ref")" || return 1
    [ -f "$image" ] && [ ! -L "$image" ] &&
    [ -r "$meta" ] && [ ! -L "$meta" ] || return 1

    version="$(nextgen_slot_version "$ref" 2>/dev/null || true)"
    [ -n "$version" ] || return 1

    bytes="$(nextgen_meta_value bytes "$meta" 2>/dev/null || true)"
    case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
    [ "$bytes" -gt 0 ] && [ "$bytes" -le $((64 * 1024 * 1024)) ] || return 1
    [ "$(wc -c < "$image")" -eq "$bytes" ] || return 1

    expected="$(nextgen_meta_value sha256 "$meta" 2>/dev/null || true)"
    [ "${#expected}" -eq 64 ] || return 1
    case "$expected" in *[!0-9A-Fa-f]*) return 1 ;; esac
    expected="$(printf '%s' "$expected" | tr 'A-F' 'a-f')"
    actual="$(sha256sum "$image" | awk '{print $1}')"
    [ "$actual" = "$expected" ]
)

nextgen_mounted_app_valid()
(
    expected_version="$1"
    info="$ACTIVE_MOUNT/bundle.info"

    [ -x "$ACTIVE_MOUNT/NextGen" ] &&
    [ -r "$ACTIVE_MOUNT/Translations.csv" ] &&
    [ -r "$info" ] || return 1

    [ "$(nextgen_meta_value format "$info" 2>/dev/null || true)" = 4 ] &&
    [ "$(nextgen_meta_value product "$info" 2>/dev/null || true)" = "$PRODUCT" ] &&
    [ "$(nextgen_meta_value platform_abi "$info" 2>/dev/null || true)" = "$PLATFORM_ABI" ] &&
    [ "$(nextgen_meta_value version "$info" 2>/dev/null || true)" = "$expected_version" ] &&
    { [ "$PRODUCT" != sound ] || [ -r "$ACTIVE_MOUNT/BaseHPD/hpdc.csv" ]; }
)
