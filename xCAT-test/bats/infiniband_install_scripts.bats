#!/usr/bin/env bats
#
# rhel-infiniband-diskfull-install.sh and rhel-infiniband-diskless-install.sh, the scripts of the
# rhel_infiniband_* xcattest cases. Without MLNX_ISO they install the rdma-core stack of the
# distribution from the ib package list, with no MLNX_OFED and no DKMS. With MLNX_ISO they keep the
# MLNX_OFED flow.
#
# The xCAT commands are stubs that log to $EVENTS. INSTALL_DIR moves /install into the scratch
# tree, and XCATROOT is the checkout's xCAT-server, which holds share/xcat.

load 'helpers/shell_source'

setup()
{
    CASEDIR="$(repo_path xCAT-test/autotest/testcase/infiniband)"
    BIN="${BATS_TEST_TMPDIR}/bin"
    INST="${BATS_TEST_TMPDIR}/install"
    EVENTS="${BATS_TEST_TMPDIR}/events"
    STANZA="${BATS_TEST_TMPDIR}/stanza"
    mkdir -p "$BIN" "$INST/postscripts"
    : >"$EVENTS"
    : >"${BATS_TEST_TMPDIR}/dvd.iso"
    local command
    for command in copycds rmdef chdef makedhcp rinstall createrepo genimage packimage sleep; do
        printf '#!/bin/sh\necho "%s $*" >>"$EVENTS"\n' "$command" >"$BIN/$command"
    done
    printf '#!/bin/sh\necho "mkdef $*" >>"$EVENTS"\ncat >>"%s"\n' "$STANZA" >"$BIN/mkdef"
    printf '#!/bin/sh\necho "$1: sshd"\n' >"$BIN/nodestat"
    cat >"$BIN/xdsh" <<'SH'
#!/bin/sh
echo "xdsh $*" >>"$EVENTS"
case "$2" in
    'rpm -qa') echo "$1: mlnx-ofa_kernel-5.8" ;;
    'rpm -q '*) echo "$1: rdma-core-51.0" ;;
esac
SH
    chmod 0755 "$BIN"/*
}

# run_script <diskfull|diskless> <VAR=value>...
run_script()
{
    local kind=$1
    shift
    run env -i PATH="$BIN:/usr/bin:/bin" LC_ALL=C EVENTS="$EVENTS" INSTALL_DIR="$INST" \
        XCATROOT="$(repo_path xCAT-server)" COMPUTE_NODE=cn1 LINUX_ARCH=x86_64 \
        RHEL_ISO="${BATS_TEST_TMPDIR}/dvd.iso" "$@" \
        bash "$CASEDIR/rhel-infiniband-$kind-install.sh"
}

show()
{
    printf 'status=%s\n%s\n--- events\n' "$status" "$output" >&2
    cat "$EVENTS" >&2
}

@test "both scripts refuse to run without LINUX_DISTRO" {
    local kind
    for kind in diskfull diskless; do
        run_script "$kind"
        [ "$status" -ne 0 ] || { show; false; }
        [[ "$output" == *'LINUX_DISTRO'* ]] || { show; false; }
        refute_grep -q '^copycds' "$EVENTS"
    done
}

@test "diskfull without MLNX_ISO installs the distribution stack" {
    run_script diskfull LINUX_DISTRO=rhels10.0
    [ "$status" -eq 0 ] || { show; false; }
    grep -qx 'rhels10.0-x86_64-install-ib:' "$STANZA" || { show; cat "$STANZA" >&2; false; }
    pkglist="$INST/custom/install/rh/ib.rhels10.x86_64.pkglist"
    grep -qx 'rdma-core' "$pkglist"
    grep -qx 'openssh-server' "$pkglist"
    refute_grep -q 'mlnxofed_ib_install' "$EVENTS"
    [[ "$output" != *DKMS* ]] || { show; false; }
    grep -q '^xdsh cn1 rpm -q rdma-core' "$EVENTS" || { show; false; }
}

@test "diskless without MLNX_ISO builds an image with the distribution stack" {
    run_script diskless LINUX_DISTRO=rhels10.0
    [ "$status" -eq 0 ] || { show; false; }
    grep -qx 'rhels10.0-x86_64-netboot-ib:' "$STANZA" || { show; cat "$STANZA" >&2; false; }
    grep -qx 'rdma-core' "$INST/custom/netboot/rh/ib.rhels10.x86_64.pkglist"
    refute_grep -q 'mlnxofed_ib_install' "$INST/custom/netboot/rh/ib.rhels10.x86_64.postinstall"
    grep -qx 'genimage rhels10.0-x86_64-netboot-ib' "$EVENTS" || { show; false; }
    grep -q '^xdsh cn1 rpm -q rdma-core' "$EVENTS" || { show; false; }
}

@test "diskfull with MLNX_ISO keeps the MLNX_OFED postscript and the DKMS repository" {
    : >"${BATS_TEST_TMPDIR}/MLNX_OFED_LINUX-24.10-rhel10.0-x86_64.iso"
    : >"${BATS_TEST_TMPDIR}/dkms-3.0.el10.noarch.rpm"
    run_script diskfull LINUX_DISTRO=rhels10.0 \
        MLNX_ISO="${BATS_TEST_TMPDIR}/MLNX_OFED_LINUX-24.10-rhel10.0-x86_64.iso" \
        DKMS_RPM="${BATS_TEST_TMPDIR}/dkms-3.0.el10.noarch.rpm"
    [ "$status" -eq 0 ] || { show; false; }
    grep -qx 'rhels10.0-x86_64-install-mlnx:' "$STANZA"
    grep -q '^chdef cn1 postscripts=.*mlnxofed_ib_install -p .*/mlnx/MLNX_OFED_LINUX-24.10-rhel10.0-x86_64.iso' "$EVENTS" \
        || { show; false; }
    [ -f "$INST/post/otherpkgs/rhels10.0/x86_64/dkms/dkms-3.0.el10.noarch.rpm" ]
}
