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

# Keep the useful ALSA engineering tools.
expect_y BR2_PACKAGE_ALSA_UTILS
expect_y BR2_PACKAGE_ALSA_UTILS_ALSACONF
expect_y BR2_PACKAGE_ALSA_UTILS_ACONNECT
expect_y BR2_PACKAGE_ALSA_UTILS_AMIXER
expect_y BR2_PACKAGE_ALSA_UTILS_APLAY

# Deliberately removed target-side debug/development utilities.
expect_n BR2_PACKAGE_JQ
expect_n BR2_PACKAGE_DRM_INFO
expect_n BR2_PACKAGE_LIBDRM_INSTALL_TESTS
expect_n BR2_PACKAGE_SPI_TOOLS
expect_n BR2_PACKAGE_RSYSLOG

echo "NextGen target config OK: ALSA tools retained; jq/DRM tests/SPI tools/rsyslog disabled"
