#!/bin/sh
set -eu
TARGET_DIR="$1"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BUILDROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE_DIR="$(CDPATH= cd -- "$BUILDROOT_DIR/.." && pwd)"
APP_DIR="${NEXTGEN_APP_DIR:-$WORKSPACE_DIR/app}"
PRODUCT="${NEXTGEN_PRODUCT:-sound}"
KERNEL_BUILD_DIR="${NEXTGEN_KERNEL_BUILD_DIR:-$WORKSPACE_DIR/linux-working/build-fast}"
KERNEL_MODULES_ROOT="${NEXTGEN_KERNEL_MODULES_ROOT:-$KERNEL_BUILD_DIR/mods/lib/modules}"
COMMON_RUNTIME="$APP_DIR/Application/Files/Runtime/Sound/Exec"

NEXTGEN_ROOT="$TARGET_DIR/opt/nextgen"
PLATFORM_BIN="$NEXTGEN_ROOT/platform/bin"
PLATFORM_SHARE="$NEXTGEN_ROOT/platform/share"
APP_REALM="$NEXTGEN_ROOT/app/$PRODUCT"
DATA_COMMON="$NEXTGEN_ROOT/data/common"
DATA_REALM="$NEXTGEN_ROOT/data/$PRODUCT"
STATE_REALM="$NEXTGEN_ROOT/state/$PRODUCT"
STATE_PLATFORM="$NEXTGEN_ROOT/state/platform"

# output-nextgen is incremental. Recreate the NextGen-owned hierarchy on every
# image build so stale files from an older layout cannot leak into a new image.
rm -rf "$NEXTGEN_ROOT"
mkdir -p "$TARGET_DIR/root" "$TARGET_DIR/boot" \
    "$PLATFORM_BIN" "$PLATFORM_SHARE" "$APP_REALM" \
    "$DATA_COMMON" "$DATA_REALM" "$STATE_REALM" "$STATE_PLATFORM"

KERNEL_PROFILE="${NEXTGEN_KERNEL_PROFILE:-unspecified}"
printf '%s\n' "$KERNEL_PROFILE" > "$TARGET_DIR/etc/nextgen-kernel-profile"
printf '%s\n' "$PRODUCT" > "$TARGET_DIR/etc/nextgen-product"

# Fail the image build before staging if any platform-owned shell helper is
# syntactically invalid. These scripts run under BusyBox ash on the meter and
# intentionally stay within POSIX sh syntax.
for script in \
    "$SCRIPT_DIR/rootfs-overlay/root/startup.sh" \
    "$SCRIPT_DIR/rootfs-overlay/root/Exec/fwenv.sh" \
    "$SCRIPT_DIR/rootfs-overlay/root/Exec/usb-gadget-common.sh" \
    "$SCRIPT_DIR/rootfs-overlay/root/Exec/usbcontrol.sh" \
    "$SCRIPT_DIR/nextgen-update-install" \
    "$SCRIPT_DIR/nextgen-update-accept"
do
    /bin/sh -n "$script" || {
        echo "error: invalid NextGen platform script: $script" >&2
        exit 1
    }
done

# Install the complete module tree when this kernel profile produces modules.
# The LZ4 control kernel is monolithic and legitimately has no module tree.
EXPECTED_KERNEL_RELEASE="${NEXTGEN_EXPECTED_KERNEL_RELEASE:-6.6.23-linux4microchip-2024.04+}"
# output-nextgen is incremental. Never let a prior 6.6 external module tree
# leak into a 6.18 image alongside the selected release.
rm -rf \
    "$TARGET_DIR/lib/modules/6.6.23-linux4microchip-2024.04+" \
    "$TARGET_DIR/lib/modules/6.18.35-linux4microchip-2026.04.2+" \
    "$TARGET_DIR/lib/modules/$EXPECTED_KERNEL_RELEASE"

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

    # The module tree comes from the external fast-boot kernel build rather
    # than Buildroot's own linux package, so regenerate target-side dependency
    # metadata after copying it. This is required for deterministic modprobe
    # of deferred drivers such as WILC and their dependencies.
    DEPMOD="${HOST_DIR:-}/sbin/depmod"
    if [ ! -x "$DEPMOD" ]; then
        DEPMOD="${HOST_DIR:-}/bin/depmod"
    fi
    [ -x "$DEPMOD" ] || {
        echo "error: Buildroot host depmod is unavailable (HOST_DIR=${HOST_DIR:-unset})" >&2
        exit 1
    }
    "$DEPMOD" -b "$TARGET_DIR" "$KERNEL_RELEASE"

    printf 'NextGen kernel modules: %s <- %s\n' \
        "$KERNEL_RELEASE" "$KERNEL_BUILD_DIR"
else
    echo "NextGen kernel modules: none for this kernel profile"
fi

# The platform owns the launcher and helper tools. The old /root/Exec layout
# must not leak into an incremental Buildroot output tree.
rm -f "$TARGET_DIR/etc/init.d/S55NextGen" "$TARGET_DIR/root/NextGen"
rm -rf "$TARGET_DIR/root/Exec"
install -m 0755 "$SCRIPT_DIR/rootfs-overlay/etc/init.d/S00NextGen" \
    "$TARGET_DIR/etc/init.d/S00NextGen"
install -m 0755 "$SCRIPT_DIR/rootfs-overlay/root/startup.sh" \
    "$TARGET_DIR/root/startup.sh"
install -m 0755 "$SCRIPT_DIR/rootfs-overlay/root/Exec/fwenv.sh" \
    "$PLATFORM_BIN/fwenv.sh"
install -m 0755 "$SCRIPT_DIR/rootfs-overlay/root/Exec/usb-gadget-common.sh" \
    "$PLATFORM_BIN/usb-gadget-common.sh"
install -m 0755 "$SCRIPT_DIR/rootfs-overlay/root/Exec/usbcontrol.sh" \
    "$PLATFORM_BIN/usbcontrol.sh"
install -m 0755 "$SCRIPT_DIR/nextgen-update-install" \
    "$PLATFORM_BIN/nextgen-update-install"
install -m 0755 "$SCRIPT_DIR/nextgen-update-accept" \
    "$PLATFORM_BIN/nextgen-update-accept"

# NextGen owns when NTP synchronisation is allowed (manual "Sync now" and the
# Auto Time Sync setting). Keep chronyd/chronyc installed, but do not start the
# package's background daemon unconditionally: it would both ignore the user
# setting and make the application's one-shot 'chronyd -q' fail immediately
# because another chronyd instance already owns the runtime PID/socket.
rm -f "$TARGET_DIR/etc/init.d/S49chronyd"

# BlueZ and the legacy NTP package are no longer selected, but Buildroot
# output trees are incremental and package removal does not purge files
# already installed into target. Prevent stale init scripts from putting
# either daemon back onto the boot-critical path.
rm -f \
    "$TARGET_DIR/etc/init.d/S40bluetoothd" \
    "$TARGET_DIR/etc/init.d/S49ntp" \
    "$TARGET_DIR/etc/init.d/S49ntpd"

# eudev remains the long-running hotplug manager, but its stock SysV script
# performs a complete coldplug trigger + settle immediately after S00NextGen.
# Critical NextGen devices are built in and available through devtmpfs; the
# application resolves the Goodix evdev node directly before udev exists.
# Keep udev installed, but let the application start the coldplug later.
if [ -f "$TARGET_DIR/etc/init.d/S10udevd" ]; then
    mv "$TARGET_DIR/etc/init.d/S10udevd" \
        "$TARGET_DIR/etc/init.d/udevd"
fi

# NetworkManager and its D-Bus dependency are needed by the application, but
# neither belongs in the boot-critical path.  Remove the SysV S-prefixes so
# rcS does not launch them; WiFiRun() starts D-Bus immediately before
# NetworkManager at the application's delayed Wi-Fi stage.
if [ -f "$TARGET_DIR/etc/init.d/S30dbus-daemon" ]; then
    mv "$TARGET_DIR/etc/init.d/S30dbus-daemon" \
        "$TARGET_DIR/etc/init.d/dbus-daemon"
fi
if [ -f "$TARGET_DIR/etc/init.d/S45NetworkManager" ]; then
    mv "$TARGET_DIR/etc/init.d/S45NetworkManager" \
        "$TARGET_DIR/etc/init.d/NetworkManager"
fi

# The application selects /etc/localtime at runtime from the timezone database.
# Keep Buildroot's UTC default valid and fail the image build if tzdata has
# somehow been omitted or /etc/localtime is left dangling.
[ -r "$TARGET_DIR/usr/share/zoneinfo/Etc/UTC" ] || {
    echo "error: NextGen timezone database is missing Etc/UTC" >&2
    exit 1
}
[ -e "$TARGET_DIR/etc/localtime" ] || {
    echo "error: NextGen /etc/localtime is missing or dangling" >&2
    exit 1
}

# The USB recovery helper remains installed for manual/serial recovery, but it
# must not run automatically: the application now waits until settings and
# engineering state are final, then creates the selected gadget exactly once.
if [ -f "$TARGET_DIR/etc/init.d/S50usb-gadget" ]; then
    mv "$TARGET_DIR/etc/init.d/S50usb-gadget" \
        "$TARGET_DIR/etc/init.d/usb-gadget"
fi

# sshd is engineering infrastructure, not a product startup dependency.
# Starting it from rcS also performs first-boot host-key generation on the
# Cortex-A5. Keep the script installed; the application launches it in the
# background after the UI/measurement path is running when engineering mode
# is enabled.
if [ -f "$TARGET_DIR/etc/init.d/S50sshd" ]; then
    mv "$TARGET_DIR/etc/init.d/S50sshd" \
        "$TARGET_DIR/etc/init.d/sshd"
fi

# dnsmasq is only used by the engineering USB NCM path. usbcontrol.sh starts
# an isolated instance with its own PID/lease files when NCM is selected.
# Keep the package installed but never start the package-wide daemon from rcS.
if [ -f "$TARGET_DIR/etc/init.d/S80dnsmasq" ]; then
    mv "$TARGET_DIR/etc/init.d/S80dnsmasq" \
        "$TARGET_DIR/etc/init.d/dnsmasq"
fi

# The application has its own persistent logging. rsyslog is useful for
# engineering/kernel diagnostics but is not required for normal operation, so
# keep it installed without letting it compete with early UI/measurement work.
if [ -f "$TARGET_DIR/etc/init.d/S01rsyslogd" ]; then
    mv "$TARGET_DIR/etc/init.d/S01rsyslogd" \
        "$TARGET_DIR/etc/init.d/rsyslogd"
fi

# /etc/network/interfaces contains only loopback. S00NextGen brings lo up
# directly before the application, so the generic ifupdown pass is redundant.
if [ -f "$TARGET_DIR/etc/init.d/S40network" ]; then
    mv "$TARGET_DIR/etc/init.d/S40network" \
        "$TARGET_DIR/etc/init.d/network"
fi

# Skip the generic sysctl walker only when the finished target contains no
# sysctl configuration from either NextGen or a selected package. This keeps
# the optimisation safe if a future Buildroot package adds a real requirement.
SYSCTL_CONFIG_FOUND=0
for conf in \
    "$TARGET_DIR/etc/sysctl.conf" \
    "$TARGET_DIR"/etc/sysctl.d/*.conf \
    "$TARGET_DIR"/usr/local/lib/sysctl.d/*.conf \
    "$TARGET_DIR"/usr/lib/sysctl.d/*.conf \
    "$TARGET_DIR"/lib/sysctl.d/*.conf
do
    [ -f "$conf" ] || continue
    SYSCTL_CONFIG_FOUND=1
    break
done
if [ "$SYSCTL_CONFIG_FOUND" -eq 0 ] && [ -f "$TARGET_DIR/etc/init.d/S02sysctl" ]; then
    mv "$TARGET_DIR/etc/init.d/S02sysctl" \
        "$TARGET_DIR/etc/init.d/sysctl"
fi

# Keep WILC genuinely on-demand in the deferred profiles.  eudev is allowed
# to autoload the other deferred DT drivers, but the application explicitly
# starts D-Bus and NetworkManager, waits for NetworkManager's D-Bus service to
# become ready, then modprobes WILC at its delayed Wi-Fi stage.
WILC_MODPROBE_CONF="$TARGET_DIR/etc/modprobe.d/nextgen-wilc-deferred.conf"
rm -f "$WILC_MODPROBE_CONF"
case "$KERNEL_PROFILE" in
    deferred|deferred-diag)
        mkdir -p "$TARGET_DIR/etc/modprobe.d"
        cat > "$WILC_MODPROBE_CONF" <<'EOF'
# NextGen fast boot: Wi-Fi is loaded explicitly by the application.
blacklist wilc-spi
blacklist wilc1000-spi
EOF
        ;;
esac

# NOR and NAND are not part of SD-root startup.  Some kernel profiles build
# the flash path in while older/deferred profiles carry parts of it as modules.
# Only blacklist components that are actually modules in the selected external
# kernel build; a blacklist has no effect on built-in drivers.
FLASH_MODPROBE_CONF="$TARGET_DIR/etc/modprobe.d/nextgen-flash-deferred.conf"
rm -f "$FLASH_MODPROBE_CONF"
case "$KERNEL_PROFILE" in
    deferred|deferred-diag)
        FLASH_BLACKLIST=""

        if grep -q '^CONFIG_SPI_ATMEL_QUADSPI=m$' "$KERNEL_BUILD_DIR/.config" 2>/dev/null; then
            FLASH_BLACKLIST="$FLASH_BLACKLIST
blacklist atmel-quadspi"
        fi
        if grep -q '^CONFIG_MTD_SPI_NOR=m$' "$KERNEL_BUILD_DIR/.config" 2>/dev/null; then
            FLASH_BLACKLIST="$FLASH_BLACKLIST
blacklist spi-nor"
        fi
        if grep -q '^CONFIG_MTD_SPI_NAND=m$' "$KERNEL_BUILD_DIR/.config" 2>/dev/null; then
            FLASH_BLACKLIST="$FLASH_BLACKLIST
blacklist spinand"
        fi

        if [ -n "$FLASH_BLACKLIST" ]; then
            mkdir -p "$TARGET_DIR/etc/modprobe.d"
            {
                echo '# NextGen SD fast boot: defer flash drivers that are modules.'
                printf '%s\n' "$FLASH_BLACKLIST"
            } > "$FLASH_MODPROBE_CONF"
        fi
        ;;
esac

# The Atmel UDC has a DT modalias, so eudev would otherwise load it during
# early userspace even though gadget construction is application-owned.
USB_GADGET_MODPROBE_CONF="$TARGET_DIR/etc/modprobe.d/nextgen-usb-gadget-deferred.conf"
rm -f "$USB_GADGET_MODPROBE_CONF"
case "$KERNEL_PROFILE" in
    deferred|deferred-diag)
        mkdir -p "$TARGET_DIR/etc/modprobe.d"
        cat > "$USB_GADGET_MODPROBE_CONF" <<'EOF'
# NextGen fast boot: the application loads the UDC only for a non-zero USB mask.
blacklist atmel_usba_udc
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

# Signed routine updates are enabled by supplying only the public verification
# key to Buildroot. The private signing key never belongs in the image/repo.
UPDATE_PUBLIC_KEY="${NEXTGEN_UPDATE_PUBLIC_KEY:-}"
REQUIRE_SIGNED_UPDATES="${NEXTGEN_REQUIRE_SIGNED_UPDATES:-0}"
case "$REQUIRE_SIGNED_UPDATES" in 0|1) ;; *)
    echo "error: NEXTGEN_REQUIRE_SIGNED_UPDATES must be 0 or 1" >&2
    exit 1
    ;;
esac

rm -f "$PLATFORM_SHARE/update-public.pem"
if [ -n "$UPDATE_PUBLIC_KEY" ]; then
    [ -f "$UPDATE_PUBLIC_KEY" ] && [ ! -L "$UPDATE_PUBLIC_KEY" ] || {
        echo "error: NEXTGEN_UPDATE_PUBLIC_KEY must name a regular public-key PEM" >&2
        exit 1
    }
    install -m 0644 "$UPDATE_PUBLIC_KEY" "$PLATFORM_SHARE/update-public.pem"
    printf '%s\n' ed25519-required > "$PLATFORM_SHARE/update-signing-policy"
elif [ "$REQUIRE_SIGNED_UPDATES" = 1 ]; then
    echo "error: signed updates required but NEXTGEN_UPDATE_PUBLIC_KEY is unset" >&2
    exit 1
else
    printf '%s\n' unsigned-development > "$PLATFORM_SHARE/update-signing-policy"
fi

# Shared fonts are platform-owned and do not participate in application slot
# switching. Release-dependent translations live beside the executable.
for name in Arial.ttf NotoSansCJKtc-Regular.ttf ionicons.ttf open-iconic.ttf; do
    [ ! -e "$COMMON_RUNTIME/$name" ] || install -m 0644 "$COMMON_RUNTIME/$name" "$PLATFORM_SHARE/$name"
done

case "$PRODUCT" in
    sound)
        APP_BINARY="$APP_DIR/Application/build/sound/bin/NextGen"
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
# or changing startup/UI code.
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

APP_VERSION="$(
    awk '/^[[:space:]]*#define[[:space:]]+VERSION[[:space:]]+[0-9]+/{print $3; exit}' \
        "$APP_DIR/Application/Version.h"
)"
case "$APP_VERSION" in
    ''|*[!0-9]*) echo "error: cannot determine application VERSION" >&2; exit 1 ;;
esac

SLOT_A="$APP_REALM/slotA"
FACTORY="$APP_REALM/factory"
mkdir -p "$SLOT_A" "$FACTORY"

install -m 0755 "$APP_BINARY" "$SLOT_A/NextGen"
install -m 0755 "$APP_BINARY" "$FACTORY/NextGen"
install -m 0644 "$APP_DIR/Application/Files/Translations.csv" "$SLOT_A/Translations.csv"
install -m 0644 "$APP_DIR/Application/Files/Translations.csv" "$FACTORY/Translations.csv"

if [ "$PRODUCT" = "sound" ]; then
    [ -f "$APP_DIR/Application/Files/hpdc.csv" ] || {
        echo "error: sound HPD database is missing" >&2
        exit 1
    }
    mkdir -p "$SLOT_A/BaseHPD" "$FACTORY/BaseHPD"
    install -m 0644 "$APP_DIR/Application/Files/hpdc.csv" "$SLOT_A/BaseHPD/hpdc.csv"
    install -m 0644 "$APP_DIR/Application/Files/hpdc.csv" "$FACTORY/BaseHPD/hpdc.csv"

    if [ -d "$COMMON_RUNTIME/Templates" ]; then
        mkdir -p "$DATA_REALM/Templates"
        cp -aL "$COMMON_RUNTIME/Templates/." "$DATA_REALM/Templates/"
    fi
    [ ! -f "$COMMON_RUNTIME/FacCalFile.dat" ] ||
        install -m 0644 "$COMMON_RUNTIME/FacCalFile.dat" "$DATA_REALM/FacCalFile.dat"
fi

for slot in "$SLOT_A" "$FACTORY"; do
    cat > "$slot/bundle.info" <<EOF
format=2
product=$PRODUCT
version=$APP_VERSION
EOF
done

ln -s slotA "$APP_REALM/active"
ln -s slotA "$APP_REALM/previous"
printf 'slotA %s\n' "$APP_VERSION" > "$STATE_REALM/accepted"

# Make the initial image durable and self-consistent before filesystem packing.
[ -x "$APP_REALM/active/NextGen" ] ||
    { echo "error: active application slot is invalid" >&2; exit 1; }
[ -r "$APP_REALM/active/Translations.csv" ] ||
    { echo "error: active application translations are missing" >&2; exit 1; }
[ -x "$PLATFORM_BIN/nextgen-update-install" ] ||
    { echo "error: application slot installer is missing" >&2; exit 1; }
[ -x "$PLATFORM_BIN/nextgen-update-accept" ] ||
    { echo "error: application slot acceptor is missing" >&2; exit 1; }
[ -x "$PLATFORM_BIN/usbcontrol.sh" ] ||
    { echo "error: platform USB helper is missing" >&2; exit 1; }
[ -x "$PLATFORM_BIN/fwenv.sh" ] ||
    { echo "error: platform fwenv helper is missing" >&2; exit 1; }
[ -r "$PLATFORM_SHARE/update-signing-policy" ] ||
    { echo "error: update signing policy is missing" >&2; exit 1; }
[ -x "$TARGET_DIR/usr/bin/openssl" ] ||
    { echo "error: target OpenSSL verifier is missing" >&2; exit 1; }
[ ! -e "$TARGET_DIR/root/Exec" ] ||
    { echo "error: obsolete /root/Exec survived image staging" >&2; exit 1; }
[ ! -e "$TARGET_DIR/root/NextGen" ] ||
    { echo "error: obsolete /root/NextGen survived image staging" >&2; exit 1; }


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
