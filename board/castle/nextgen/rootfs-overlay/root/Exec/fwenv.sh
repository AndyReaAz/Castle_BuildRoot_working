#!/bin/sh
set -u

SD_CONFIG=/etc/fw_env.sd.config
FLASH_CONFIG=/etc/fw_env.flash.config

die()
{
    echo "fwenv: $*" >&2
    exit 1
}

select_config()
{
    CMDLINE="$(cat /proc/cmdline 2>/dev/null || true)"
    BACKEND=""

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
            fi
            printf '%s\n' "$SD_CONFIG"
            ;;
        flash)
            # Deliberately no guessed fallback here. The current kernel NOR
            # partition map is not authoritative, so flash environment access
            # is enabled only when an explicitly validated config is installed.
            [ -r "$FLASH_CONFIG" ] ||
                die "flash environment config is not installed"
            printf '%s\n' "$FLASH_CONFIG"
            ;;
        *)
            die "unsupported backend: $BACKEND"
            ;;
    esac
}

[ "$#" -ge 1 ] || die "usage: $0 {print|set|config} [arguments...]"
ACTION="$1"
shift

CONFIG="$(select_config)" || exit $?

case "$ACTION" in
    config)
        [ "$#" -eq 0 ] || die "config takes no arguments"
        printf '%s\n' "$CONFIG"
        ;;
    print)
        exec /usr/bin/fw_printenv -c "$CONFIG" "$@"
        ;;
    set)
        [ "$#" -ge 1 ] || die "set requires a variable name"
        exec /usr/bin/fw_setenv -c "$CONFIG" "$@"
        ;;
    *)
        die "unknown action: $ACTION"
        ;;
esac
