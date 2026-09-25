#!/bin/sh
set -eu

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || {
    echo "Usage: $0 <target-dir> [sound|vibra]" >&2
    exit 2
}

TARGET_DIR="$1"
PRODUCT="${2:-}"
if [ -z "$PRODUCT" ]; then
    [ -r "$TARGET_DIR/etc/nextgen-product" ] || {
        echo "error: missing /etc/nextgen-product in target" >&2
        exit 1
    }
    PRODUCT="$(cat "$TARGET_DIR/etc/nextgen-product")"
fi
case "$PRODUCT" in sound|vibra) ;; *)
    echo "error: invalid NextGen product '$PRODUCT'" >&2
    exit 1
    ;;
esac

ROOT="$TARGET_DIR/opt/nextgen"
APP="$ROOT/app/$PRODUCT"
DATA="$ROOT/data/$PRODUCT"
COMMON_SHARE="$ROOT/common/share"
COMMON_STATE="$ROOT/common/state"
STATE="$ROOT/state/$PRODUCT"
BIN="$ROOT/platform/bin"
SHARE="$ROOT/platform/share"

fail()
{
    echo "error: NextGen target layout: $*" >&2
    exit 1
}

[ -d "$APP/slotA" ] || fail "slotA is missing"
[ -d "$APP/factory" ] || fail "factory slot is missing"
[ "$(readlink "$APP/active" 2>/dev/null || true)" = slotA ] ||
    fail "active does not point at slotA"
[ "$(readlink "$APP/previous" 2>/dev/null || true)" = slotA ] ||
    fail "previous does not point at slotA"

for slot in slotA factory; do
    [ -x "$APP/$slot/NextGen" ] || fail "$slot/NextGen is missing or not executable"
    [ -r "$APP/$slot/Translations.csv" ] || fail "$slot/Translations.csv is missing"
    [ -r "$APP/$slot/bundle.info" ] || fail "$slot/bundle.info is missing"
    grep -qx 'format=3' "$APP/$slot/bundle.info" ||
        fail "$slot has the wrong bundle format"
    grep -qx "product=$PRODUCT" "$APP/$slot/bundle.info" ||
        fail "$slot has the wrong product"
done

if [ "$PRODUCT" = sound ]; then
    for slot in slotA factory; do
        [ -r "$APP/$slot/BaseHPD/hpdc.csv" ] ||
            fail "$slot sound HPD database is missing"
    done
fi

for helper in nextgen-update-install nextgen-update-accept usbcontrol.sh fwenv.sh; do
    [ -x "$BIN/$helper" ] || fail "platform helper $helper is missing"
done

# These were historical development conveniences, not runtime dependencies.
# Keep the finished image honest: usbcontrol.sh must remain self-contained
# rather than silently depending on jq being present.
[ ! -e "$TARGET_DIR/usr/bin/jq" ] || fail "jq unexpectedly remains in target"
[ ! -e "$TARGET_DIR/usr/bin/drm_info" ] || fail "drm_info unexpectedly remains in target"
[ ! -e "$TARGET_DIR/usr/sbin/rsyslogd" ] || fail "rsyslogd unexpectedly remains in target"
if grep -Eq '(^|[^[:alnum:]_])jq([^[:alnum:]_]|$)' "$BIN/usbcontrol.sh"; then
    fail "usbcontrol.sh has an undeclared jq runtime dependency"
fi

# Exercise the installed helper against the staged alternating settings files.
# Vibra development images may legitimately have no settings seed yet, in
# which case usbcontrol.sh must still return the all-zero generic identity.
USB_IDENTITY="$(
    NEXTGEN_PRODUCT="$PRODUCT" \
    NEXTGEN_SETTINGS0="$DATA/SettingsJSON0.dat" \
    NEXTGEN_SETTINGS1="$DATA/SettingsJSON1.dat" \
        /bin/sh "$BIN/usbcontrol.sh" identity
)" || fail "usbcontrol.sh identity parsing failed"
for field in SerialNumber Manufacturer ModelType; do
    value="$(printf '%s\n' "$USB_IDENTITY" | sed -n "s/^$field=//p")"
    case "$value" in
        ''|*[!0-9]*) fail "usbcontrol.sh returned invalid $field identity" ;;
    esac
done
for field in ManufacturerName ProductName; do
    value="$(printf '%s\n' "$USB_IDENTITY" | sed -n "s/^$field=//p")"
    [ -n "$value" ] || fail "usbcontrol.sh returned empty $field"
done

for font in Arial.ttf NotoSansCJKtc-Regular.ttf ionicons.ttf open-iconic.ttf; do
    [ -r "$COMMON_SHARE/$font" ] || fail "platform font $font is missing"
done

[ -d "$DATA" ] || fail "mutable realm data directory is missing"
[ -d "$COMMON_STATE" ] || fail "common state directory is missing"
[ -d "$STATE" ] || fail "realm state directory is missing"

# The current development sound image is deliberately factory/test seeded by
# rootfs-overlay-dev.  Catch any future layout migration that deletes the
# historical /root/Exec overlay before importing these mutable files.
if [ "$PRODUCT" = sound ]; then
    for seed in SettingsJSON0.dat SettingsJSON1.dat CalFile.dat FacCalFile.dat; do
        [ -s "$DATA/$seed" ] || fail "development sound seed $seed is missing or empty"
    done
    [ -f "$COMMON_STATE/engmode" ] ||
        fail "development engineering-mode seed is missing"
fi
[ -r "$STATE/accepted" ] || fail "initial accepted-slot record is missing"

version="$(sed -n 's/^version=//p' "$APP/slotA/bundle.info")"
case "$version" in ''|*[!0-9]*) fail "slotA version is invalid" ;; esac
[ "$(cat "$STATE/accepted")" = "slotA $version" ] ||
    fail "accepted-slot record does not match slotA"

policy="$(cat "$SHARE/update-signing-policy" 2>/dev/null || true)"
case "$policy" in
    ed25519-required)
        [ -r "$SHARE/update-public.pem" ] ||
            fail "signed-update policy has no public key"
        [ -x "$TARGET_DIR/usr/bin/openssl" ] ||
            fail "signed-update policy has no OpenSSL verifier"
        ;;
    unsigned-development)
        [ ! -e "$SHARE/update-public.pem" ] ||
            fail "unsigned development image unexpectedly contains an update public key"
        ;;
    *)
        fail "invalid or missing update signing policy"
        ;;
esac

[ ! -e "$TARGET_DIR/root/Exec" ] || fail "legacy /root/Exec survived staging"
[ ! -e "$TARGET_DIR/root/NextGen" ] || fail "legacy /root/NextGen survived staging"

echo "NextGen target layout OK: product=$PRODUCT version=$version signing=$policy"
