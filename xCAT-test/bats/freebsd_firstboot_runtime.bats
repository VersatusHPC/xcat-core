#!/usr/bin/env bats
#
# The installer writes a postscript that installs the xcatfirstboot rc.d service. The service
# reports "booted" to the controller from a detached worker and keeps its pending marker
# until a matching acknowledgment arrives. daemon, nc, sleep and the rc framework are stubs.

bats_require_minimum_version 1.5.0
load 'helpers/freebsd'

setup()
{
    DIR="$(freebsd_installer_dir)"
    command -v flock >/dev/null && command -v setsid >/dev/null || skip 'flock and setsid are required'
    PIDS=()
}

teardown()
{
    local pid
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    [ -n "${ROOT:-}" ] && [ -f "$ROOT/var/run/xcatfirstboot.pid" ] && kill "$(cat "$ROOT/var/run/xcatfirstboot.pid")" 2>/dev/null
    return 0
}

# fixture: a root with the stubs and the production postscript installed into it. Sets ROOT.
fixture()
{
    ROOT="$(mktemp -d "$BATS_TEST_TMPDIR/root.XXXXXX")"
    mkdir -p "$ROOT"/{bin,etc/ssh,usr/sbin,var/run,root}
    printf 'UsePAM yes\n' >"$ROOT/etc/ssh/sshd_config"
    cat >"$ROOT/etc/rc.subr" <<'RC'
load_rc_config()
{
    xcatfirstboot_enable=$(cat "$FIXTURE_DIR/enabled")
}
run_rc_command()
{
    case "$1" in
        start) [ "$xcatfirstboot_enable" = YES ] || return 0; "$start_cmd" ;;
        report) "$report_cmd" ;;
        *) return 1 ;;
    esac
}
RC
    printf '#!/bin/sh\nexit 0\n' | freebsd_stub "$ROOT/bin/pw"
    printf '#!/bin/sh\nexit 0\n' | freebsd_stub "$ROOT/bin/fsync"
    freebsd_stub "$ROOT/bin/sysrc" <<'STUB'
#!/bin/sh
for value in "$@"; do
    case "$value" in xcatfirstboot_enable=*) printf '%s\n' "${value#*=}" > "$FIXTURE_DIR/enabled" ;; esac
done
STUB
    freebsd_stub "$ROOT/bin/date" <<'STUB'
#!/bin/sh
if [ -f "$FIXTURE_DIR/clock" ]; then cat "$FIXTURE_DIR/clock"; else printf '0\n'; fi
STUB
    # A virtual clock: each sleep advances it and returns at once.
    freebsd_stub "$ROOT/bin/sleep" <<'STUB'
#!/bin/sh
now=$(cat "$FIXTURE_DIR/clock" 2>/dev/null || echo 0)
printf '%s\n' "$((now + $1))" > "$FIXTURE_DIR/clock"
/bin/sleep 0.02
STUB
    freebsd_stub "$ROOT/bin/nc" <<'STUB'
#!/bin/sh
read -r protocol generation attempt phase
printf '%s %s %s %s\n' "$protocol" "$generation" "$attempt" "$phase" >> "$FIXTURE_DIR/requests"
printf 'ready\n'
if [ -f "$FIXTURE_DIR/ack" ]; then
    [ "$(cat "$FIXTURE_DIR/ack")" = matching ] || generation=cccccccccccccccccccccccccccccccc
    printf 'freebsd-install-v1 %s %s ok\n' "$generation" "$phase"
fi
STUB
    # daemon -f [-S] -p <pidfile> <command>: one worker per pidfile, detached.
    freebsd_stub "$ROOT/usr/sbin/daemon" <<'STUB'
#!/bin/sh
[ -f "$FIXTURE_DIR/deny-daemon" ] && exit 73
[ "$1" = -f ] || exit 64; shift
out=/dev/null
if [ "$1" = -S ]; then out=$FIXTURE_DIR/syslog; shift; fi
[ "$1" = -p ] || exit 64
pidfile=$2; shift 2
exec 9>>"$pidfile"
flock -n 9 || exit 3
setsid sh -c 'pidfile=$1; shift
    printf "%s\n" "$$" > "$pidfile"
    printf "worker\n" >> "$FIXTURE_DIR/workers"
    "$@"; status=$?
    printf "%s\n" "$status" > "$FIXTURE_DIR/worker-exit"
    rm -f "$pidfile"; exit "$status"' sh "$pidfile" "$@" </dev/null >"$out" 2>&1 3>&- &
exit 0
STUB
    # The installer and its postscript both read the node settings.
    local env=(FIXTURE_DIR="$ROOT" PATH="$ROOT/bin:$PATH" XCAT_WORK="$ROOT/work" XCAT_FILESYSTEM=zfs
        XCAT_TARGET_DISK=vtbd0 XCAT_TARGET_DISK_IDENT=OS0 XCAT_SWAP_SIZE=0
        XCAT_MASTER=127.0.0.1 XCAT_PORT=3002 XCAT_GENERATION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        XCAT_ATTEMPT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb XCAT_HOSTNAME=node01.example.test
        XCAT_PROVISIONING_IF=em0 XCAT_IPV4=192.0.2.20 XCAT_NETMASK=255.255.255.0 XCAT_GATEWAY=
        XCAT_NAMESERVERS= XCAT_AUTHORIZED_KEY_BASE64="$(printf 'fixture public key' | base64 -w0)")
    env "${env[@]}" \
        sh -c '. "$1"; xcat_write_installer "$2" "$1"' sh "$DIR/xcat-install-lib.sh" \
        "$DIR/installerconfig.tmpl" >"$ROOT/installer"
    # The second script of the installer is the postscript. Its absolute paths move into ROOT.
    perl -e 'local $/; open(my $f, "<", $ARGV[0]) or die "$ARGV[0]: $!\n"; my $i = <$f>;
        my (undef, $p) = split(/(?=^#!)/m, $i, 2); defined $p or die "missing generated postscript\n";
        $p =~ s{(?<![A-Za-z0-9_.+-])/(usr/local|usr/sbin/daemon|etc|root|var)(?=/|[\s"\x27])}{$ARGV[1]/$1}g; print $p' \
        "$ROOT/installer" "$ROOT" >"$ROOT/postscript"
    env "${env[@]}" sh "$ROOT/postscript" 3>&-
    [ "$(cat "$ROOT/etc/xcat/os-disks")" = 'vtbd0@OS0' ]
}

# start: the rc.d service in the background. Sets PID.
start()
{
    FIXTURE_DIR="$ROOT" PATH="$ROOT/bin:$PATH" sh "$ROOT/usr/local/etc/rc.d/xcatfirstboot" start \
        >"$ROOT/start.log" 2>&1 3>&- &
    PID=$!
    PIDS+=("$PID")
}

# wait_for <seconds> <command...>
wait_for()
{
    local deadline=$((SECONDS + $1)); shift
    until "$@"; do [ "$SECONDS" -lt "$deadline" ] || return 1; /bin/sleep 0.05; done
}

# exit_of <pid> <seconds>: sets RC to the exit status once the process ends. Not called in a
# command substitution: only this shell can wait for its own child.
exit_of()
{
    RC=
    wait_for "$2" eval "! kill -0 $1 2>/dev/null" || return 1
    RC=0; wait "$1" || RC=$?
}

@test "the postscript records the concrete OS disk identity" {
    fixture
}

@test "only a matching acknowledgment completes the pending marker" {
    fixture
    pending="$(cat "$ROOT/var/db/xcat/firstboot")"
    start; first=$PID
    exit_of "$first" 2; [ "$RC" = 0 ]
    wait_for 2 test -s "$ROOT/requests"
    [ "$(cat "$ROOT/var/db/xcat/firstboot")" = "$pending" ]
    [ ! -e "$ROOT/var/db/xcat/firstboot.done" ]
    printf 'wrong-generation\n' >"$ROOT/ack"
    /bin/sleep 0.15
    [ ! -e "$ROOT/var/db/xcat/firstboot.done" ]
    start
    exit_of "$PID" 2
    [ -n "$RC" ] && [ "$RC" != 0 ]
    [ "$(cat "$ROOT/workers")" = worker ]
    printf 'matching\n' >"$ROOT/ack"
    wait_for 3 test -e "$ROOT/var/db/xcat/firstboot.done"
    [ "$(cat "$ROOT/var/db/xcat/firstboot.done")" = "$pending" ]
    [ ! -e "$ROOT/var/db/xcat/firstboot" ]
    wait_for 2 grep -qx NO "$ROOT/enabled"
    wait_for 2 test ! -e "$ROOT/var/run/xcatfirstboot.pid"
}

@test "an unavailable controller exhausts the fifteen-minute retry policy" {
    fixture
    start
    exit_of "$PID" 2; [ "$RC" = 0 ]
    wait_for 15 test -f "$ROOT/worker-exit"
    [ "$(cat "$ROOT/worker-exit")" = 1 ]
    grep -q 'Controller did not acknowledge booted' "$ROOT/syslog"
    [ "$(cat "$ROOT/clock")" = 900 ]
    [ -e "$ROOT/var/db/xcat/firstboot" ] && [ ! -e "$ROOT/var/db/xcat/firstboot.done" ]
    [ "$(cat "$ROOT/enabled")" = YES ]
}

@test "a daemon launch failure propagates and keeps the marker" {
    fixture
    : >"$ROOT/deny-daemon"
    start
    exit_of "$PID" 2; [ "$RC" = 73 ]
    [ -e "$ROOT/var/db/xcat/firstboot" ] && [ ! -e "$ROOT/requests" ]
    rm "$ROOT/var/db/xcat/firstboot"
    start
    exit_of "$PID" 2; [ "$RC" = 0 ]
}
