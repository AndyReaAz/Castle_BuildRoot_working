#!/bin/sh
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$HERE/../../../.." && pwd)"
WRAPPER="$ROOT/build-nextgen-image.sh"

plan()
{
    NEXTGEN_PLAN_ONLY=1 "$WRAPPER" "$@"
}

ro_sound="$(plan 6.18-ro sound)"
ro_vibra="$(plan 6.18-ro vibra)"
flash_sound="$(plan 6.18-flash sound)"
flash_vibra="$(plan 6.18-flash vibra)"
bringup_sound="$(plan 6.18-bringup sound)"
bringup_vibra="$(plan 6.18-bringup vibra)"

shared="$ROOT/output-nextgen-shared"
bringup="$ROOT/output-nextgen-bringup"

[ "$ro_sound" = "sound=$shared" ]
[ "$ro_vibra" = "vibra=$shared" ]
[ "$flash_sound" = "sound=$shared" ]
[ "$flash_vibra" = "vibra=$shared" ]
[ "$bringup_sound" = "sound=$bringup" ]
[ "$bringup_vibra" = "vibra=$bringup" ]

both="$(plan 6.18-ro both)"
printf '%s\n' "$both" | grep -qx "sound=$shared"
printf '%s\n' "$both" | grep -qx "vibra=$shared"

override="$ROOT/existing-populated-output"
actual="$(NEXTGEN_PLAN_ONLY=1 NEXTGEN_SHARED_BUILDROOT_OUT="$override" \
    "$WRAPPER" 6.18-flash vibra)"
[ "$actual" = "vibra=$override" ]

echo "PASS: RO/flash products share one Buildroot output tree"
echo "PASS: bring-up products share one separate Buildroot output tree"
echo "PASS: existing populated shared output can be selected explicitly"
