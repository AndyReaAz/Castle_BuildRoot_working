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
    product="$2"
    generation="$3"
    serial="$4"
    manufacturer="$5"
    modeltype="$6"
    valid="$7"
    legacy="$8"

    python3 - "$path" "$product" "$generation" "$serial" "$manufacturer" "$modeltype" "$valid" "$legacy" <<'PY'
import struct
import sys

path, product, generation, serial, manufacturer, modeltype, valid, legacy = sys.argv[1:]
generation = int(generation)
serial = int(serial)
manufacturer = int(manufacturer)
modeltype = int(modeltype)
legacy = legacy == "1"

manufacturer_names = {
    1: "Castle Group",
    2: "SKC",
    3: "Pulsar Instruments",
    4: "Cirrus Research",
}

if product == "sound":
    if manufacturer == 2:
        product_name = "SoundCHEK PRO" if modeltype == 3 else "SoundCHEK"
    else:
        product_name = {
            0: "Sonik Meter",
            1: "dBAir",
            2: "dBAngel",
            3: "dBAir Pro",
        }.get(modeltype, "Sonik Meter")
else:
    if manufacturer == 3:
        product_name = "vB2"
    elif manufacturer != 1:
        product_name = "Triax"
    else:
        product_name = {
            128: "VIBA(8)",
            129: "VIBAir",
            130: "VEXO",
            131: "VIBA(8) V2",
        }.get(modeltype, "VIBA(8)")

parts = []
if not legacy:
    parts.extend([
        '"FileFormat":"NextGenSettings"',
        '"SchemaVersion":1',
        '"Product":"%s"' % product,
    ])
parts.append('"Index":%d' % generation)
if not legacy:
    parts.extend([
        '"ManufacturerName":"%s"' % manufacturer_names.get(manufacturer, "Castle Group"),
        '"ProductName":"%s"' % product_name,
    ])
parts.extend([
    '"SerialNumber":%d' % serial,
    '"Manufacturer":%d' % manufacturer,
])
if valid == "1":
    parts.append('"ModelType":%d' % modeltype)
parts.append('"Template":{}')
text = "{ " + ", ".join(parts) + " }"

with open(path, "wb") as out:
    if legacy:
        out.write(struct.pack("<I", generation))
    out.write(text.encode("ascii"))
PY
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
    serial="$2"
    manufacturer="$3"
    modeltype="$4"
    manufacturer_name="$5"
    product_name="$6"

    printf '%s\n' "$output" | grep -qx "SerialNumber=$serial" ||
        { echo "FAIL: serial mismatch: $output" >&2; exit 1; }
    printf '%s\n' "$output" | grep -qx "Manufacturer=$manufacturer" ||
        { echo "FAIL: manufacturer mismatch: $output" >&2; exit 1; }
    printf '%s\n' "$output" | grep -qx "ModelType=$modeltype" ||
        { echo "FAIL: model type mismatch: $output" >&2; exit 1; }
    printf '%s\n' "$output" | grep -qx "ManufacturerName=$manufacturer_name" ||
        { echo "FAIL: manufacturer name mismatch: $output" >&2; exit 1; }
    printf '%s\n' "$output" | grep -qx "ProductName=$product_name" ||
        { echo "FAIL: product name mismatch: $output" >&2; exit 1; }
}

write_fixture "$S0" sound 10 123456 1 1 1 0
write_fixture "$S1" sound 11 654321 2 3 1 0
assert_identity "$(identity sound)" 654321 2 3 "SKC" "SoundCHEK PRO"
echo "PASS: newest pure-JSON settings generation supplies sound USB identity"

write_fixture "$S0" sound 20 123456 1 1 1 1
write_fixture "$S1" sound 21 654321 2 3 1 1
assert_identity "$(identity sound)" 654321 2 3 "SKC" "SoundCHEK PRO"
echo "PASS: legacy prefixed settings remain readable"

python3 - "$S1" <<'PY'
import struct
import sys
path = sys.argv[1]
with open(path, "rb") as source:
    data = source.read()
with open(path, "wb") as target:
    target.write(struct.pack("<I", 22))
    target.write(data[4:])
PY
assert_identity "$(identity sound)" 123456 1 1 "Castle Group" "dBAir"
echo "PASS: legacy generation header/JSON index mismatch is rejected"

write_fixture "$S1" sound 22 999999 2 3 0 0
assert_identity "$(identity sound)" 123456 1 1 "Castle Group" "dBAir"
echo "PASS: newer malformed pure-JSON settings file is ignored"

write_fixture "$S1" vibra 23 999999 3 128 1 0
assert_identity "$(identity sound)" 123456 1 1 "Castle Group" "dBAir"
echo "PASS: settings metadata for the wrong product is rejected"

write_fixture "$S0" vibra 30 123456 1 130 1 0
write_fixture "$S1" vibra 31 234567 3 128 1 0
assert_identity "$(identity vibra)" 234567 3 128 "Pulsar Instruments" "vB2"
echo "PASS: Pulsar vibration USB branding comes from generated metadata"

write_fixture "$S1" vibra 29 234567 3 128 1 0
assert_identity "$(identity vibra)" 123456 1 130 "Castle Group" "VEXO"
echo "PASS: all current Castle vibration model types are accepted"

rm -f "$S0" "$S1"
assert_identity "$(identity sound)" 0 0 0 "Castle Group" "Sonik Meter"
echo "PASS: missing settings fall back to generic USB identity"

echo "All USB identity tests passed"
