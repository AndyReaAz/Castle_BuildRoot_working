#!/bin/sh
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BOARD="$(CDPATH= cd -- "$HERE/.." && pwd)"
LAUNCHER="$BOARD/rootfs-overlay/root/startup.sh"
INSTALLER="$BOARD/nextgen-update-install"
ACCEPTOR="$BOARD/nextgen-update-accept"

for tool in awk cat chmod dirname md5sum mkdir mktemp mv python3 readlink rm sed sha256sum sync unzip; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "SKIP: missing host tool: $tool" >&2
        exit 77
    }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
TESTS=0

fail()
{
    echo "FAIL: $*" >&2
    exit 1
}

pass()
{
    TESTS=$((TESTS + 1))
    echo "PASS: $*"
}

assert_eq()
{
    actual="$1"
    expected="$2"
    message="$3"
    [ "$actual" = "$expected" ] ||
        fail "$message: expected '$expected', got '$actual'"
}

assert_exists()
{
    [ -e "$1" ] || fail "$2: missing $1"
}

assert_not_exists()
{
    [ ! -e "$1" ] || fail "$2: unexpected $1"
}

assert_link()
{
    actual="$(readlink "$1" 2>/dev/null || true)"
    assert_eq "$actual" "$2" "$3"
}

make_slot()
{
    root="$1"
    product="$2"
    slot="$3"
    version="$4"
    exit_code="${5:-0}"

    dir="$root/app/$product/$slot"
    mkdir -p "$dir/BaseHPD"
    cat > "$dir/NextGen" <<EOF
#!/bin/sh
echo "RUN $slot $version"
exit $exit_code
EOF
    chmod 0755 "$dir/NextGen"
    printf 'translations %s\n' "$version" > "$dir/Translations.csv"
    printf 'hpd %s\n' "$version" > "$dir/BaseHPD/hpdc.csv"
    cat > "$dir/bundle.info" <<EOF
format=3
product=$product
version=$version
EOF
}

make_fixture()
{
    case_dir="$1"
    active="$2"
    previous="$3"
    accepted_slot="$4"
    accepted_version="$5"

    root="$case_dir/root"
    sd="$case_dir/sdcard"
    run="$case_dir/run"
    product_file="$case_dir/nextgen-product"
    mounts="$case_dir/mounts"

    mkdir -p "$root/app/sound" "$root/state/sound" "$root/platform/share"         "$sd/public" "$sd/temp/TempFirmware" "$run"
    printf '%s\n' sound > "$product_file"
    : > "$mounts"
    ln -s "$active" "$root/app/sound/active"
    ln -s "$previous" "$root/app/sound/previous"
    printf '%s %s\n' "$accepted_slot" "$accepted_version" > "$root/state/sound/accepted"
    printf '%s\n' unsigned-development > "$root/platform/share/update-signing-policy"
}

mount_sd()
{
    sd="$1"
    mounts="$2"
    printf 'fake %s ext4 rw 0 0\n' "$sd" > "$mounts"
}

run_launcher()
{
    case_dir="$1"
    NEXTGEN_ROOT="$case_dir/root"     NEXTGEN_PRODUCT_FILE="$case_dir/nextgen-product"         /bin/sh "$LAUNCHER"
}

run_acceptor()
{
    case_dir="$1"
    NEXTGEN_ROOT="$case_dir/root"     NEXTGEN_SDCARD_ROOT="$case_dir/sdcard"     NEXTGEN_MOUNTS_FILE="$case_dir/mounts"         /bin/sh "$ACCEPTOR" sound
}

run_installer()
{
    case_dir="$1"
    package="$2"
    NEXTGEN_ROOT="$case_dir/root"     NEXTGEN_SDCARD_ROOT="$case_dir/sdcard"     NEXTGEN_RUN_ROOT="$case_dir/run"         /bin/sh "$INSTALLER" sound "$package"
}

build_bundle()
{
    package="$1"
    version="$2"

    python3 - "$package" "$version" <<'PY'
from __future__ import annotations
import hashlib
from pathlib import Path
import stat
import sys
import zipfile

package = Path(sys.argv[1])
version = int(sys.argv[2])
package.parent.mkdir(parents=True, exist_ok=True)

payloads = [
    ("NextGen", "NextGen", 0o755,
     f"#!/bin/sh\necho RUN candidate {version}\nexit 0\n".encode()),
    ("Translations", "Translations.csv", 0o644,
     f"translations {version}\n".encode()),
    ("hpdc", "BaseHPD/hpdc.csv", 0o644,
     f"hpd {version}\n".encode()),
]

members = []
manifest = [f"NEXTGEN_APP_BUNDLE 3 sound {version}"]
for label, target, mode, data in payloads:
    md5 = hashlib.md5(data).hexdigest()
    suffix = ".csv" if label != "NextGen" else ""
    name = f"{label}_{md5}{suffix}"
    sha = hashlib.sha256(data).hexdigest()
    manifest.append(f"{name} {target} {mode:04o} {sha}")
    members.append((name, mode, data))

manifest_data = ("\n".join(manifest) + "\n").encode("ascii")
manifest_name = (
    f"manifest_V{version}_{hashlib.md5(manifest_data).hexdigest()}.txt"
)

def info(name: str, mode: int) -> zipfile.ZipInfo:
    z = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    z.create_system = 3
    z.external_attr = (stat.S_IFREG | mode) << 16
    z.compress_type = zipfile.ZIP_DEFLATED
    return z

with zipfile.ZipFile(package, "w", allowZip64=False) as zf:
    for name, mode, data in members:
        zf.writestr(info(name, mode), data)
    zf.writestr(info(manifest_name, 0o644), manifest_data)
PY
}

test_install_boot_accept()
{
    case_dir="$TMP/install-boot-accept"
    make_fixture "$case_dir" slotA slotA slotA 110
    make_slot "$case_dir/root" sound slotA 110
    make_slot "$case_dir/root" sound factory 110
    mount_sd "$case_dir/sdcard" "$case_dir/mounts"

    package="$case_dir/sdcard/public/update_V111.zip"
    build_bundle "$package" 111

    run_installer "$case_dir" "$package" >/dev/null

    assert_link "$case_dir/root/app/sound/active" slotA "installer must not switch active"
    assert_link "$case_dir/root/app/sound/previous" slotA "installer previous"
    assert_eq "$(cat "$case_dir/root/state/sound/pending")" "slotB slotA 111" "pending record"
    assert_eq "$(sed -n 's/^version=//p' "$case_dir/root/app/sound/slotB/bundle.info")" 111 "staged version"
    assert_eq "$(cat "$case_dir/root/state/sound/accepted")" "slotA 110" "accepted remains old"

    run_launcher "$case_dir" >/dev/null
    assert_link "$case_dir/root/app/sound/active" slotB "first candidate boot switches active"
    assert_link "$case_dir/root/app/sound/previous" slotA "known-good previous retained"
    assert_eq "$(cat "$case_dir/root/state/sound/booting")" slotB "booting marker"

    run_acceptor "$case_dir" >/dev/null
    assert_eq "$(cat "$case_dir/root/state/sound/accepted")" "slotB 111" "candidate accepted"
    assert_not_exists "$case_dir/root/state/sound/pending" "pending cleared"
    assert_not_exists "$case_dir/root/state/sound/booting" "booting cleared"
    assert_not_exists "$case_dir/root/state/sound/cleanup" "cleanup cleared"
    assert_not_exists "$package" "accepted USB package removed"
    pass "install -> first boot -> acceptance -> USB cleanup"
}

test_power_loss_after_active_switch()
{
    case_dir="$TMP/active-switch"
    make_fixture "$case_dir" slotB slotA slotA 110
    make_slot "$case_dir/root" sound slotA 110
    make_slot "$case_dir/root" sound slotB 111
    make_slot "$case_dir/root" sound factory 110
    printf '%s\n' "slotB slotA 111" > "$case_dir/root/state/sound/pending"

    run_launcher "$case_dir" >/dev/null

    assert_link "$case_dir/root/app/sound/active" slotB "resumed candidate active"
    assert_link "$case_dir/root/app/sound/previous" slotA "resumed previous"
    assert_eq "$(cat "$case_dir/root/state/sound/booting")" slotB "booting recreated"
    assert_not_exists "$case_dir/root/state/sound/rollback" "must not prematurely roll back"
    pass "power loss after active switch but before booting marker"
}

test_failed_candidate_rollback_usb_retained()
{
    case_dir="$TMP/rollback-usb"
    make_fixture "$case_dir" slotB slotA slotA 110
    make_slot "$case_dir/root" sound slotA 110
    make_slot "$case_dir/root" sound slotB 112
    make_slot "$case_dir/root" sound factory 110
    printf '%s\n' "slotB slotA 112" > "$case_dir/root/state/sound/pending"
    printf '%s\n' slotB > "$case_dir/root/state/sound/booting"

    package="$case_dir/sdcard/public/update_V112.zip"
    printf 'failed candidate package\n' > "$package"
    printf '112 %s\n' "$package" > "$case_dir/root/state/sound/cleanup"
    mount_sd "$case_dir/sdcard" "$case_dir/mounts"

    run_launcher "$case_dir" >/dev/null

    assert_link "$case_dir/root/app/sound/active" slotA "rollback active"
    assert_link "$case_dir/root/app/sound/previous" slotA "rollback previous"
    assert_exists "$case_dir/root/state/sound/rollback" "rollback marker"
    assert_not_exists "$case_dir/root/state/sound/pending" "rollback pending cleared"
    assert_not_exists "$case_dir/root/state/sound/booting" "rollback booting cleared"

    run_acceptor "$case_dir" >/dev/null

    assert_exists "$package" "rolled-back USB package retained"
    assert_not_exists "$case_dir/root/state/sound/rollback" "rollback cleanup marker cleared"
    assert_not_exists "$case_dir/root/state/sound/cleanup" "rollback cleanup record cleared"
    assert_eq "$(cat "$case_dir/root/state/sound/accepted")" "slotA 110" "old acceptance preserved"
    pass "failed candidate rolls back and retains USB package"
}

test_durable_acceptance_survives_cleanup_power_loss()
{
    case_dir="$TMP/durable-accept"
    make_fixture "$case_dir" slotB slotA slotB 111
    make_slot "$case_dir/root" sound slotA 110
    make_slot "$case_dir/root" sound slotB 111
    make_slot "$case_dir/root" sound factory 110
    printf '%s\n' "slotB slotA 111" > "$case_dir/root/state/sound/pending"
    printf '%s\n' slotB > "$case_dir/root/state/sound/booting"

    package="$case_dir/sdcard/public/update_V111.zip"
    printf 'accepted package\n' > "$package"
    printf '111 %s\n' "$package" > "$case_dir/root/state/sound/cleanup"
    mount_sd "$case_dir/sdcard" "$case_dir/mounts"

    run_launcher "$case_dir" >/dev/null

    assert_link "$case_dir/root/app/sound/active" slotB "accepted active preserved"
    assert_eq "$(cat "$case_dir/root/state/sound/accepted")" "slotB 111" "durable acceptance preserved"
    assert_not_exists "$case_dir/root/state/sound/pending" "accepted pending finalised"
    assert_not_exists "$case_dir/root/state/sound/booting" "accepted booting finalised"
    assert_exists "$package" "launcher must not own package cleanup"

    run_acceptor "$case_dir" >/dev/null
    assert_not_exists "$package" "acceptor retries accepted package cleanup"
    assert_not_exists "$case_dir/root/state/sound/cleanup" "accepted cleanup record cleared"
    pass "durable acceptance is not rolled back after cleanup power loss"
}

test_cleanup_waits_for_sd_mount()
{
    case_dir="$TMP/no-sd"
    make_fixture "$case_dir" slotB slotB slotB 111
    make_slot "$case_dir/root" sound slotB 111

    package="$case_dir/sdcard/public/update_V111.zip"
    printf 'accepted package\n' > "$package"
    printf '111 %s\n' "$package" > "$case_dir/root/state/sound/cleanup"

    run_acceptor "$case_dir" >/dev/null
    assert_exists "$package" "package retained while SD not mounted"
    assert_exists "$case_dir/root/state/sound/cleanup" "cleanup retained while SD not mounted"

    mount_sd "$case_dir/sdcard" "$case_dir/mounts"
    run_acceptor "$case_dir" >/dev/null
    assert_not_exists "$package" "package removed after SD returns"
    assert_not_exists "$case_dir/root/state/sound/cleanup" "cleanup cleared after SD returns"
    pass "accepted cleanup waits for mounted SD"
}

test_cloud_rollback_requeues_package()
{
    case_dir="$TMP/cloud-rollback"
    make_fixture "$case_dir" slotA slotA slotA 111
    make_slot "$case_dir/root" sound slotA 111

    package="$case_dir/sdcard/temp/TempFirmware/NgSound_V112_deadbeef.zip"
    printf 'cloud package\n' > "$package"
    printf 'applying:112\n' > "$case_dir/sdcard/temp/TempFirmware/.status"
    printf '112 %s\n' "$package" > "$case_dir/root/state/sound/cleanup"
    printf 'rollback\n' > "$case_dir/root/state/sound/rollback"
    mount_sd "$case_dir/sdcard" "$case_dir/mounts"

    run_acceptor "$case_dir" >/dev/null

    assert_exists "$package" "cloud rollback package retained"
    assert_eq "$(cat "$case_dir/sdcard/temp/TempFirmware/.status")" "ready:112" "cloud package requeued"
    assert_not_exists "$case_dir/root/state/sound/cleanup" "cloud cleanup cleared"
    assert_not_exists "$case_dir/root/state/sound/rollback" "cloud rollback marker cleared"
    pass "cloud rollback restores ready status"
}

test_malformed_pending_rolls_back()
{
    case_dir="$TMP/malformed-pending"
    make_fixture "$case_dir" slotB slotA slotA 110
    make_slot "$case_dir/root" sound slotA 110
    make_slot "$case_dir/root" sound slotB 111
    make_slot "$case_dir/root" sound factory 110
    printf '%s\n' "slotB slotA 999" > "$case_dir/root/state/sound/pending"

    run_launcher "$case_dir" >/dev/null

    assert_link "$case_dir/root/app/sound/active" slotA "malformed pending recovery active"
    assert_link "$case_dir/root/app/sound/previous" slotA "malformed pending recovery previous"
    assert_exists "$case_dir/root/state/sound/rollback" "malformed pending rollback marker"
    assert_not_exists "$case_dir/root/state/sound/pending" "malformed pending removed"
    pass "malformed pending transaction recovers known-good slot"
}

test_equal_version_rejected()
{
    case_dir="$TMP/equal-version"
    make_fixture "$case_dir" slotA slotA slotA 110
    make_slot "$case_dir/root" sound slotA 110
    make_slot "$case_dir/root" sound factory 110

    package="$case_dir/sdcard/public/update_V110.zip"
    build_bundle "$package" 110

    if run_installer "$case_dir" "$package" >/dev/null 2>&1; then
        fail "equal-version installer unexpectedly succeeded"
    fi

    assert_link "$case_dir/root/app/sound/active" slotA "equal-version active unchanged"
    assert_eq "$(cat "$case_dir/root/state/sound/accepted")" "slotA 110" "equal-version acceptance unchanged"
    assert_not_exists "$case_dir/root/state/sound/pending" "equal-version pending absent"
    pass "equal-version application bundle rejected"
}

test_install_boot_accept
test_power_loss_after_active_switch
test_failed_candidate_rollback_usb_retained
test_durable_acceptance_survives_cleanup_power_loss
test_cleanup_waits_for_sd_mount
test_cloud_rollback_requeues_package
test_malformed_pending_rolls_back
test_equal_version_rejected

echo "All $TESTS NextGen update state-machine tests passed"
