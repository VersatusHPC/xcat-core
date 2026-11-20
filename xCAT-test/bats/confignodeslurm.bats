#!/usr/bin/env bats
# confignodeslurm turns a node into a Slurm compute node. Each test runs in a
# scratch root with dnf, systemctl, chown, firewall-cmd and the credential
# fetch shadowed by shell functions.

bats_require_minimum_version 1.5.0

load 'helpers/shell_source'

setup()
{
    SCRIPT="$(require_repo_file 'xCAT/postscripts/confignodeslurm')"
    ROOT="${BATS_TEST_TMPDIR}/root"
    EVENTS="${BATS_TEST_TMPDIR}/events.log"
    mkdir -p "$ROOT/post/ohpc" "$ROOT/repos"
    echo 'ClusterName=xcat' >"$ROOT/post/ohpc/slurm.conf"
    export XCAT_SLURM_ETC="$ROOT/slurm" XCAT_MUNGE_ETC="$ROOT/munge" XCAT_YUM_REPOS="$ROOT/repos"
    export XCAT_POST_DIR="$ROOT/post" MASTER=10.0.0.21 INSTALLDIR=/install ARCH=x86_64
    export OSPKGDIR=/install/alma9.8/x86_64 EVENTS
    FIREWALLD=inactive
    export FIREWALLD
}

run_script()
{
    XCAT_SLURM_SOURCED=1
    . "$SCRIPT"
    dnf() { echo "dnf $*" >>"$EVENTS"; }
    chown() { echo "chown $*" >>"$EVENTS"; }
    systemctl() {
        echo "systemctl $*" >>"$EVENTS"
        [ "$1 $2" != "is-active --quiet" ] || [ "$FIREWALLD" = active ]
    }
    firewall-cmd() { echo "firewall-cmd $*" >>"$EVENTS"; }
    logger() { :; }
    # Replaces the xcatd credential request of the script.
    slurm_fetch_munge_key() { [ -n "${NO_KEY:-}" ] && return 1; echo 'S2V5S2V5' >"$1"; }
    slurm_main "$@"
}

@test "the node gets the repository, the key, slurm.conf, and starts slurmd" {
    run run_script
    [ "$status" -eq 0 ]
    grep -qx 'baseurl=http://10.0.0.21/install/ohpc/3/x86_64' "$ROOT/repos/xcat-ohpc.repo"
    grep -qx 'baseurl=http://10.0.0.21/install/alma9.8/x86_64/AppStream' "$ROOT/repos/xcat-ohpc.repo"
    grep -qx 'dnf install -y ohpc-slurm-client munge' "$EVENTS"
    [ "$(cat "$ROOT/munge/munge.key")" = 'S2V5S2V5' ]
    [ "$(stat -c %a "$ROOT/munge/munge.key")" = 400 ]
    grep -qx "chown munge:munge $ROOT/munge/munge.key.new" "$EVENTS"
    [ "$(cat "$ROOT/slurm/slurm.conf")" = 'ClusterName=xcat' ]
    grep -qx 'systemctl restart slurmd' "$EVENTS"
    run -1 grep -q '^firewall-cmd' "$EVENTS"
}

@test "firewalld running: the slurmd port is opened" {
    FIREWALLD=active
    run run_script
    [ "$status" -eq 0 ]
    grep -qx 'firewall-cmd --permanent --add-port=6818/tcp' "$EVENTS"
}

@test "no munge key: the node does not start slurmd" {
    NO_KEY=1
    export NO_KEY
    run run_script
    [ "$status" -eq 1 ]
    [ ! -e "$ROOT/munge/munge.key" ]
    run -1 grep -q 'systemctl restart slurmd' "$EVENTS"
}

@test "no published slurm.conf: nothing is installed" {
    rm -f "$ROOT/post/ohpc/slurm.conf"
    run run_script
    [ "$status" -eq 1 ]
    [ ! -e "$EVENTS" ]
}
