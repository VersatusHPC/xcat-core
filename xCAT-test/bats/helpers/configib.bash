#!/usr/bin/env bash
#
# Run xCAT/postscripts/configib against a scratch root. XCAT_CONFIGIB_ROOT moves every /etc and
# /sys path of the script into $ROOT, and the commands that change a node are stubs in $BIN that
# append "<command> <arguments>" to $EVENTS.
#
# The nmcli stub keeps one file per connection in $ROOT/nmcli. "con show <name>" fails for a
# connection that has no file, as nmcli does.

load 'helpers/shell_source'

setup_configib()
{
    CONFIGIB="$(require_repo_file 'xCAT/postscripts/configib')"
    ROOT="${BATS_TEST_TMPDIR}/root"
    BIN="${BATS_TEST_TMPDIR}/bin"
    EVENTS="${BATS_TEST_TMPDIR}/events"
    mkdir -p "$ROOT/etc/sysconfig/network-scripts" "$ROOT/nmcli" "$ROOT/sys/class/net" "$BIN"
    : >"$EVENTS"
    : >"$ROOT/etc/sysctl.conf"

    local command
    for command in logger sysctl modprobe netplan networkctl ifup ifdown ip sleep; do
        printf '#!/bin/sh\necho "%s $*" >>"$EVENTS"\n' "$command" >"$BIN/$command"
    done
    # "systemctl is-active" answers inactive unless the test sets SYSTEMCTL_ACTIVE_RC=0.
    cat >"$BIN/systemctl" <<'SH'
#!/bin/sh
echo "systemctl $*" >>"$EVENTS"
[ "$1" = is-active ] && exit "${SYSTEMCTL_ACTIVE_RC:-3}"
exit 0
SH
    cat >"$BIN/nmcli" <<'SH'
#!/bin/sh
echo "nmcli $*" >>"$EVENTS"
case "$*" in
    "--field connection.id con show "*) [ -e "$XCAT_CONFIGIB_ROOT/nmcli/$5" ] ;;
    "con add "*)
        while [ $# -gt 0 ]; do
            [ "$1" = con-name ] && : >"$XCAT_CONFIGIB_ROOT/nmcli/$2"
            shift
        done ;;
    "con up "*) exit "${NMCLI_UP_RC:-0}" ;;
esac
SH
    chmod 0755 "$BIN"/*
}

# The release files that configib reads to tell the distribution.
el_root()
{
    printf 'AlmaLinux release 10.0 (Purple Lion)\n' >"$ROOT/etc/redhat-release"
}

ubuntu_root()
{
    printf 'NAME="Ubuntu"\nVERSION_ID="24.04"\n' >"$ROOT/etc/os-release"
}

# An IB device that the kernel created, as configib sees it in /sys.
ib_device()
{
    mkdir -p "$ROOT/sys/class/net/$1"
}

# One NETWORKS_LINE value: <netname> <net> <mask>.
ib_network()
{
    printf 'netname=%s||net=%s||mask=%s||mgtifname=||gateway=||dhcpserver=||tftpserver=||nameservers=||ntpservers=||logservers=||dynamicrange=||staticrange=||staticrangeincrement=||nodehostname=||ddnsdomain=||vlanid=||domain=||mtu=||disable=||comments=' \
        "$1" "$2" "$3"
}

# run_configib <VAR=value>... -- run the script with these variables and nothing else from the
# caller's environment.
run_configib()
{
    run env -i PATH="$BIN:/usr/bin:/bin" LC_ALL=C EVENTS="$EVENTS" \
        XCAT_CONFIGIB_ROOT="$ROOT" "$@" bash "$CONFIGIB"
}

# Print the events, for a failed assertion.
show_events()
{
    printf 'status=%s\n%s\n--- events\n' "$status" "$output" >&2
    cat "$EVENTS" >&2
}
