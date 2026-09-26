#!/bin/sh
# Buildroot executes its configured hooks directly, not via /bin/sh.
# Audit permissions as well as syntax without running any staging/provisioner.
set -eu
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BUILDROOT="${1:-$(CDPATH= cd -- "$HERE/../../../.." && pwd)}"
# Expand the controlled config glob, then disable expansion for hook paths.
set -- "$BUILDROOT"/configs/castle_nextgen*_defconfig
set -f
[ -f "$1" ] || { echo 'FAIL: no NextGen defconfigs found' >&2; exit 1; }

/bin/sh -n "$BUILDROOT/build-nextgen-image.sh" || {
    echo 'FAIL: build-nextgen-image.sh shell syntax' >&2
    exit 1
}
echo "PASS: build-nextgen-image.sh parses cleanly"

if [ -f "$BUILDROOT/rebuild-nextgen-from-scratch.sh" ]; then
    bash -n "$BUILDROOT/rebuild-nextgen-from-scratch.sh" || {
        echo 'FAIL: rebuild-nextgen-from-scratch.sh shell syntax' >&2
        exit 1
    }
    echo "PASS: rebuild-nextgen-from-scratch.sh parses cleanly"
fi
HOOKS="$(sed -n \
    -e 's/^BR2_ROOTFS_POST_BUILD_SCRIPT="\([^"]*\)"$/\1/p' \
    -e 's/^BR2_ROOTFS_POST_FAKEROOT_SCRIPT="\([^"]*\)"$/\1/p' \
    -e 's/^BR2_ROOTFS_POST_IMAGE_SCRIPT="\([^"]*\)"$/\1/p' \
    "$@" | tr ' ' '\n' | sed '/^$/d' | sort -u)"
[ -n "$HOOKS" ] || { echo 'FAIL: no NextGen image hooks found' >&2; exit 1; }
failed=0
count=0
for hook in $HOOKS; do
    count=$((count + 1))
    case "$hook" in
        board/castle/nextgen/*) ;;
        *) echo "FAIL: unexpected hook path: $hook" >&2; failed=1; continue ;;
    esac
    path="$BUILDROOT/$hook"
    if [ ! -f "$path" ] || [ ! -r "$path" ] || [ ! -x "$path" ]; then
        echo "FAIL: hook must be a readable executable file: $hook" >&2
        failed=1
        continue
    fi
    if [ "$(head -n 1 "$path")" != '#!/bin/sh' ]; then
        echo "FAIL: expected POSIX shell hook interpreter: $hook" >&2
        failed=1
        continue
    fi
    if ! /bin/sh -n "$path"; then
        echo "FAIL: hook shell syntax: $hook" >&2
        failed=1
        continue
    fi
    echo "PASS: executable image hook: $hook"
done
[ "$failed" -eq 0 ] || exit 1
echo "All $count configured NextGen image hooks are executable and parse cleanly"


# Provisioning must complete its read-only checks before consulting the arm
# marker, and both automatic/manual writers must be tied to the explicit
# bring-up environment.
PROVISIONER="$BUILDROOT/board/castle/nextgen/nextgen-provision-storage"
MANUAL_FLASH="$BUILDROOT/board/castle/nextgen/program-nextgen-flash.sh"
/bin/sh -n "$PROVISIONER"
/bin/sh -n "$MANUAL_FLASH"

line_no()
{
    pattern="$1"
    file="$2"
    grep -n -m1 "$pattern" "$file" | cut -d: -f1
}

bundle_line="$(line_no 'sha256sum -c manifest.sha256' "$PROVISIONER")"
mtd_line="$(line_no 'rootdev=.*mtd_by_label rootfs' "$PROVISIONER")"
boot_line="$(line_no 'require_bringup_environment || return 1' "$PROVISIONER")"
arm_line="$(line_no 'arm_value=.*ARM_MARKER' "$PROVISIONER")"
write_line="$(line_no 'ubiformat "\$rootdev"' "$PROVISIONER")"

[ "$bundle_line" -lt "$arm_line" ] &&
[ "$mtd_line" -lt "$arm_line" ] &&
[ "$boot_line" -lt "$arm_line" ] &&
[ "$arm_line" -lt "$write_line" ] || {
    echo "FAIL: provisioning preflight/arming order regressed" >&2
    exit 1
}

grep -Fq 'nextgen.env=bringup' "$PROVISIONER" &&
grep -Fq 'hardware-tested-nor-ubi-v1' "$PROVISIONER" &&
grep -Fq 'nextgen.env=bringup' "$MANUAL_FLASH" || {
    echo "FAIL: provisioning boot/arm guards regressed" >&2
    exit 1
}
! grep -Fq 'root=/dev/mmcblk' "$MANUAL_FLASH" || {
    echo "FAIL: manual flash writer still accepts generic SD-root boot" >&2
    exit 1
}

echo "PASS: provisioning preflight completes before the arm gate"
echo "PASS: flash writers require the explicit bring-up environment"

# The normal bring-up profile is the factory card, not a passive service card:
# it must require a production bundle, arm that exact bundle, mount the writable
# p3 data partition, and leave a persistent run log there.
WRAPPER="$BUILDROOT/build-nextgen-image.sh"
BRINGUP_POST="$BUILDROOT/board/castle/nextgen/post-build-bringup.sh"
BRINGUP_INIT="$BUILDROOT/board/castle/nextgen/S01NextGenBringup"
BRINGUP_FLOW="$BUILDROOT/board/castle/nextgen/nextgen-bringup.sh"

grep -Fq 'bring-up profile requires a matching production provision bundle' "$WRAPPER" &&
grep -Fq 'build_arm_provisioning="YES-I-HAVE-HARDWARE-TESTED-NOR-UBI-BOOT"' "$WRAPPER" &&
grep -Fq 'NEXTGEN_ARM_PROVISIONING="$build_arm_provisioning"' "$WRAPPER" || {
    echo "FAIL: factory bring-up profile is no longer automatically armed" >&2
    exit 1
}
grep -Fq '/dev/mmcblk0p3 /sdcard ext4 defaults 0 2' "$BRINGUP_POST" &&
grep -Fq 'run-$RUN_ID-inprogress.log' "$BRINGUP_INIT" &&
grep -Fq 'run-$RUN_ID-pass.log' "$BRINGUP_INIT" &&
grep -Fq 'run-$RUN_ID-fail.log' "$BRINGUP_INIT" &&
grep -Fq 'sequence=%s' "$BRINGUP_INIT" &&
grep -Fq 'NEXTGEN_BRINGUP_LOG' "$BRINGUP_FLOW" &&
grep -Fq 'NEXTGEN_BRINGUP_LOG' "$PROVISIONER" || {
    echo "FAIL: bring-up SD logging path/naming regressed" >&2
    exit 1
}

for stage in \
    'Checking production image...' \
    'Checking flash layout...' \
    'Programming system storage...' \
    'Verifying system storage...' \
    'Programming boot storage...' \
    'Verifying boot storage...' \
    'Programming U-Boot...' \
    'Verifying U-Boot...' \
    'Resetting boot environment...' \
    'Programming bootloader...' \
    'Verifying bootloader...' \
    'Final verification...'
do
    grep -Fq "progress \"$stage\"" "$PROVISIONER" || {
        echo "FAIL: bring-up provisioning stage missing: $stage" >&2
        exit 1
    }
done
grep -Fq 'log "stage: $stage"' "$PROVISIONER" || {
    echo "FAIL: LCD provisioning stages are not mirrored to the SD run log" >&2
    exit 1
}

stage_before()
{
    stage="$1"
    operation="$2"
    stage_line="$(grep -nF -m1 "progress \"$stage\"" "$PROVISIONER" | cut -d: -f1)"
    operation_line="$(grep -nF -m1 "$operation" "$PROVISIONER" | cut -d: -f1)"
    [ -n "$stage_line" ] && [ -n "$operation_line" ] &&
    [ "$stage_line" -lt "$operation_line" ] || {
        echo "FAIL: provisioning stage is not ahead of its operation: $stage" >&2
        exit 1
    }
}

stage_before 'Programming system storage...' 'ubiformat "$rootdev" -y -f "$BUNDLE/rootfs.ubi"'
stage_before 'Verifying system storage...' 'verify_rootfs_ubi "$rootdev" "$NEXTGEN_PRODUCT"'
stage_before 'Programming boot storage...' 'ubiformat "$bootdev" -y -f "$BUNDLE/boot.ubi"'
stage_before 'Verifying boot storage...' 'verify_boot_ubi "$bootdev"'
stage_before 'Programming U-Boot...' 'flash_erase "$ubootdev" 0 0'
stage_before 'Verifying U-Boot...' 'verify_readback "$ubootdev" 0'
stage_before 'Resetting boot environment...' 'flash_erase "$envdev" 0 0'
stage_before 'Programming bootloader...' 'flash_erase "$at91dev" 0 0'
stage_before 'Verifying bootloader...' 'verify_readback "$at91dev" 0'
stage_before 'Final verification...' '    sync'

echo "PASS: factory bring-up profile requires and arms a production bundle"
echo "PASS: bring-up uses numbered persistent run logs on the SD data partition"
echo "PASS: bring-up LCD reports actual provisioning operations and logs every stage"


# RO-root ownership invariants used by engineering access and network identity.
RO_POST="$BUILDROOT/board/castle/nextgen/post-build-ro.sh"
RO_VERIFY="$BUILDROOT/board/castle/nextgen/verify-target-ro-layout.sh"
PERSIST_INIT="$BUILDROOT/board/castle/nextgen/persist-init-ro.sh"
NM_CONF="$BUILDROOT/board/castle/nextgen/rootfs-overlay/etc/NetworkManager/conf.d/10-nextgen-unmanaged.conf"

/bin/sh -n "$RO_POST"
/bin/sh -n "$RO_VERIFY"
/bin/sh -n "$PERSIST_INIT"

grep -Fq 'mkdir -p' "$PERSIST_INIT" &&
grep -Fq '"$PERSIST/os/ssh/root"' "$PERSIST_INIT" || {
    echo "FAIL: persist init does not create root SSH state" >&2
    exit 1
}
grep -Fq 'ln -s /persist/os/ssh/root "$TARGET_DIR/root/.ssh"' "$RO_POST" || {
    echo "FAIL: RO image no longer persists root authorized_keys" >&2
    exit 1
}
grep -Fq 'hostname-mode=none' "$NM_CONF" || {
    echo "FAIL: NetworkManager may overwrite the Application-owned hostname" >&2
    exit 1
}
grep -Fq 'root SSH authorized_keys path is not persistent' "$RO_VERIFY" || {
    echo "FAIL: RO layout verifier does not check root SSH persistence" >&2
    exit 1
}

echo "PASS: RO engineering SSH state is persistent"
echo "PASS: Application retains ownership of the runtime hostname"
