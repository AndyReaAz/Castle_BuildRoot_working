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
