#!/bin/sh
set -u

SCREEN=/opt/nextgen/platform/bin/nextgen-bringup-screen
PROVISIONER=/opt/nextgen/platform/bin/nextgen-provision-storage
FUSE_ADDR=0xf804c060
FUSE_EXPECTED=0x00060B3F

log()
{
    echo "BRINGUP: $*"
}

screen_progress()
{
    "$SCREEN" progress "NEXTGEN BRING-UP" "" "$1" 2>/dev/null
}

fail()
{
    reason="$1"
    log "FAILED: $reason"
    "$SCREEN" fail \
        "PROVISIONING FAILED" \
        "" \
        "DO NOT USE THIS UNIT" \
        "" \
        "See service console" 2>/dev/null || true
    return 1
}

require_mtd_label()
{
    label="$1"
    grep -q " \"$label\"$" /proc/mtd 2>/dev/null ||
        fail "missing MTD partition: $label"
}

main()
{
    screen_progress "Checking hardware..." || {
        log "LCD/fbcon is unavailable; refusing provisioning"
        return 1
    }
    log "starting provisioning preflight"

    [ -r /proc/mtd ] || fail "/proc/mtd is unavailable" || return 1

    # Kernel and DTB are UBI volumes inside the "boot" MTD partition,
    # not standalone MTD partitions.
    for label in at91bootstrap uboot uboot-env boot rootfs
    do
        require_mtd_label "$label" || return 1
    done

    command -v devmem >/dev/null 2>&1 ||
        fail "devmem is unavailable for fuse verification" || return 1

    fuse="$(devmem "$FUSE_ADDR" 32 2>/dev/null || true)"
    log "boot fuse = ${fuse:-unreadable}"
    [ "$fuse" = "$FUSE_EXPECTED" ] ||
        fail "boot fuse is not $FUSE_EXPECTED" || return 1

    screen_progress "Preparing provisioning..." ||
        fail "LCD/fbcon became unavailable" || return 1

    [ -x "$PROVISIONER" ] ||
        fail "storage provisioner is not installed" || return 1

    screen_progress "Starting provisioning..." ||
        fail "LCD/fbcon became unavailable" || return 1
    log "starting storage provisioner"

    "$PROVISIONER"
    provision_rc=$?

    if [ "$provision_rc" -eq 64 ]; then
        log "storage provisioning is not armed in this build"
        "$SCREEN" hold \
            "BRING-UP IMAGE READY" \
            "" \
            "PROVISIONING NOT ARMED" \
            "" \
            "See service console" 2>/dev/null || {
                log "bring-up hold screen could not be displayed"
                return 1
            }
        return 0
    fi

    [ "$provision_rc" -eq 0 ] ||
        fail "storage provisioning failed (rc=$provision_rc)" || return 1

    screen_progress "Final verification..." ||
        fail "LCD/fbcon became unavailable" || return 1
    log "running final sync"
    sync

    log "provisioning completed successfully"
    "$SCREEN" success \
        "PROVISIONING COMPLETE" \
        "" \
        "REMOVE USB POWER" \
        "AND SD CARD" 2>/dev/null || {
            log "provisioning completed but the pass screen could not be displayed"
            return 1
        }

    return 0
}

trap 'fail "provisioning interrupted"; exit 1' HUP INT TERM
main
