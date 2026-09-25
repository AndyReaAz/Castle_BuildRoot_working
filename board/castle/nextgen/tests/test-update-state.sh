#!/bin/sh
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BOARD="$(CDPATH= cd -- "$HERE/.." && pwd)"
LAUNCHER="$BOARD/startup-ro.sh"
INSTALLER="$BOARD/nextgen-update-install-ro"
ACCEPTOR="$BOARD/nextgen-update-accept-ro"
COMMON="$BOARD/nextgen-slot-common-ro.sh"

for file in "$LAUNCHER" "$INSTALLER" "$ACCEPTOR" "$COMMON"; do
    [ -r "$file" ] || { echo "FAIL: missing $file" >&2; exit 1; }
done
for tool in awk chmod cp grep md5sum mkdir mktemp mv python3 rm sed sha256sum sync tr unzip wc; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: missing $tool" >&2; exit 77; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
TESTS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { TESTS=$((TESTS + 1)); echo "PASS: $*"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }
assert_exists() { [ -e "$1" ] || fail "$2: missing $1"; }
assert_not_exists() { [ ! -e "$1" ] || fail "$2: unexpected $1"; }

make_fake_image()
{
    image="$1"; product="$2"; version="$3"; exit_code="${4:-0}"
    cat > "$image" <<EOF_IMAGE
FAKE_SQFS=1
product=$product
version=$version
exit_code=$exit_code
platform_abi=1
EOF_IMAGE
}

write_slot_meta()
{
    root="$1"; product="$2"; slot="$3"; version="$4"
    image="$root/app/$product/$slot.sqfs"
    cat > "$root/app/$product/$slot.meta" <<EOF_META
format=4
product=$product
version=$version
platform_abi=1
bytes=$(wc -c < "$image")
sha256=$(sha256sum "$image" | awk '{print $1}')
EOF_META
}

make_slot()
{
    root="$1"; product="$2"; slot="$3"; version="$4"; exit_code="${5:-0}"
    mkdir -p "$root/app/$product"
    make_fake_image "$root/app/$product/$slot.sqfs" "$product" "$version" "$exit_code"
    chmod 0444 "$root/app/$product/$slot.sqfs"
    write_slot_meta "$root" "$product" "$slot" "$version"
}

make_factory()
{
    root="$1"; product="$2"; version="$3"; dir="$root/factory/$product"
    mkdir -p "$dir/BaseHPD"
    cat > "$dir/NextGen" <<EOF_APP
#!/bin/sh
echo RUN factory $version
exit 0
EOF_APP
    chmod 0755 "$dir/NextGen"
    printf 'translations %s\n' "$version" > "$dir/Translations.csv"
    [ "$product" != sound ] || printf 'hpd %s\n' "$version" > "$dir/BaseHPD/hpdc.csv"
    cat > "$dir/bundle.info" <<EOF_INFO
format=4
product=$product
version=$version
platform_abi=1
EOF_INFO
}

install_fake_mount_tools()
{
    d="$1/bin"; mkdir -p "$d"
    cat > "$d/losetup" <<'EOF_LOSETUP'
#!/bin/sh
set -eu
case "${1:-}" in
-f) printf '%s\n' "${FAKE_LOOP_DEVICE:?}" ;;
-r) printf '%s\n' "$3" > "${FAKE_LOOP_MAP:?}" ;;
-d) rm -f "${FAKE_LOOP_MAP:?}" ;;
*) exit 2 ;;
esac
EOF_LOSETUP
    cat > "$d/mount" <<'EOF_MOUNT'
#!/bin/sh
set -eu
while [ "$#" -gt 2 ]; do shift; done
source="$1"; target="$2"
rm -rf "$target"; mkdir -p "$target"
if [ "$source" = "${FAKE_LOOP_DEVICE:?}" ]; then
    image="$(cat "${FAKE_LOOP_MAP:?}")"
    [ -z "${FAKE_MOUNT_FAIL_MATCH:-}" ] || case "$image" in *"$FAKE_MOUNT_FAIL_MATCH"*) exit 1;; esac
    [ "$(sed -n 's/^FAKE_SQFS=//p' "$image")" = 1 ] || exit 1
    product="$(sed -n 's/^product=//p' "$image")"
    version="$(sed -n 's/^version=//p' "$image")"
    exit_code="$(sed -n 's/^exit_code=//p' "$image")"
    abi="$(sed -n 's/^platform_abi=//p' "$image")"
    mkdir -p "$target/BaseHPD"
    cat > "$target/NextGen" <<EOF_APP
#!/bin/sh
echo RUN $product $version
exit $exit_code
EOF_APP
    chmod 0755 "$target/NextGen"
    printf 'translations %s\n' "$version" > "$target/Translations.csv"
    [ "$product" != sound ] || printf 'hpd %s\n' "$version" > "$target/BaseHPD/hpdc.csv"
    printf 'format=4\nproduct=%s\nversion=%s\nplatform_abi=%s\n' "$product" "$version" "$abi" > "$target/bundle.info"
    fs=squashfs
else
    cp -a "$source/." "$target/"; fs=bind
fi
tmp="${FAKE_MOUNTS:?}.tmp"
awk -v p="$target" '$2 != p' "$FAKE_MOUNTS" > "$tmp" 2>/dev/null || true
printf '%s %s %s ro 0 0\n' "$source" "$target" "$fs" >> "$tmp"
mv -f "$tmp" "$FAKE_MOUNTS"
EOF_MOUNT
    cat > "$d/umount" <<'EOF_UMOUNT'
#!/bin/sh
set -eu
target="$1"; tmp="${FAKE_MOUNTS:?}.tmp"
awk -v p="$target" '$2 != p' "$FAKE_MOUNTS" > "$tmp" 2>/dev/null || true
mv -f "$tmp" "$FAKE_MOUNTS"
rm -rf "$target"; mkdir -p "$target"
EOF_UMOUNT
    chmod 0755 "$d/losetup" "$d/mount" "$d/umount"
}

make_fixture()
{
    c="$1"; accepted_ref="${2:-}"; accepted_version="${3:-}"
    mkdir -p "$c/root/app/sound/active" "$c/root/factory/sound" \
        "$c/root/state/sound" "$c/root/platform/bin" "$c/root/platform/share" \
        "$c/sdcard/public" "$c/sdcard/temp/TempFirmware" "$c/run"
    cp "$COMMON" "$c/root/platform/bin/nextgen-slot-common.sh"
    chmod 0755 "$c/root/platform/bin/nextgen-slot-common.sh"
    printf 'sound\n' > "$c/nextgen-product"
    printf '1\n' > "$c/nextgen-platform-abi"
    printf 'unsigned-development\n' > "$c/root/platform/share/update-signing-policy"
    : > "$c/mounts"; : > "$c/persist-ready"
    [ -z "$accepted_ref" ] || printf '%s %s\n' "$accepted_ref" "$accepted_version" > "$c/root/state/sound/accepted"
    install_fake_mount_tools "$c"
}

setup_known_good()
{
    c="$1"; version="${2:-110}"
    make_fixture "$c" slotA "$version"
    make_slot "$c/root" sound slotA "$version"
    make_factory "$c/root" sound "$version"
}

mount_sd() { printf 'fake %s ext4 rw 0 0\n' "$1/sdcard" >> "$1/mounts"; }

run_launcher()
{
    c="$1"
    PATH="$c/bin:$PATH" FAKE_LOOP_DEVICE="$c/loop0" FAKE_LOOP_MAP="$c/loop-map" \
    FAKE_MOUNTS="$c/mounts" FAKE_MOUNT_FAIL_MATCH="${FAKE_MOUNT_FAIL_MATCH:-}" \
    NEXTGEN_ROOT="$c/root" NEXTGEN_PRODUCT_FILE="$c/nextgen-product" \
    NEXTGEN_PERSIST_READY="$c/persist-ready" NEXTGEN_PLATFORM_ABI_FILE="$c/nextgen-platform-abi" \
    NEXTGEN_RUN_LOOP="$c/run/nextgen-app-loop" NEXTGEN_RUN_REF="$c/run/nextgen-app-ref" \
    NEXTGEN_MOUNTS_FILE="$c/mounts" /bin/sh "$LAUNCHER"
}

run_acceptor()
{
    c="$1"
    PATH="$c/bin:$PATH" FAKE_LOOP_DEVICE="$c/loop0" FAKE_LOOP_MAP="$c/loop-map" FAKE_MOUNTS="$c/mounts" \
    NEXTGEN_ROOT="$c/root" NEXTGEN_SDCARD_ROOT="$c/sdcard" NEXTGEN_MOUNTS_FILE="$c/mounts" \
    NEXTGEN_PLATFORM_ABI_FILE="$c/nextgen-platform-abi" NEXTGEN_RUN_REF="$c/run/nextgen-app-ref" \
    /bin/sh "$ACCEPTOR" sound
}

run_installer()
{
    c="$1"; package="$2"
    PATH="$c/bin:$PATH" FAKE_LOOP_DEVICE="$c/loop0" FAKE_LOOP_MAP="$c/loop-map" FAKE_MOUNTS="$c/mounts" \
    NEXTGEN_ROOT="$c/root" NEXTGEN_SDCARD_ROOT="$c/sdcard" NEXTGEN_RUN_ROOT="$c/run" \
    NEXTGEN_MOUNTS_FILE="$c/mounts" NEXTGEN_PLATFORM_ABI_FILE="$c/nextgen-platform-abi" \
    /bin/sh "$INSTALLER" sound "$package"
}

build_bundle()
{
    package="$1"; manifest_version="$2"; image_version="${3:-$manifest_version}"
    work="$TMP/bundle-$manifest_version-$$"; rm -rf "$work"; mkdir -p "$work"
    image="$work/Application.sqfs"
    make_fake_image "$image" sound "$image_version" 0
    bytes="$(wc -c < "$image")"; sha="$(sha256sum "$image" | awk '{print $1}')"
    manifest="$work/manifest.txt"
    printf 'NEXTGEN_APP_IMAGE 4 sound %s 1\nimage=Application.sqfs\nbytes=%s\nsha256=%s\n' \
        "$manifest_version" "$bytes" "$sha" > "$manifest"
    md5="$(md5sum "$manifest" | awk '{print $1}')"
    final_manifest="$work/manifest_V${manifest_version}_${md5}.txt"
    mv "$manifest" "$final_manifest"
    python3 - "$package" "$image" "$final_manifest" <<'PY'
import sys, zipfile
from pathlib import Path
package, image, manifest = map(Path, sys.argv[1:])
package.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(package, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    z.write(image, image.name)
    z.write(manifest, manifest.name)
PY
    rm -rf "$work"
}

test_install_boot_accept()
{
    c="$TMP/install"; setup_known_good "$c"; mount_sd "$c"
    p="$c/sdcard/public/update_V111.zip"; build_bundle "$p" 111
    run_installer "$c" "$p" >/dev/null
    assert_exists "$c/root/app/sound/slotB.sqfs" "slotB image"
    assert_eq "$(cat "$c/root/state/sound/pending")" "slotB slotA 111" "pending"
    assert_eq "$(cat "$c/root/state/sound/accepted")" "slotA 110" "accepted before boot"
    run_launcher "$c" >/dev/null
    assert_eq "$(cat "$c/root/state/sound/booting")" slotB "booting"
    assert_eq "$(cat "$c/run/nextgen-app-ref")" "slotB 111" "runtime ref"
    run_acceptor "$c" >/dev/null
    assert_eq "$(cat "$c/root/state/sound/accepted")" "slotB 111" "accepted after boot"
    assert_eq "$(cat "$c/root/state/sound/previous")" "slotA 110" "previous"
    assert_not_exists "$c/root/state/sound/pending" "pending cleared"
    assert_not_exists "$c/root/state/sound/cleanup" "cleanup cleared"
    assert_not_exists "$p" "accepted package removed"
    pass "format-4 install, candidate boot and acceptance"
}

test_unaccepted_candidate_rolls_back()
{
    c="$TMP/restart"; setup_known_good "$c"; make_slot "$c/root" sound slotB 111
    printf 'slotB slotA 111\n' > "$c/root/state/sound/pending"
    run_launcher "$c" >/dev/null
    run_launcher "$c" >/dev/null
    assert_eq "$(cat "$c/run/nextgen-app-ref")" "slotA 110" "rollback runtime"
    assert_exists "$c/root/state/sound/rollback" "rollback marker"
    assert_not_exists "$c/root/state/sound/pending" "rollback pending"
    assert_eq "$(cat "$c/root/state/sound/accepted")" "slotA 110" "accepted unchanged"
    pass "unaccepted candidate restart rolls back"
}

test_cleanup_before_pending_power_loss()
{
    c="$TMP/prepending"; setup_known_good "$c"; make_slot "$c/root" sound slotB 111; mount_sd "$c"
    p="$c/sdcard/public/update_V111.zip"; printf x > "$p"; printf '111 %s\n' "$p" > "$c/root/state/sound/cleanup"
    run_launcher "$c" >/dev/null
    assert_eq "$(cat "$c/run/nextgen-app-ref")" "slotA 110" "orphan inactive ignored"
    run_acceptor "$c" >/dev/null
    assert_exists "$p" "interrupted USB package retained"
    assert_not_exists "$c/root/state/sound/cleanup" "orphan cleanup reconciled"
    pass "power loss after image/cleanup but before pending"
}

test_previous_before_accepted_power_loss()
{
    c="$TMP/preaccepted"; setup_known_good "$c"; make_slot "$c/root" sound slotB 111
    printf 'slotB slotA 111\n' > "$c/root/state/sound/pending"; printf 'slotB\n' > "$c/root/state/sound/booting"
    printf 'slotA 110\n' > "$c/root/state/sound/previous"
    run_launcher "$c" >/dev/null
    assert_eq "$(cat "$c/run/nextgen-app-ref")" "slotA 110" "old runtime"
    assert_exists "$c/root/state/sound/rollback" "rollback after interrupted accept"
    assert_eq "$(cat "$c/root/state/sound/accepted")" "slotA 110" "accepted authoritative"
    pass "power loss after previous but before accepted"
}

test_accepted_before_marker_cleanup_power_loss()
{
    c="$TMP/postaccepted"; setup_known_good "$c"; make_slot "$c/root" sound slotB 111
    printf 'slotB slotA 111\n' > "$c/root/state/sound/pending"; printf 'slotB\n' > "$c/root/state/sound/booting"
    printf 'slotA 110\n' > "$c/root/state/sound/previous"; printf 'slotB 111\n' > "$c/root/state/sound/accepted"
    run_launcher "$c" >/dev/null
    assert_eq "$(cat "$c/run/nextgen-app-ref")" "slotB 111" "new runtime"
    assert_not_exists "$c/root/state/sound/pending" "stale pending cleared"
    assert_not_exists "$c/root/state/sound/rollback" "no rollback after durable accept"
    pass "durable accepted state wins after marker-cleanup power loss"
}

test_mount_failure_fallback()
{
    c="$TMP/mountfail"; setup_known_good "$c"; make_slot "$c/root" sound slotB 111
    printf 'slotB slotA 111\n' > "$c/root/state/sound/pending"
    FAKE_MOUNT_FAIL_MATCH=slotB.sqfs run_launcher "$c" >/dev/null
    assert_eq "$(cat "$c/run/nextgen-app-ref")" "slotA 110" "mount fallback"
    assert_exists "$c/root/state/sound/rollback" "mount rollback"
    pass "candidate mount failure falls back to accepted image"
}

test_corrupt_hash_fallback()
{
    c="$TMP/hashfail"; setup_known_good "$c"; make_slot "$c/root" sound slotB 111
    chmod 0644 "$c/root/app/sound/slotB.sqfs"; printf corrupt >> "$c/root/app/sound/slotB.sqfs"; chmod 0444 "$c/root/app/sound/slotB.sqfs"
    printf 'slotB slotA 111\n' > "$c/root/state/sound/pending"
    run_launcher "$c" >/dev/null
    assert_eq "$(cat "$c/run/nextgen-app-ref")" "slotA 110" "hash fallback"
    assert_exists "$c/root/state/sound/rollback" "hash rollback"
    pass "corrupt image hash is rejected before execution"
}

test_factory_repairs_empty_state()
{
    c="$TMP/factory"; make_fixture "$c"; make_factory "$c/root" sound 100
    run_launcher "$c" >/dev/null
    assert_eq "$(cat "$c/run/nextgen-app-ref")" "factory 100" "factory runtime"
    assert_eq "$(cat "$c/root/state/sound/accepted")" "factory 100" "factory accepted repair"
    assert_eq "$(cat "$c/root/state/sound/previous")" "factory 100" "factory previous repair"
    pass "empty persistent app state recovers from immutable factory"
}

test_manifest_image_disagreement_rejected()
{
    c="$TMP/mismatch"; setup_known_good "$c"
    p="$c/sdcard/public/update_V111.zip"; build_bundle "$p" 111 112
    run_installer "$c" "$p" >/dev/null 2>&1 && fail "manifest/image version mismatch accepted"
    assert_not_exists "$c/root/state/sound/pending" "mismatch pending"
    assert_eq "$(cat "$c/root/state/sound/accepted")" "slotA 110" "mismatch accepted"
    pass "installer validates mounted image against manifest"
}

test_equal_version_rejected()
{
    c="$TMP/equal"; setup_known_good "$c"
    p="$c/sdcard/public/update_V110.zip"; build_bundle "$p" 110
    run_installer "$c" "$p" >/dev/null 2>&1 && fail "equal version accepted"
    assert_not_exists "$c/root/state/sound/pending" "equal pending"
    pass "equal version image is rejected"
}

test_cleanup_waits_for_sd()
{
    c="$TMP/nosd"; setup_known_good "$c"; printf 'slotA 110\n' > "$c/run/nextgen-app-ref"
    p="$c/sdcard/public/update_V110.zip"; printf x > "$p"; printf '110 %s\n' "$p" > "$c/root/state/sound/cleanup"
    run_acceptor "$c" >/dev/null
    assert_exists "$c/root/state/sound/cleanup" "cleanup retained without SD"
    mount_sd "$c"; run_acceptor "$c" >/dev/null
    assert_not_exists "$p" "accepted package removed when SD returns"
    assert_not_exists "$c/root/state/sound/cleanup" "cleanup cleared when SD returns"
    pass "accepted cleanup waits for mounted SD"
}

test_cloud_rollback_requeue()
{
    c="$TMP/cloud"; setup_known_good "$c"; mount_sd "$c"
    p="$c/sdcard/temp/TempFirmware/NgSound_V111_deadbeef.zip"; printf x > "$p"
    printf 'applying:111\n' > "$c/sdcard/temp/TempFirmware/.status"
    printf '111 %s\n' "$p" > "$c/root/state/sound/cleanup"; printf 'rollback\n' > "$c/root/state/sound/rollback"
    run_acceptor "$c" >/dev/null
    assert_eq "$(cat "$c/sdcard/temp/TempFirmware/.status")" "ready:111" "cloud requeue"
    assert_not_exists "$c/root/state/sound/rollback" "rollback cleared"
    pass "cloud rollback restores ready status"
}

for t in \
    test_install_boot_accept \
    test_unaccepted_candidate_rolls_back \
    test_cleanup_before_pending_power_loss \
    test_previous_before_accepted_power_loss \
    test_accepted_before_marker_cleanup_power_loss \
    test_mount_failure_fallback \
    test_corrupt_hash_fallback \
    test_factory_repairs_empty_state \
    test_manifest_image_disagreement_rejected \
    test_equal_version_rejected \
    test_cleanup_waits_for_sd \
    test_cloud_rollback_requeue
do
    "$t"
done

echo "All $TESTS NextGen format-4 update state-machine tests passed"
