#!/bin/sh
USB_GADGET_ROOT="${USB_GADGET_ROOT:-/sys/kernel/config/usb_gadget/g1}"
USB_MTP_ROOT="${USB_MTP_ROOT:-/sdcard/public}"
USB_MTP_RUNTIME_DIR="${USB_MTP_RUNTIME_DIR:-/run/umtprd}"
USB_MTP_CONFIG="${USB_MTP_CONFIG:-$USB_MTP_RUNTIME_DIR/umtprd.conf}"
USB_MTP_CONFIG_LINK="${USB_MTP_CONFIG_LINK:-/etc/umtprd/umtprd.conf}"

usb_mtp_read_identity()
{
    USB_MTP_MANUFACTURER="$(cat "$USB_GADGET_ROOT/strings/0x409/manufacturer" 2>/dev/null || echo "Castle Group")"
    USB_MTP_PRODUCT="$(cat "$USB_GADGET_ROOT/strings/0x409/product" 2>/dev/null || echo "NextGen")"
    USB_MTP_SERIAL="$(cat "$USB_GADGET_ROOT/strings/0x409/serialnumber" 2>/dev/null || echo "000000")"
    USB_MTP_FIRMWARE="unknown"
    if [ -r "$USB_MTP_ROOT/ver.log" ]; then
        value="$(sed -n '2p' "$USB_MTP_ROOT/ver.log" 2>/dev/null | tr -d '\r\n"' | cut -c1-63)"
        [ -n "$value" ] && USB_MTP_FIRMWARE="$value"
    fi
}

usb_mtp_ensure_config_link()
{
    mkdir -p "$USB_MTP_RUNTIME_DIR" "$(dirname "$USB_MTP_CONFIG_LINK")" || return 1
    if [ -L "$USB_MTP_CONFIG_LINK" ] &&
       [ "$(readlink "$USB_MTP_CONFIG_LINK" 2>/dev/null)" = "$USB_MTP_CONFIG" ]; then
        return 0
    fi
    rm -f "$USB_MTP_CONFIG_LINK" || return 1
    ln -s "$USB_MTP_CONFIG" "$USB_MTP_CONFIG_LINK" || return 1
}

usb_mtp_write_config()
{
    usb_mtp_read_identity
    usb_mtp_ensure_config_link || return 1
    mkdir -p "$USB_MTP_RUNTIME_DIR" "$USB_MTP_ROOT" || return 1
    tmp="$USB_MTP_CONFIG.tmp.$$"
    umask 022
    cat > "$tmp" <<EOF_CONFIG
# Generated at runtime from the active USB identity. Stored in RAM.
loop_on_disconnect 1
umask 022
storage "$USB_MTP_ROOT" "Storage" "rw"
manufacturer "$USB_MTP_MANUFACTURER"
product "$USB_MTP_PRODUCT"
serial "$USB_MTP_SERIAL"
firmware_version "$USB_MTP_FIRMWARE"
mtp_extensions ""
interface "MTP"
usb_vendor_id 0x1D6B
usb_product_id 0x0104
usb_class 0x06
usb_subclass 0x01
usb_protocol 0x01
usb_dev_version 0x0100
usb_functionfs_mode 0x1
usb_dev_path "/dev/ffs-mtp/ep0"
usb_epin_path "/dev/ffs-mtp/ep1"
usb_epout_path "/dev/ffs-mtp/ep2"
usb_epint_path "/dev/ffs-mtp/ep3"
usb_max_packet_size 0x200
usb_max_rd_buffer_size 0x2000
usb_max_wr_buffer_size 0x2000
read_buffer_cache_size 0x100000
EOF_CONFIG
    mv -f "$tmp" "$USB_MTP_CONFIG" || { rm -f "$tmp"; return 1; }
}
