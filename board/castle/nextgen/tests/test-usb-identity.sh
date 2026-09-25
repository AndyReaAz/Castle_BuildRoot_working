#!/bin/sh
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
USB_CONTROL="$HERE/../rootfs-overlay/root/Exec/usbcontrol.sh"

command -v python3 >/dev/null 2>&1 || {
    echo "SKIP: python3 is required for USB identity fixture generation" >&2
    exit 77
}

if grep -Eq '(^|[^[:alnum:]_])jq([^[:alnum:]_]|$)' "$USB_CONTROL"; then
    echo "FAIL: usbcontrol.sh still has a jq runtime dependency" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
S0="$TMP/SettingsJSON0.dat"
S1="$TMP/SettingsJSON1.dat"

write_fixture()
{
    path="$1"
    generation="$2"
    serial="$3"
    manufacturer="$4"
    modeltype="$5"
    valid="$6"

    python3 - "$path" "$generation" "$serial" "$manufacturer" "$modeltype" "$valid" <<'PY'
import struct
import sys

path, generation, serial, manufacturer, modeltype, valid = sys.argv[1:]
generation = int(generation)
serial = int(serial)
manufacturer = int(manufacturer)
modeltype = int(modeltype)

if valid == "1":
    text = (
        '{ "Index":%d, "SerialNumber":%d, "Manufacturer":%d, '
        '"ModelType":%d, "Template":{} }'
        % (generation, serial, manufacturer, modeltype)
    )
else:
    # Syntactically plausible settings prefix but deliberately missing
    # ModelType, so it must not be allowed to override the older valid file.
    text = (
        '{ "Index":%d, "SerialNumber":%d, "Manufacturer":%d, '
        '"Template":{} }'
        % (generation, serial, manufacturer)
    )

with open(path, "wb") as f:
    f.write(struct.pack("<I", generation))
    f.write(text.encode("ascii"))
PY
}

identity()
{
    NEXTGEN_SETTINGS0="$S0"     NEXTGEN_SETTINGS1="$S1"         /bin/sh "$USB_CONTROL" identity
}

assert_identity()
{
    output="$1"
    serial="$2"
    manufacturer="$3"
    modeltype="$4"

    printf '%s\n' "$output" | grep -qx "SerialNumber=$serial" ||
        { echo "FAIL: serial mismatch: $output" >&2; exit 1; }
    printf '%s\n' "$output" | grep -qx "Manufacturer=$manufacturer" ||
        { echo "FAIL: manufacturer mismatch: $output" >&2; exit 1; }
    printf '%s\n' "$output" | grep -qx "ModelType=$modeltype" ||
        { echo "FAIL: model type mismatch: $output" >&2; exit 1; }
}

write_fixture "$S0" 10 123456 1 1 1
write_fixture "$S1" 11 654321 2 3 1
assert_identity "$(identity)" 654321 2 3
echo "PASS: newest valid settings generation supplies USB identity"

write_fixture "$S1" 12 999999 2 3 0
assert_identity "$(identity)" 123456 1 1
echo "PASS: newer malformed settings file is ignored"

rm -f "$S0" "$S1"
assert_identity "$(identity)" 0 0 0
echo "PASS: missing settings fall back to generic USB identity"

echo "All USB identity tests passed"
