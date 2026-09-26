#!/bin/sh
# A sourced validation library must not modify a caller's transaction state.
set -eu
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
PRODUCT=sound
PLATFORM_ABI=1
APP_ROOT="$TMP/app"
FACTORY_ROOT="$TMP/factory"
ACTIVE_MOUNT="$FACTORY_ROOT"
mkdir -p "$APP_ROOT" "$FACTORY_ROOT/BaseHPD"
printf 'candidate fixture\n' > "$APP_ROOT/slotA.sqfs"
printf '#!/bin/sh\nexit 0\n' > "$FACTORY_ROOT/NextGen"
chmod 0755 "$FACTORY_ROOT/NextGen"
: > "$FACTORY_ROOT/Translations.csv"
: > "$FACTORY_ROOT/BaseHPD/hpdc.csv"
printf 'format=4\nproduct=sound\nversion=110\nplatform_abi=1\n' > "$FACTORY_ROOT/bundle.info"
cp "$FACTORY_ROOT/bundle.info" "$APP_ROOT/slotA.meta"
printf 'bytes=%s\nsha256=%s\n' "$(wc -c < "$APP_ROOT/slotA.sqfs")" \
    "$(sha256sum "$APP_ROOT/slotA.sqfs" | awk '{print $1}')" >> "$APP_ROOT/slotA.meta"
. "$HERE/../nextgen-slot-common-ro.sh"
ref=caller_ref; version=111; image=candidate.sqfs; meta=candidate.meta
bytes=65; expected=expected_hash; actual=actual_hash; value=caller_value
info=caller_info; key=caller_key; file=caller_file; count=caller_count
expected_version=caller_expected_version
snapshot()
{
    printf '%s|' "$ref" "$version" "$image" "$meta" "$bytes" \
        "$expected" "$actual" "$value" "$info" "$key" "$file" \
        "$count" "$expected_version"
}
before="$(snapshot)"
nextgen_meta_value version "$FACTORY_ROOT/bundle.info" >/dev/null
nextgen_slot_version slotA >/dev/null
nextgen_factory_version >/dev/null
nextgen_slot_valid slotA
nextgen_slot_valid factory
nextgen_mounted_app_valid 110
[ "$(snapshot)" = "$before" ] || {
    echo 'FAIL: slot validation changed caller transaction variables' >&2
    exit 1
}
echo 'PASS: slot/factory/mounted validation preserves caller transaction state'
