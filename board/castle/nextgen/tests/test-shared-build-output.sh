#!/bin/sh
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$HERE/../../../.." && pwd)"
WRAPPER="$ROOT/build-nextgen-image.sh"

plan()
{
    env -u NEXTGEN_BUILDROOT_OUT \
        -u NEXTGEN_SHARED_BUILDROOT_OUT \
        -u NEXTGEN_BRINGUP_BUILDROOT_OUT \
        NEXTGEN_PLAN_ONLY=1 "$WRAPPER" "$@"
}

ro_sound="$(plan 6.18-ro sound)"
ro_vibra="$(plan 6.18-ro vibra)"
flash_sound="$(plan 6.18-flash sound)"
flash_vibra="$(plan 6.18-flash vibra)"
bringup_sound="$(plan 6.18-bringup sound)"
bringup_vibra="$(plan 6.18-bringup vibra)"

shared="$ROOT/output-nextgen-shared"

[ "$ro_sound" = "sound=$shared" ]
[ "$ro_vibra" = "vibra=$shared" ]
[ "$flash_sound" = "sound=$shared" ]
[ "$flash_vibra" = "vibra=$shared" ]
[ "$bringup_sound" = "sound=$shared" ]
[ "$bringup_vibra" = "vibra=$shared" ]

both="$(plan 6.18-ro both)"
printf '%s\n' "$both" | grep -qx "sound=$shared"
printf '%s\n' "$both" | grep -qx "vibra=$shared"

override="$ROOT/existing-populated-output"
actual="$(NEXTGEN_PLAN_ONLY=1 NEXTGEN_SHARED_BUILDROOT_OUT="$override" \
    "$WRAPPER" 6.18-flash vibra)"
[ "$actual" = "vibra=$override" ]

echo "PASS: RO/flash/bring-up products share one Buildroot output tree"
echo "PASS: existing populated shared output can be selected explicitly"

# Product changes must rebuild the complete NextGen-owned hierarchy rather than
# layering one product over another in the mutable shared target tree.
grep -q 'rm -rf "\$NEXTGEN_ROOT"' "$ROOT/board/castle/nextgen/post-build.sh"
grep -q 'candidate_bundle="\$artifact_root/\$product/6.18-flash/production-provision"' "$WRAPPER"
grep -q 'NEXTGEN_PRODUCT=\$expected_product' "$ROOT/board/castle/nextgen/post-build-bringup.sh"
grep -q 'build_provision_bundle=' "$WRAPPER"
! grep -q 'export NEXTGEN_PROVISION_BUNDLE_DIR' "$WRAPPER"
grep -q 'persist-init.sh|d' "$ROOT/board/castle/nextgen/post-build.sh"
grep -q 'nextgen-bringup-image' "$ROOT/board/castle/nextgen/post-build.sh"
grep -q 'nextgen-provision-armed' "$ROOT/board/castle/nextgen/post-build.sh"
grep -q 'cp -L "\$out/images/rootfs.ext4" "\$artifact_dir/rootfs.ext4"' "$WRAPPER"
grep -q 'bring-up snapshot rootfs.ext4 is not self-contained' "$WRAPPER"

echo "PASS: bring-up artifact snapshot materializes rootfs.ext4"
echo "PASS: shared target is normalized between production and bring-up"
echo "PASS: shared target is fully restaged between products"
echo "PASS: bring-up consumes the matching product snapshot"
