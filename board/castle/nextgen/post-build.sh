#!/bin/sh
set -eu
TARGET_DIR="$1"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BUILDROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE_DIR="$(CDPATH= cd -- "$BUILDROOT_DIR/.." && pwd)"
APP_DIR="${NEXTGEN_APP_DIR:-$WORKSPACE_DIR/app}"
PRODUCT="${NEXTGEN_PRODUCT:-sound}"
KERNEL_BUILD_DIR="${NEXTGEN_KERNEL_BUILD_DIR:-$WORKSPACE_DIR/linux-working/build-fast}"
KERNEL_MODULES_ROOT="$KERNEL_BUILD_DIR/mods/lib/modules"
EXEC_DIR="$TARGET_DIR/root/Exec"
COMMON_RUNTIME="$APP_DIR/Application/Files/Runtime/Sound/Exec"
mkdir -p "$TARGET_DIR/root" "$TARGET_DIR/boot" "$EXEC_DIR"
KERNEL_PROFILE="${NEXTGEN_KERNEL_PROFILE:-unspecified}"
printf '%s\n' "$KERNEL_PROFILE" > "$TARGET_DIR/etc/nextgen-kernel-profile"

# Install the complete module tree when this kernel profile produces modules.
# The LZ4 control kernel is monolithic and legitimately has no module tree.
EXPECTED_KERNEL_RELEASE="6.6.23-linux4microchip-2024.04+"
rm -rf "$TARGET_DIR/lib/modules/$EXPECTED_KERNEL_RELEASE"

if [ -d "$KERNEL_MODULES_ROOT" ]; then
    set -- "$KERNEL_MODULES_ROOT"/*
    [ "$#" -eq 1 ] && [ -d "$1" ] || {
        echo "error: expected exactly one kernel release below $KERNEL_MODULES_ROOT" >&2
        printf '       %s\n' "$@" >&2
        exit 1
    }

    KERNEL_RELEASE="$(basename "$1")"
    [ "$KERNEL_RELEASE" = "$EXPECTED_KERNEL_RELEASE" ] || {
        echo "error: unexpected kernel module release: $KERNEL_RELEASE" >&2
        echo "       expected: $EXPECTED_KERNEL_RELEASE" >&2
        exit 1
    }

    mkdir -p "$TARGET_DIR/lib/modules"
    cp -a "$1" "$TARGET_DIR/lib/modules/"
    rm -f \
        "$TARGET_DIR/lib/modules/$KERNEL_RELEASE/build" \
        "$TARGET_DIR/lib/modules/$KERNEL_RELEASE/source"

    printf 'NextGen kernel modules: %s <- %s\n' \
        "$KERNEL_RELEASE" "$KERNEL_BUILD_DIR"
else
    echo "NextGen kernel modules: none for this kernel profile"
fi

# This branch renamed the application service from S55NextGen to S00NextGen.
# Buildroot output trees are incremental and overlay rsync does not remove a
# file that disappeared from the overlay, so explicitly remove the obsolete
# service and restage the early-boot files on every image build.
rm -f "$TARGET_DIR/etc/init.d/S55NextGen"
install -m 0755 "$SCRIPT_DIR/rootfs-overlay/etc/init.d/S00NextGen" \
    "$TARGET_DIR/etc/init.d/S00NextGen"
install -m 0755 "$SCRIPT_DIR/rootfs-overlay/root/startup.sh" \
    "$TARGET_DIR/root/startup.sh"

# NextGen owns when NTP synchronisation is allowed (manual "Sync now" and the
# Auto Time Sync setting). Keep chronyd/chronyc installed, but do not start the
# package's background daemon unconditionally: it would both ignore the user
# setting and make the application's one-shot 'chronyd -q' fail immediately
# because another chronyd instance already owns the runtime PID/socket.
rm -f "$TARGET_DIR/etc/init.d/S49chronyd"

# NetworkManager is needed by the application, but it is intentionally kept
# out of the boot critical path.  Remove the SysV S-prefix so rcS does not
# launch it; WiFiRun() starts this script at the application's existing
# delayed Wi-Fi stage.
if [ -f "$TARGET_DIR/etc/init.d/S45NetworkManager" ]; then
    mv "$TARGET_DIR/etc/init.d/S45NetworkManager" \
        "$TARGET_DIR/etc/init.d/NetworkManager"
fi

# Keep WILC genuinely on-demand in the deferred profiles.  eudev is allowed
# to autoload the other deferred DT drivers, but the application explicitly
# modprobes WILC at its delayed Wi-Fi stage before starting NetworkManager.
WILC_MODPROBE_CONF="$TARGET_DIR/etc/modprobe.d/nextgen-wilc-deferred.conf"
rm -f "$WILC_MODPROBE_CONF"
case "$KERNEL_PROFILE" in
    deferred|deferred-diag)
        mkdir -p "$TARGET_DIR/etc/modprobe.d"
        cat > "$WILC_MODPROBE_CONF" <<'EOF'
# NextGen fast boot: Wi-Fi is loaded explicitly by the application.
blacklist wilc-spi
blacklist wilc-sdio
EOF
        ;;
esac

# NetworkManager always maintains its generated resolver state here.  The
# Buildroot skeleton points /etc/resolv.conf at /run/resolv.conf, but with
# NetworkManager that target is never created, leaving DNS completely broken.
# Point libc directly at NetworkManager's canonical runtime resolver file.
ln -snf ../run/NetworkManager/resolv.conf "$TARGET_DIR/etc/resolv.conf"

for connection in "$TARGET_DIR"/etc/NetworkManager/system-connections/*.nmconnection; do
    [ -f "$connection" ] || continue
    chmod 0600 "$connection"
done

for name in Arial.ttf NotoSansCJKtc-Regular.ttf Translations.csv ionicons.ttf open-iconic.ttf; do
    [ ! -e "$COMMON_RUNTIME/$name" ] || cp -L "$COMMON_RUNTIME/$name" "$EXEC_DIR/$name"
done

case "$PRODUCT" in
    sound)
        APP_BINARY="$APP_DIR/Application/build/sound/bin/NextGen"
        if [ -d "$COMMON_RUNTIME/Templates" ]; then
            rm -rf "$EXEC_DIR/Templates"
            mkdir -p "$EXEC_DIR/Templates"
            cp -aL "$COMMON_RUNTIME/Templates/." "$EXEC_DIR/Templates/"
        fi
        [ ! -f "$COMMON_RUNTIME/FacCalFile.dat" ] || install -m 0644 "$COMMON_RUNTIME/FacCalFile.dat" "$EXEC_DIR/FacCalFile.dat"
        if [ -f "$APP_DIR/Application/Files/hpdc.csv" ]; then
            install -d -m 0755 "$EXEC_DIR/BaseHPD"
            install -m 0644 "$APP_DIR/Application/Files/hpdc.csv" "$EXEC_DIR/BaseHPD/hpdc.csv"
        fi
        ;;
    vibra)
        APP_BINARY="$APP_DIR/Application/build/vibra/bin/NextGen"
        ;;
    *)
        echo "Unknown NEXTGEN_PRODUCT: $PRODUCT" >&2
        exit 1
        ;;
esac

if [ ! -x "$APP_BINARY" ]; then
    echo "error: NextGen application not staged (missing $APP_BINARY)" >&2
    exit 1
fi

# Never silently package an older application binary after switching branches
# or changing startup/UI code.  The application remains a separate build, but
# an image build now fails loudly if any maintained application source is newer
# than the binary being staged.
STALE_SOURCE="$(
    find "$APP_DIR/Application" "$APP_DIR/LicenceGenerator/FirmwareReference" \
        -type f \( -name '*.c' -o -name '*.h' -o -name 'Makefile' \) \
        -newer "$APP_BINARY" -print -quit 2>/dev/null || true
)"
if [ -n "$STALE_SOURCE" ]; then
    echo "error: NextGen application binary is stale: $APP_BINARY" >&2
    echo "       newer source: $STALE_SOURCE" >&2
    echo "       rebuild the $PRODUCT application before rebuilding the image" >&2
    exit 1
fi

install -m 0755 "$APP_BINARY" "$TARGET_DIR/root/NextGen"


# Development images deliberately keep a password login recovery path.
# The defconfig sets the root password to "root"; current OpenSSH defaults
# otherwise reject password authentication for root (PermitRootLogin
# prohibit-password). Production images can disable this explicitly with
# NEXTGEN_DEV_SSH_PASSWORD_LOGIN=0.
if [ "${NEXTGEN_DEV_SSH_PASSWORD_LOGIN:-1}" = "1" ] && [ -f "$TARGET_DIR/etc/ssh/sshd_config" ]; then
    sed -i \
        -e 's/^[#[:space:]]*PermitRootLogin[[:space:]].*/PermitRootLogin yes/' \
        -e 's/^[#[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication yes/' \
        "$TARGET_DIR/etc/ssh/sshd_config"

    grep -q '^PermitRootLogin[[:space:]]\+yes$' "$TARGET_DIR/etc/ssh/sshd_config" || \
        printf '\nPermitRootLogin yes\n' >> "$TARGET_DIR/etc/ssh/sshd_config"
    grep -q '^PasswordAuthentication[[:space:]]\+yes$' "$TARGET_DIR/etc/ssh/sshd_config" || \
        printf 'PasswordAuthentication yes\n' >> "$TARGET_DIR/etc/ssh/sshd_config"
fi
