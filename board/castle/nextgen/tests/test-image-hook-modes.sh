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
