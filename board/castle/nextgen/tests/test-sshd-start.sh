#!/bin/sh
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SSHD_SCRIPT="$HERE/../rootfs-overlay/etc/init.d/sshd"

fail()
{
    echo "FAIL: $*" >&2
    exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

RUNTIME="$TMP/run"
KEY_DIR="$TMP/keys"
PIDFILE="$TMP/sshd.pid"
LOG="$TMP/actions.log"
KEYGEN="$TMP/ssh-keygen"
DAEMON="$TMP/sshd"
START_STOP="$TMP/start-stop-daemon"

mkdir -p "$RUNTIME" "$KEY_DIR"
: > "$LOG"

cat > "$KEYGEN" <<'EOF'
#!/bin/sh
set -eu
file=
prev=
for arg in "$@"; do
    if [ "$prev" = -f ]; then
        file="$arg"
        break
    fi
    prev="$arg"
done

if [ "${1:-}" = -y ]; then
    [ -n "$file" ] && [ -f "$file" ] && [ "$(cat "$file")" = valid-key ]
    exit
fi

echo keygen >> "$TEST_LOG"
[ -n "$file" ] || exit 2
mkdir -p "$(dirname "$file")"
printf '%s\n' valid-key > "$file"
printf '%s\n' valid-pub > "$file.pub"
sleep "${TEST_KEYGEN_DELAY:-0}"
exit 0
EOF

cat > "$DAEMON" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$START_STOP" <<'EOF'
#!/bin/sh
case "${1:-}" in
    --start)
        echo daemon-start >> "$TEST_LOG"
        : > "$TEST_PIDFILE"
        exit 0
        ;;
    --stop)
        echo daemon-stop >> "$TEST_LOG"
        rm -f "$TEST_PIDFILE"
        exit 0
        ;;
esac
echo "unexpected start-stop-daemon arguments: $*" >&2
exit 2
EOF

chmod +x "$KEYGEN" "$DAEMON" "$START_STOP"

run_sshd()
{
    delay="$1"
    shift
    TEST_LOG="$LOG" \
    TEST_PIDFILE="$PIDFILE" \
    TEST_KEYGEN_DELAY="$delay" \
    NEXTGEN_STORAGE_SCHEMA=ro-persist-v1 \
    NEXTGEN_SSH_KEY_DIR="$KEY_DIR" \
    NEXTGEN_SSHD_DAEMON="$DAEMON" \
    NEXTGEN_SSH_KEYGEN="$KEYGEN" \
    NEXTGEN_START_STOP_DAEMON="$START_STOP" \
    NEXTGEN_SSH_PIDFILE="$PIDFILE" \
    NEXTGEN_SSH_RUNTIME_DIR="$RUNTIME" \
        /bin/sh "$SSHD_SCRIPT" "$@"
}

wait_for_lock()
{
    count=0
    while [ ! -d "$RUNTIME/nextgen-sshd-start.lock" ] && [ "$count" -lt 100 ]; do
        sleep 0.02
        count=$((count + 1))
    done
    [ -d "$RUNTIME/nextgen-sshd-start.lock" ] ||
        fail "SSH start lock was not acquired"
}

count_action()
{
    grep -c "^$1$" "$LOG" 2>/dev/null || true
}

# A health check can arrive while first-boot key generation is still running.
# It must observe the active start lock and return without launching a second
# key generator or daemon start.
: > "$LOG"
rm -f "$PIDFILE"
rm -rf "$KEY_DIR"; mkdir -p "$KEY_DIR"
rm -rf "$RUNTIME/nextgen-sshd-start.lock"
rm -f "$RUNTIME/nextgen-sshd-stop.pending"

run_sshd 1 start >"$TMP/start-1.out" 2>&1 &
first_pid=$!
wait_for_lock
run_sshd 0 start >"$TMP/start-2.out" 2>&1
wait "$first_pid"

[ "$(count_action keygen)" -eq 2 ] ||
    fail "concurrent starts ran an unexpected number of key generations"
[ "$(count_action daemon-start)" -eq 1 ] ||
    fail "concurrent starts launched sshd an unexpected number of times"
grep -q '^SSH start already in progress$' "$TMP/start-2.out" ||
    fail "second start did not report the in-progress start"
echo "PASS: concurrent SSH health-check start is serialized"

# Engineering mode can be disabled while the first-use key generator is still
# running. The stop marker must win that race so the original background start
# cannot expose sshd after engineering mode has been disabled.
: > "$LOG"
rm -f "$PIDFILE"
rm -rf "$RUNTIME/nextgen-sshd-start.lock"
rm -f "$RUNTIME/nextgen-sshd-stop.pending"

run_sshd 1 start >"$TMP/start-cancel.out" 2>&1 &
first_pid=$!
wait_for_lock
run_sshd 0 stop >"$TMP/stop.out" 2>&1
wait "$first_pid"

[ "$(count_action keygen)" -eq 2 ] ||
    fail "cancel test did not generate exactly one host-key pair"
[ "$(count_action daemon-start)" -eq 0 ] ||
    fail "sshd started after engineering-mode cancellation"
grep -q '^SSH start cancelled$' "$TMP/start-cancel.out" ||
    fail "background start did not observe cancellation"
echo "PASS: engineering disable cancels an in-progress first-use SSH start"

# A stale lock from a dead process must not permanently suppress SSH recovery.
: > "$LOG"
rm -f "$PIDFILE"
rm -rf "$RUNTIME/nextgen-sshd-start.lock"
mkdir -p "$RUNTIME/nextgen-sshd-start.lock"
echo 999999 > "$RUNTIME/nextgen-sshd-start.lock/pid"
rm -f "$RUNTIME/nextgen-sshd-stop.pending"

run_sshd 0 start >"$TMP/start-stale.out" 2>&1

[ "$(count_action keygen)" -eq 2 ] ||
    fail "stale lock prevented host-key generation"
[ "$(count_action daemon-start)" -eq 1 ] ||
    fail "stale lock prevented sshd start"
echo "PASS: stale SSH start lock is recovered"

# A non-empty but corrupt persisted private key must be replaced rather than
# leaving engineering SSH permanently unusable after a power loss.
: > "$LOG"
rm -f "$PIDFILE"
rm -rf "$RUNTIME/nextgen-sshd-start.lock"
rm -f "$RUNTIME/nextgen-sshd-stop.pending"
printf '%s\n' corrupt-key > "$KEY_DIR/ssh_host_ed25519_key"

run_sshd 0 start >"$TMP/start-corrupt.out" 2>&1

[ "$(count_action keygen)" -eq 1 ] ||
    fail "corrupt key did not trigger exactly one regeneration"
[ "$(cat "$KEY_DIR/ssh_host_ed25519_key")" = valid-key ] ||
    fail "corrupt ed25519 key was not replaced"
[ "$(count_action daemon-start)" -eq 1 ] ||
    fail "sshd did not start after corrupt key recovery"
echo "PASS: corrupt persistent SSH key is regenerated"

echo "All engineering SSH start tests passed"
