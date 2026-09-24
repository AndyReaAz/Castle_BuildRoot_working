#!/bin/sh
set -u

SD_CONFIG=/etc/fw_env.sd.config
FLASH_CONFIG=/etc/fw_env.flash.config

BACKEND=""
CONFIG=""
BOOT_MOUNTED_BY_US=0
ENV_DIRTY=0

die()
{
    echo "fwenv: $*" >&2
    exit 1
}

find_tool()
{
    NAME="$1"

    for TOOL in "/usr/sbin/$NAME" "/usr/bin/$NAME"; do
        [ -x "$TOOL" ] && {
            printf '%s\n' "$TOOL"
            return 0
        }
    done

    TOOL="$(command -v "$NAME" 2>/dev/null || true)"
    [ -n "$TOOL" ] || die "missing $NAME"
    printf '%s\n' "$TOOL"
}

cleanup()
{
    STATUS=$?

    if [ "$BOOT_MOUNTED_BY_US" -eq 1 ]; then
        if [ "$ENV_DIRTY" -eq 1 ]; then
            # Make the FAT-backed environment durable before removing /boot.
            sync
        fi

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

set_if_changed()
{
    NAME="$1"
    VALUE="$2"

    LINE="$("$FW_PRINTENV" -c "$CONFIG" "$NAME" 2>/dev/null || true)"
    case "$LINE" in
        "$NAME=$VALUE")
            return 0
            ;;
    esac

    echo "fwenv: set $NAME=$VALUE" >&2
    ENV_DIRTY=1
    "$FW_SETENV" -c "$CONFIG" "$NAME" "$VALUE"
}

[ "$#" -ge 1 ] || die "usage: $0 {print|set|set-many|config} [arguments...]"
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
        ENV_DIRTY=1
        "$FW_SETENV" -c "$CONFIG" "$@"
        ;;
    set-many)
        [ "$#" -ge 2 ] || die "set-many requires name/value pairs"
        [ $(( $# % 2 )) -eq 0 ] || die "set-many requires name/value pairs"

        FW_PRINTENV="$(find_tool fw_printenv)"
        FW_SETENV="$(find_tool fw_setenv)"

        while [ "$#" -gt 0 ]; do
            NAME="$1"
            VALUE="$2"
            shift 2
            set_if_changed "$NAME" "$VALUE" || exit $?
        done
        ;;
    *)
        die "unknown action: $ACTION"
        ;;
esac
