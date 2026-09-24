#!/bin/sh
set -u

SD_CONFIG=/etc/fw_env.sd.config
FLASH_CONFIG=/etc/fw_env.flash.config

BACKEND=""
CONFIG=""
BOOT_MOUNTED_BY_US=0

die()
{
    echo "fwenv: $*" >&2
    exit 1
}

find_tool()
{
    TOOL="$(command -v "$1" 2>/dev/null || true)"
    [ -n "$TOOL" ] || die "missing $1"
    printf '%s\n' "$TOOL"
}

cleanup()
{
    STATUS=$?

    if [ "$BOOT_MOUNTED_BY_US" -eq 1 ]; then
        # A write may still be completing through the FAT block cache.
        sync
        umount /boot || {
            echo "fwenv: warning: unable to unmount /boot" >&2
            [ "$STATUS" -ne 0 ] || STATUS=1
        }
        BOOT_MOUNTED_BY_US=0
    fi

    trap - EXIT INT TERM
    exit "$STATUS"
}

select_config()
{
    CMDLINE="$(cat /proc/cmdline 2>/dev/null || true)"

    case " $CMDLINE " in
        *" nextgen.env=sd "*)
            BACKEND=sd
            ;;
        *" nextgen.env=nor "*|*" nextgen.env=flash "*)
            BACKEND=flash
            ;;
    esac

    if [ -z "$BACKEND" ]; then
        # Compatibility only for the existing SD image, which predates the
        # explicit nextgen.env= marker. A flash boot must provide the marker;
        # do not guess a writable NOR target from MTD numbering.
        case " $CMDLINE " in
            *" root=/dev/mmcblk"*)
                BACKEND=sd
                ;;
            *)
                die "boot environment backend is not identified"
                ;;
        esac
    fi

    case "$BACKEND" in
        sd)
            [ -r "$SD_CONFIG" ] ||
                die "missing SD environment config: $SD_CONFIG"

            if ! grep -qs ' /boot ' /proc/mounts; then
                mount /boot ||
                    die "unable to mount /boot for SD U-Boot environment"
                BOOT_MOUNTED_BY_US=1
            fi
            CONFIG="$SD_CONFIG"
            ;;
        flash)
            # Deliberately no guessed fallback here. The current kernel NOR
            # partition map is not authoritative, so flash environment access
            # is enabled only when an explicitly validated config is installed.
            [ -r "$FLASH_CONFIG" ] ||
                die "flash environment config is not installed"
            CONFIG="$FLASH_CONFIG"
            ;;
        *)
            die "unsupported backend: $BACKEND"
            ;;
    esac
}

[ "$#" -ge 1 ] || die "usage: $0 {print|set|config} [arguments...]"
ACTION="$1"
shift

trap cleanup EXIT INT TERM
select_config

case "$ACTION" in
    config)
        [ "$#" -eq 0 ] || die "config takes no arguments"
        printf '%s\n' "$CONFIG"
        ;;
    print)
        FW_PRINTENV="$(find_tool fw_printenv)"
        "$FW_PRINTENV" -c "$CONFIG" "$@"
        ;;
    set)
        [ "$#" -ge 1 ] || die "set requires a variable name"
        FW_SETENV="$(find_tool fw_setenv)"
        "$FW_SETENV" -c "$CONFIG" "$@"
        # Ensure the FAT-backed environment is durable before cleanup unmounts
        # a boot partition that this wrapper mounted temporarily.
        [ "$BACKEND" != "sd" ] || sync
        ;;
    *)
        die "unknown action: $ACTION"
        ;;
esac
