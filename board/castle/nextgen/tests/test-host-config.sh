#!/bin/sh
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BUILDROOT="$(CDPATH= cd -- "$HERE/../../../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
OUT="$TMP/output"

fail()
{
    echo "FAIL: $*" >&2
    exit 1
}

expect_y()
{
    symbol="$1"
    grep -qx "$symbol=y" "$OUT/.config" ||
        fail "$symbol was not selected"
}

expect_n()
{
    symbol="$1"
    if grep -qx "$symbol=y" "$OUT/.config"; then
        fail "$symbol was unexpectedly selected"
    fi
}

make -s -C "$BUILDROOT" O="$OUT" castle_nextgen_dev_defconfig >/dev/null

# These are direct requirements of the NextGen image/module staging hooks.
expect_y BR2_PACKAGE_HOST_DOSFSTOOLS
expect_y BR2_PACKAGE_HOST_GENIMAGE
expect_y BR2_PACKAGE_HOST_KMOD
expect_y BR2_PACKAGE_HOST_MTOOLS

# Heavy development conveniences are intentionally not part of the image build.
expect_n BR2_PACKAGE_HOST_GDB
expect_n BR2_PACKAGE_HOST_QEMU
expect_n BR2_PACKAGE_HOST_DTC

# host-python3 itself may still be built as a make dependency of Meson/Python
# package infrastructure.  What NextGen must not force are these optional,
# heavyweight feature modules.
expect_n BR2_PACKAGE_HOST_PYTHON3_BZIP2
expect_n BR2_PACKAGE_HOST_PYTHON3_XZ
expect_n BR2_PACKAGE_HOST_PYTHON3_CURSES
expect_n BR2_PACKAGE_HOST_PYTHON3_SSL

# This is the only selected libglib2 mode that would force host QEMU.
expect_n BR2_PACKAGE_GOBJECT_INTROSPECTION

echo "NextGen host config OK: required image tools only; no explicit GDB/QEMU/DTC/Python feature bundle"
