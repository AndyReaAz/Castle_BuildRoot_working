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
PIDFILE="$TMP/sshd.pid"
LOG="$TMP/actions.log"
KEYGEN="$TMP/ssh-keygen"
DAEMON="$TMP/sshd"
START_STOP="$TMP/start-stop-daemon"

mkdir -p "$RUNTIME"
: > "$LOG"

cat > "$KEYGEN" <<'EOF'
#!/bin/sh
echo keygen >> "$TEST_LOG"
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
rm -rf "$RUNTIME/nextgen-sshd-start.lock"
rm -f "$RUNTIME/nextgen-sshd-stop.pending"

run_sshd 1 start >"$TMP/start-1.out" 2>&1 &
first_pid=$!
wait_for_lock
run_sshd 0 start >"$TMP/start-2.out" 2>&1
wait "$first_pid"

[ "$(count_action keygen)" -eq 1 ] ||
    fail "concurrent starts ran key generation more than once"
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

[ "$(count_action keygen)" -eq 1 ] ||
    fail "cancel test did not run exactly one key generation"
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

[ "$(count_action keygen)" -eq 1 ] ||
    fail "stale lock prevented key generation"
[ "$(count_action daemon-start)" -eq 1 ] ||
    fail "stale lock prevented sshd start"
echo "PASS: stale SSH start lock is recovered"

echo "All engineering SSH start tests passed"
