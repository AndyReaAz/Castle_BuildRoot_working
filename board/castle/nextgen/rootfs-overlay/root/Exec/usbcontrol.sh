#!/bin/sh

GADGET=/sys/kernel/config/usb_gadget/g1
CONFIG="$GADGET/configs/c.1"
FUNCTIONFS=/dev/ffs-mtp
USB_COMMON=/root/Exec/usb-gadget-common.sh
LOG_DIR=/run/log

MTP_PID=/run/umtprd.pid
MTP_LOG="$LOG_DIR/umtprd.log"

DNSMASQ_PID=/run/dnsmasq-usb.pid
DNSMASQ_LEASES=/run/dnsmasq-usb.leases
DNSMASQ_LOG="$LOG_DIR/dnsmasq-usb.log"

if [ -r "$USB_COMMON" ]; then
    # shellcheck source=/dev/null
    . "$USB_COMMON"
fi

USB_IP="${USB_IP:-192.168.7.2}"
USB_NETMASK="${USB_NETMASK:-255.255.255.0}"
USB_DEV_MAC="${USB_DEV_MAC:-02:12:34:56:78:9a}"
USB_HOST_MAC="${USB_HOST_MAC:-06:12:34:56:78:9b}"

BIT_CDC=1
BIT_NCM=2
BIT_MTP=4
VALID_MASK=7

find_udc()
{
    for udc in /sys/class/udc/*; do
        [ -e "$udc" ] || continue
        basename "$udc"
        return 0
    done

    return 1
}

function_enabled()
{
    [ -L "$CONFIG/$1" ]
}

current_mask()
{
    mask=0

    function_enabled acm.usb0 && mask=$((mask | BIT_CDC))
    function_enabled ncm.usb0 && mask=$((mask | BIT_NCM))
    function_enabled ffs.mtp && mask=$((mask | BIT_MTP))

    echo "$mask"
}

mask_name()
{
    mask="$1"
    name=""

    [ $((mask & BIT_CDC)) -ne 0 ] && name="${name}+cdc"
    [ $((mask & BIT_NCM)) -ne 0 ] && name="${name}+ncm"
    [ $((mask & BIT_MTP)) -ne 0 ] && name="${name}+mtp"

    if [ -z "$name" ]; then
        echo "none"
    else
        echo "${name#+}"
    fi
}

mode_to_mask()
{
    case "$1" in
        none|off)
            echo 0
            return 0
            ;;
        cdc|acm)
            echo "$BIT_CDC"
            return 0
            ;;
        ncm|network)
            echo "$BIT_NCM"
            return 0
            ;;
        mtp|drive)
            echo "$BIT_MTP"
            return 0
            ;;
        all)
            echo "$VALID_MASK"
            return 0
            ;;
    esac

    mask=0
    old_ifs="$IFS"
    IFS="+"
    set -- $1
    IFS="$old_ifs"

    for item in "$@"; do
        case "$item" in
            cdc|acm)
                mask=$((mask | BIT_CDC))
                ;;
            ncm|network)
                mask=$((mask | BIT_NCM))
                ;;
            mtp|drive)
                mask=$((mask | BIT_MTP))
                ;;
            *)
                return 1
                ;;
        esac
    done

    echo "$mask"
}

mtp_running()
{
    if [ -f "$MTP_PID" ]; then
        pid="$(cat "$MTP_PID" 2>/dev/null)"

        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            return 0
        fi
    fi

    return 1
}

stop_mtp()
{
    if [ -f "$MTP_PID" ]; then
        pid="$(cat "$MTP_PID" 2>/dev/null)"

        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            kill "$pid" 2>/dev/null || true

            count=0
            while [ "$count" -lt 20 ] && [ -d "/proc/$pid" ]; do
                sleep 0.1
                count=$((count + 1))
            done

            [ -d "/proc/$pid" ] && kill -9 "$pid" 2>/dev/null || true
        fi

        rm -f "$MTP_PID"
    fi

    umount "$FUNCTIONFS" 2>/dev/null || true
}

start_mtp()
{
    mkdir -p "$LOG_DIR"

    if [ -r "$USB_COMMON" ]; then
        usb_mtp_write_config || {
            echo "Failed to generate MTP configuration"
            return 1
        }
    fi

    mkdir -p "$FUNCTIONFS"

    if ! grep -qs " $FUNCTIONFS " /proc/mounts; then
        mount -t functionfs mtp "$FUNCTIONFS" || {
            echo "Failed to mount MTP FunctionFS"
            return 1
        }
    fi

    if ! mtp_running; then
        umtprd >"$MTP_LOG" 2>&1 &
        echo $! >"$MTP_PID"
        sleep 1
    fi

    if ! mtp_running; then
        echo "umtprd failed to start"
        return 1
    fi

    return 0
}

stop_usb_dhcp()
{
    if [ -f "$DNSMASQ_PID" ]; then
        pid="$(cat "$DNSMASQ_PID" 2>/dev/null)"

        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            kill "$pid" 2>/dev/null || true

            count=0
            while [ "$count" -lt 20 ] && [ -d "/proc/$pid" ]; do
                sleep 0.1
                count=$((count + 1))
            done
        fi

        rm -f "$DNSMASQ_PID"
    fi

    rm -f "$DNSMASQ_LEASES"
}

start_usb_dhcp()
{
    stop_usb_dhcp
    mkdir -p "$LOG_DIR"

    dnsmasq \
        --interface=usb0 \
        --bind-interfaces \
        --port=0 \
        --conf-file=/dev/null \
        --dhcp-range=192.168.7.10,192.168.7.10,255.255.255.0,24h \
        --dhcp-option=3 \
        --dhcp-option=6 \
        --pid-file="$DNSMASQ_PID" \
        --dhcp-leasefile="$DNSMASQ_LEASES" \
        >"$DNSMASQ_LOG" 2>&1 || {
            echo "Failed to start USB DHCP server"
            return 1
        }

    count=0
    while [ "$count" -lt 20 ]; do
        if [ -f "$DNSMASQ_PID" ]; then
            pid="$(cat "$DNSMASQ_PID" 2>/dev/null)"

            if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
                return 0
            fi
        fi

        sleep 0.1
        count=$((count + 1))
    done

    echo "USB DHCP server did not remain running"
    return 1
}

wait_for_usb0()
{
    count=0

    while [ "$count" -lt 30 ]; do
        [ -d /sys/class/net/usb0 ] && return 0
        sleep 0.1
        count=$((count + 1))
    done

    return 1
}

net_down()
{
    stop_usb_dhcp
    ifconfig usb0 down 2>/dev/null || true
}

net_up()
{
    wait_for_usb0 || {
        echo "usb0 did not appear"
        return 1
    }

    ifconfig usb0 "$USB_IP" netmask "$USB_NETMASK" up || {
        echo "Failed to configure usb0"
        return 1
    }

    start_usb_dhcp || return 1
    return 0
}

usb_down()
{
    net_down
    echo "" >"$GADGET/UDC" 2>/dev/null || true
}

clear_links()
{
    rm -f "$CONFIG/acm.usb0" 2>/dev/null || true
    rm -f "$CONFIG/ncm.usb0" 2>/dev/null || true
    rm -f "$CONFIG/ffs.mtp" 2>/dev/null || true
}

link_function()
{
    function="$1"

    if [ ! -d "$GADGET/functions/$function" ]; then
        echo "Missing USB function: $function"
        return 1
    fi

    if [ "$function" = "ncm.usb0" ]; then
        echo "$USB_DEV_MAC" >"$GADGET/functions/ncm.usb0/dev_addr" || return 1
        echo "$USB_HOST_MAC" >"$GADGET/functions/ncm.usb0/host_addr" || return 1
    fi

    ln -s "$GADGET/functions/$function" "$CONFIG/$function" || {
        echo "Failed to link USB function: $function"
        return 1
    }

    return 0
}

usb_up()
{
    udc="$(find_udc)" || {
        echo "No USB device controller found"
        return 1
    }

    echo "$udc" >"$GADGET/UDC" || {
        echo "Failed to bind USB device controller: $udc"
        return 1
    }

    sleep 1

    if function_enabled ncm.usb0; then
        net_up || return 1
    fi

    return 0
}

repair_current_state()
{
    mask="$1"

    if [ $((mask & BIT_MTP)) -ne 0 ]; then
        start_mtp || return 1
    else
        stop_mtp
    fi

    if [ $((mask & BIT_NCM)) -ne 0 ]; then
        net_up || return 1
    else
        net_down
    fi

    return 0
}

apply_mask()
{
    requested="$1"

    case "$requested" in
        ''|*[!0-9]*)
            echo "Invalid USB mask: $requested"
            return 1
            ;;
    esac

    if [ "$requested" -gt "$VALID_MASK" ]; then
        echo "USB mask must be between 0 and $VALID_MASK"
        return 1
    fi

    current="$(current_mask)"

    if [ "$current" -eq "$requested" ]; then
        repair_current_state "$requested" || return 1
        echo "USB mode already set: $(mask_name "$requested") mask=$requested"
        return 0
    fi

    usb_down
    clear_links
    stop_mtp

    if [ "$requested" -eq 0 ]; then
        echo "USB disabled"
        return 0
    fi

    if [ $((requested & BIT_CDC)) -ne 0 ]; then
        link_function acm.usb0 || return 1
    fi

    if [ $((requested & BIT_NCM)) -ne 0 ]; then
        link_function ncm.usb0 || return 1
    fi

    if [ $((requested & BIT_MTP)) -ne 0 ]; then
        link_function ffs.mtp || return 1
        start_mtp || return 1
    fi

    usb_up || {
        usb_down
        clear_links
        stop_mtp
        return 1
    }

    echo "USB mode set: $(mask_name "$requested") mask=$requested"
    return 0
}

status()
{
    mask="$(current_mask)"

    echo "UDC         : $(cat "$GADGET/UDC" 2>/dev/null)"
    echo "Mask        : $mask"
    echo "Mode        : $(mask_name "$mask")"

    if function_enabled acm.usb0; then
        echo "CDC ACM     : on (/dev/ttyGS0)"
    else
        echo "CDC ACM     : off"
    fi

    if function_enabled ncm.usb0; then
        echo "NCM         : on (usb0)"
    else
        echo "NCM         : off"
    fi

    if function_enabled ffs.mtp; then
        echo "MTP         : on"
    else
        echo "MTP         : off"
    fi

    if mtp_running; then
        echo "umtprd      : running"
    else
        echo "umtprd      : stopped"
    fi

    if [ -f "$DNSMASQ_PID" ]; then
        pid="$(cat "$DNSMASQ_PID" 2>/dev/null)"

        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            echo "USB DHCP    : running"
        else
            echo "USB DHCP    : stale PID file"
        fi
    else
        echo "USB DHCP    : stopped"
    fi

    echo "USB IP      : $USB_IP"
    echo "USB netmask : $USB_NETMASK"
    echo "Device MAC  : $USB_DEV_MAC"
    echo "Host MAC    : $USB_HOST_MAC"

    ifconfig usb0 2>/dev/null | head -n 2
}

usage()
{
    echo "Usage:"
    echo "  $0 status"
    echo "  $0 mask 0..7"
    echo "  $0 mode none|cdc|ncm|mtp|cdc+ncm|cdc+mtp|ncm+mtp|all"
    echo ""
    echo "Mask bits:"
    echo "  1 = CDC ACM"
    echo "  2 = NCM network"
    echo "  4 = MTP"
}

case "$1" in
    status)
        status
        ;;

    mask)
        [ -n "$2" ] || {
            usage
            exit 1
        }

        apply_mask "$2"
        ;;

    mode)
        [ -n "$2" ] || {
            usage
            exit 1
        }

        mask="$(mode_to_mask "$2")" || {
            echo "Unknown USB mode: $2"
            exit 1
        }

        apply_mask "$mask"
        ;;

    none|off|cdc|acm|ncm|network|mtp|drive|all|*+*)
        mask="$(mode_to_mask "$1")" || {
            echo "Unknown USB mode: $1"
            exit 1
        }

        apply_mask "$mask"
        ;;

    *)
        usage
        exit 1
        ;;
esac

exit $?
