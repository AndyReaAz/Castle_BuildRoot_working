#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd -- "$ROOT/.." && pwd)"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="${NEXTGEN_ACID_LOG_ROOT:-$ROOT/acid-rebuild-logs}/$STAMP"
LOG_FILE="$LOG_DIR/rebuild.log"
CURRENT_STEP=startup

AT91="$WORKSPACE/at91bootstrap"
UBOOT="$WORKSPACE/u-boot"
LINUX="$WORKSPACE/linux-6.18"
APP="$WORKSPACE/app"
ARTIFACTS="$ROOT/output-nextgen-artifacts"

case "$JOBS" in
    ''|*[!0-9]*|0) echo "error: JOBS must be a positive integer" >&2; exit 2 ;;
esac

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

on_error()
{
    rc=$?
    echo
    echo "NEXTGEN ACID REBUILD FAILED"
    echo "step: $CURRENT_STEP"
    echo "rc:   $rc"
    echo "log:  $LOG_FILE"
    exit "$rc"
}
trap on_error ERR

step()
{
    CURRENT_STEP="$1"
    echo
    echo "================================================================"
    echo "[$(date -u +%FT%TZ)] $CURRENT_STEP"
    echo "================================================================"
}

need_repo()
{
    [ -d "$1/.git" ] || {
        echo "error: expected git checkout: $1" >&2
        exit 1
    }
}

need_cmd()
{
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: required host command not found: $1" >&2
        exit 1
    }
}

source_manifest()
{
    out="$1"
    : > "$out"
    for dir in "$AT91" "$UBOOT" "$LINUX" "$APP" "$ROOT"; do
        {
            echo "repo=$dir"
            echo "head=$(git -C "$dir" rev-parse HEAD)"
            echo "branch=$(git -C "$dir" symbolic-ref --short -q HEAD || echo DETACHED)"
            echo "describe=$(git -C "$dir" describe --always --dirty 2>/dev/null || true)"
            git -C "$dir" status --short --untracked-files=no | sed 's/^/status=/' || true
            echo
        } >> "$out"
    done
}

verify_application()
{
    product="$1"
    bin="$APP/Application/build/$product/bin/NextGen"
    readelf="$OUT/host/bin/arm-buildroot-linux-gnueabihf-readelf"

    [ -x "$bin" ] || { echo "error: missing $bin" >&2; exit 1; }
    file "$bin" | tee "$LOG_DIR/app-$product-file.txt"
    file "$bin" | grep -Eq 'ELF 32-bit .*ARM'

    "$readelf" -h "$bin" > "$LOG_DIR/app-$product-elf-header.txt"
    "$readelf" -A "$bin" > "$LOG_DIR/app-$product-arm-attrs.txt"
    "$readelf" -d "$bin" > "$LOG_DIR/app-$product-dynamic.txt"

    grep -Eq 'Machine:[[:space:]]+ARM' "$LOG_DIR/app-$product-elf-header.txt"
    grep -Eq 'Tag_ABI_VFP_args:[[:space:]]+VFP registers' "$LOG_DIR/app-$product-arm-attrs.txt"
    grep -q 'Shared library: \[libcurl.so.4\]' "$LOG_DIR/app-$product-dynamic.txt"
    grep -q 'Shared library: \[libasound.so.2\]' "$LOG_DIR/app-$product-dynamic.txt"
    grep -q 'Shared library: \[libpng16.so.16\]' "$LOG_DIR/app-$product-dynamic.txt"

    sha256sum "$bin" | tee "$LOG_DIR/app-$product.sha256"
}

verify_snapshot()
{
    d="$1"
    [ -f "$d/SHA256SUMS" ] || {
        echo "error: missing snapshot checksum file: $d/SHA256SUMS" >&2
        exit 1
    }
    echo
    echo "=== $d ==="
    (cd "$d" && sha256sum -c SHA256SUMS)
}

step "Preflight"
for dir in "$AT91" "$UBOOT" "$LINUX" "$APP" "$ROOT"; do
    need_repo "$dir"
done
for cmd in git make file sha256sum arm-linux-gnueabihf-gcc lz4; do
    need_cmd "$cmd"
done

if [ -e "$ROOT/output-nextgen-shared" ]; then
    OUT="$(readlink -f "$ROOT/output-nextgen-shared")"
elif [ -d "$ROOT/output-nextgen-sound" ]; then
    OUT="$ROOT/output-nextgen-sound"
    ln -s output-nextgen-sound "$ROOT/output-nextgen-shared"
else
    OUT="$ROOT/output-nextgen-shared"
fi

echo "workspace=$WORKSPACE"
echo "jobs=$JOBS"
echo "shared Buildroot output=$OUT"
echo "log=$LOG_FILE"
echo "ccache reuse=disabled"
echo "Buildroot dl/=preserved"

source_manifest "$LOG_DIR/source-before.txt"

export CCACHE_DISABLE=1
export UBOOT_CCACHE=0
export KERNEL_CCACHE=0
export NEXTGEN_APP_DIR="$APP"
unset MAKEFLAGS MFLAGS MAKEOVERRIDES GNUMAKEFLAGS MAKELEVEL
unset NEXTGEN_BUILDROOT_OUT NEXTGEN_SHARED_BUILDROOT_OUT NEXTGEN_BRINGUP_BUILDROOT_OUT

step "Preserve previous artifact matrix"
if [ -d "$ARTIFACTS" ]; then
    mv "$ARTIFACTS" "$LOG_DIR/artifacts-before-rebuild"
fi

step "Clean prior generated Buildroot and Application outputs"
if [ -f "$OUT/Makefile" ] || [ -f "$OUT/.config" ]; then
    make -C "$ROOT" O="$OUT" clean
fi
make -C "$APP/Application" clean

step "AT91Bootstrap SD"
(cd "$AT91" && JOBS="$JOBS" ./build-fast.sh rebuild sd)

step "AT91Bootstrap NOR"
(cd "$AT91" && JOBS="$JOBS" ./build-fast.sh rebuild nor)

step "U-Boot SD/fast"
(cd "$UBOOT" && JOBS="$JOBS" UBOOT_CCACHE=0 ./build-fast.sh rebuild fast)

step "U-Boot production flash"
(cd "$UBOOT" && JOBS="$JOBS" UBOOT_CCACHE=0 ./build-fast.sh rebuild flash)

step "Linux 6.18 normal"
(cd "$LINUX" && JOBS="$JOBS" KERNEL_CCACHE=0 ./build-fast.sh rebuild normal)

step "Linux 6.18 bring-up"
(cd "$LINUX" && JOBS="$JOBS" KERNEL_CCACHE=0 ./build-fast.sh rebuild bringup)

step "Fresh Buildroot toolchain and Application dependencies"
make -C "$ROOT" O="$OUT" castle_nextgen_ro_dev_defconfig
make -C "$ROOT" O="$OUT" -j"$JOBS" toolchain libcurl alsa-lib libpng

APP_SYSROOT="$OUT/host/arm-buildroot-linux-gnueabihf/sysroot"
APP_CC="$OUT/host/bin/arm-buildroot-linux-gnueabihf-gcc"
APP_READELF="$OUT/host/bin/arm-buildroot-linux-gnueabihf-readelf"

[ -x "$APP_CC" ] || { echo "error: missing fresh compiler: $APP_CC" >&2; exit 1; }
[ -x "$APP_READELF" ] || { echo "error: missing fresh readelf: $APP_READELF" >&2; exit 1; }
[ -d "$APP_SYSROOT/usr/include" ] || { echo "error: incomplete sysroot: $APP_SYSROOT" >&2; exit 1; }

"$APP_CC" --version | head -n 1
echo "Application sysroot=$APP_SYSROOT"

step "Application sound production build"
make -C "$APP/Application" -j"$JOBS" sound CC="$APP_CC" SYSROOT="$APP_SYSROOT" PRE_SCRIPT=:
verify_application sound

step "Application vibration production build"
make -C "$APP/Application" -j"$JOBS" vibra CC="$APP_CC" SYSROOT="$APP_SYSROOT" PRE_SCRIPT=:
verify_application vibra

step "Buildroot wrapper and hook checks"
/bin/sh -n "$ROOT/build-nextgen-image.sh"
/bin/sh "$ROOT/board/castle/nextgen/tests/test-image-hook-modes.sh"
/bin/sh "$ROOT/board/castle/nextgen/tests/test-shared-build-output.sh"

step "RO SD images: sound + vibration"
(cd "$ROOT" && ./build-nextgen-image.sh 6.18-ro both)

step "Production NOR/NAND images: sound + vibration"
(cd "$ROOT" && ./build-nextgen-image.sh 6.18-flash both)

step "Bring-up SD images: sound + vibration"
(cd "$ROOT" && ./build-nextgen-image.sh 6.18-bringup both)

step "Verify all six artifact snapshots"
for d in     "$ARTIFACTS/sound/6.18-ro"     "$ARTIFACTS/sound/6.18-flash"     "$ARTIFACTS/sound/6.18-bringup"     "$ARTIFACTS/vibra/6.18-ro"     "$ARTIFACTS/vibra/6.18-flash"     "$ARTIFACTS/vibra/6.18-bringup"
do
    verify_snapshot "$d"
done

for d in "$ARTIFACTS/sound/6.18-bringup" "$ARTIFACTS/vibra/6.18-bringup"; do
    [ -f "$d/rootfs.ext4" ] && [ ! -L "$d/rootfs.ext4" ] || {
        echo "error: bring-up rootfs.ext4 is not self-contained: $d" >&2
        exit 1
    }
done

step "Write final manifests"
source_manifest "$LOG_DIR/source-after.txt"
if ! cmp -s "$LOG_DIR/source-before.txt" "$LOG_DIR/source-after.txt"; then
    echo "WARNING: source checkout/status changed during rebuild."
    diff -u "$LOG_DIR/source-before.txt" "$LOG_DIR/source-after.txt" || true
fi

sha256sum     "$AT91/build-sd/binaries/boot.bin"     "$AT91/build-nor/binaries/boot.bin"     "$UBOOT/build-fast/u-boot.bin"     "$UBOOT/build-flash/u-boot.bin"     "$UBOOT/build-flash/u-boot.nor-trailer"     "$LINUX/build-fast-6.18/arch/arm/boot/zImage"     "$LINUX/build-fast-6.18/arch/arm/boot/dts/microchip/nextgen.dtb"     "$LINUX/build-fast-6.18-bringup/arch/arm/boot/zImage"     "$LINUX/build-fast-6.18-bringup/arch/arm/boot/dts/microchip/nextgen.dtb"     "$APP/Application/build/sound/bin/NextGen"     "$APP/Application/build/vibra/bin/NextGen"     | tee "$LOG_DIR/core-artifacts.sha256"

(
    cd "$ROOT"
    find output-nextgen-artifacts -type f -print0 |
        sort -z |
        xargs -0 sha256sum
) > "$LOG_DIR/all-image-artifacts.sha256"

step "ACID REBUILD PASSED"
echo "Rebuilt from clean generated outputs:"
echo "  AT91Bootstrap: SD + NOR"
echo "  U-Boot: fast/SD + production flash"
echo "  Linux 6.18: normal + bring-up"
echo "  Application: sound + vibration"
echo "  Images: all six RO/flash/bring-up product variants"
echo
echo "Buildroot output: $OUT"
echo "Artifact matrix:  $ARTIFACTS"
echo "Full log:         $LOG_FILE"
echo "Source manifest:  $LOG_DIR/source-before.txt"
echo "Core hashes:      $LOG_DIR/core-artifacts.sha256"
echo "Image hashes:     $LOG_DIR/all-image-artifacts.sha256"
echo "Old artifacts:    $LOG_DIR/artifacts-before-rebuild (if present)"
