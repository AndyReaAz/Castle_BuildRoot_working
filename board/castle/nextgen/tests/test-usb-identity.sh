#!/bin/sh
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
USB_CONTROL="$HERE/../rootfs-overlay/root/Exec/usbcontrol.sh"

if grep -Eq '(^|[^[:alnum:]_])jq([^[:alnum:]_]|$)' "$USB_CONTROL"; then
    echo "FAIL: usbcontrol.sh still has a jq runtime dependency" >&2
    exit 1
fi
if grep -Eq 'SettingsJSON|LEGACY_SETTINGS|tail -c \+5|ModelType|Manufacturer[^N]' "$USB_CONTROL"; then
    echo "FAIL: usbcontrol.sh still contains legacy settings/model decoding" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
S0="$TMP/Settings0.json"
S1="$TMP/Settings1.json"

write_fixture()
{
    path="$1"
    product="$2"
    generation="$3"
    usb_serial="$4"
    usb_manufacturer="$5"
    usb_product="$6"

    cat >"$path" <<EOF
{
  "FileFormat": "NextGenSettings",
  "SchemaVersion": 1,
  "Product": "$product",
  "Index": $generation,
  "UsbSerial": "$usb_serial",
  "UsbManufacturer": "$usb_manufacturer",
  "UsbProduct": "$usb_product"
}
EOF
}

identity()
{
    product="$1"
    NEXTGEN_PRODUCT="$product" NEXTGEN_SETTINGS0="$S0" NEXTGEN_SETTINGS1="$S1" \
        /bin/sh "$USB_CONTROL" identity
}

assert_identity()
{
    output="$1"
    index="$2"
    serial="$3"
    manufacturer="$4"
    product="$5"

    printf '%s\n' "$output" | grep -qx "SettingsIndex=$index" ||
        { echo "FAIL: settings index mismatch: $output" >&2; exit 1; }
    printf '%s\n' "$output" | grep -qx "UsbSerial=$serial" ||
        { echo "FAIL: USB serial mismatch: $output" >&2; exit 1; }
    printf '%s\n' "$output" | grep -qx "UsbManufacturer=$manufacturer" ||
        { echo "FAIL: USB manufacturer mismatch: $output" >&2; exit 1; }
    printf '%s\n' "$output" | grep -qx "UsbProduct=$product" ||
        { echo "FAIL: USB product mismatch: $output" >&2; exit 1; }
}

write_fixture "$S0" sound 10 123456 "Castle Group" "dBAir"
write_fixture "$S1" sound 11 654321 "SKC" "SoundCHEK PRO"
assert_identity "$(identity sound)" 11 654321 "SKC" "SoundCHEK PRO"
echo "PASS: newest settings JSON supplies USB identity directly"

cat >"$S1" <<'EOF'
{
  "FileFormat": "NextGenSettings",
  "SchemaVersion": 1,
  "Product": "sound",
  "Index": 12,
  "UsbSerial": "999999",
  "UsbManufacturer": "SKC"
}
EOF
assert_identity "$(identity sound)" 10 123456 "Castle Group" "dBAir"
echo "PASS: incomplete newer settings JSON is ignored"

write_fixture "$S1" vibra 13 999999 "Pulsar Instruments" "vB2"
assert_identity "$(identity sound)" 10 123456 "Castle Group" "dBAir"
echo "PASS: wrong-product settings JSON is ignored"

write_fixture "$S0" vibra 20 123456 "Castle Group" "VEXO"
write_fixture "$S1" vibra 21 234567 "Pulsar Instruments" "vB2"
assert_identity "$(identity vibra)" 21 234567 "Pulsar Instruments" "vB2"
echo "PASS: vibration identity needs no shell model table"

rm -f "$S0" "$S1"
assert_identity "$(identity sound)" "" 000000 "Castle Group" "Sonik Meter"
echo "PASS: missing settings use generic USB identity"

echo "All USB identity tests passed"
