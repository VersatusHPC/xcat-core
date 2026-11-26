#!/usr/bin/env bats
#
# Run the Genesis restart script, which renews the DHCP leases of every client that doxcat
# started. The clients are stubs that record their own argv.

load 'helpers/shell_source'

V4LEASES=/var/lib/dhclient/dhclient.leases
V6LEASES=/var/lib/dhclient/dhclient6.leases

setup()
{
    [ "$(uname -s)" = Linux ] || skip 'the Genesis restart test needs a Linux sandbox'
    bwrap=$(PATH=/usr/bin:/bin type -P bwrap) || {
        echo 'Install bubblewrap to run the Genesis restart test' >&2
        return 1
    }
    fixture="$BATS_TEST_TMPDIR/fixture"
    mkdir -p "$fixture"/{bin,sbin,var/run,var/lib/dhclient}
    cat >"$fixture/bin/dhclient" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>/fx/dhcp
SH
    cat >"$fixture/bin/ip" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>/fx/ip
case "$*" in
    '-oneline link show') printf '2: eth0: <UP> mtu 1500\\    link/ether 52:54:00:00:00:01\n' ;;
    '-4 -oneline addr show eth0') printf '2: eth0    inet 192.0.2.20/24 scope global eth0\n' ;;
esac
SH
    printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/sleep"
    # restart starts /sbin/rsyslogd by its full path.
    printf '#!/bin/sh\nprintf "rsyslogd 8.2312.0\\n"\n' >"$fixture/sbin/rsyslogd"
    chmod +x "$fixture/bin/"* "$fixture/sbin/"*
    : >"$fixture/dhcp"
    : >"$fixture/ip"
    : >"$fixture/restart"
}

# Run restart as Genesis does, from /, with /restart written by minixcatd.
run_restart()
{
    local sandbox=("$bwrap" --unshare-all --die-with-parent --new-session
        --ro-bind /usr /usr --ro-bind /etc /etc --symlink usr/bin /bin --symlink usr/sbin /sbin
        --symlink usr/lib /lib --proc /proc --dev /dev --tmpfs /tmp
        --bind "$fixture" /fx --bind "$fixture/var" /var --ro-bind "$fixture/sbin" /usr/sbin
        --ro-bind "$fixture/restart" /restart
        --ro-bind "$(repo_path xCAT-genesis-scripts/usr/bin/restart)" /run/restart --chdir /
        --setenv PATH /fx/bin:/usr/bin)
    [ ! -e /usr/lib64 ] || sandbox+=(--symlink usr/lib64 /lib64)
    run timeout 60 "${sandbox[@]}" /bin/bash /run/restart </dev/null
    [ "$status" -eq 0 ] || { printf 'restart exited %s\n%s\n' "$status" "$output" >&2; return 1; }
}

client_ran()
{
    local nic
    for nic in "$@"; do
        : >"$fixture/var/run/dhclient.$nic.pid"
        : >"$fixture/var/run/dhclient6.$nic.pid"
    done
}

assert_dhcp()
{
    printf '%s\n' "$@" | sed '/^$/d' >"$fixture/expected"
    run diff -u "$fixture/expected" "$fixture/dhcp"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "restart renews each lease in the lease file that doxcat gives dhclient" {
    client_ran eth0
    run_restart
    assert_dhcp \
        "-r -1 -cf /etc/dhclient.conf -pf /var/run/dhclient.eth0.pid -lf $V4LEASES eth0" \
        "-cf /etc/dhclient.conf -nw -pf /var/run/dhclient.eth0.pid -lf $V4LEASES eth0" \
        "-6 -r -1 -pf /var/run/dhclient6.eth0.pid -lf $V6LEASES eth0" \
        "-6 -pf /var/run/dhclient6.eth0.pid -nw -lf $V6LEASES eth0"
}

@test "restart releases a nic outside discoverynics in the same lease file" {
    client_ran eth0 eth1
    printf 'restart eth0\n' >"$fixture/restart"
    run_restart
    grep -Fqx -- "-r -1 -cf /etc/dhclient.conf -pf /var/run/dhclient.eth1.pid -lf $V4LEASES eth1" \
        "$fixture/dhcp" || { cat "$fixture/dhcp" >&2; return 1; }
    grep -Fqx -- 'link set eth1 down' "$fixture/ip"
}

@test "restart starts no client for a family that has no client running" {
    : >"$fixture/var/run/dhclient.eth0.pid"
    run_restart
    assert_dhcp \
        "-r -1 -cf /etc/dhclient.conf -pf /var/run/dhclient.eth0.pid -lf $V4LEASES eth0" \
        "-cf /etc/dhclient.conf -nw -pf /var/run/dhclient.eth0.pid -lf $V4LEASES eth0"
}
