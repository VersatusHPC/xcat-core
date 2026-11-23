#!/usr/bin/env bats
# configure_roce_nic in nicutils.sh: the RDMA half of a nictypes=RoCE nic.
# rdma, modprobe, mount and systemctl are shell functions that log to a file,
# so nothing on the host changes. The rdma_cm configfs tree and the systemd
# unit dir are scratch directories.

bats_require_minimum_version 1.5.0

load 'helpers/shell_source'

setup()
{
    NICUTILS="$(require_repo_file 'xCAT/postscripts/nicutils.sh')"
    EVENTS="${BATS_TEST_TMPDIR}/events.log"
    LINKS="${BATS_TEST_TMPDIR}/links"
    export XCAT_SYSTEMD_UNIT_DIR="${BATS_TEST_TMPDIR}/systemd"
    export XCAT_RDMA_CM_CONFIGFS="${BATS_TEST_TMPDIR}/config/rdma_cm"
    mkdir -p "$XCAT_SYSTEMD_UNIT_DIR"
    # The kernel makes ports/1 when a device dir is made in configfs.
    mkdir -p "$XCAT_RDMA_CM_CONFIGFS/rxe_ens4/ports/1" "$XCAT_RDMA_CM_CONFIGFS/mlx5_0/ports/1"
    : >"$EVENTS"
    : >"$LINKS"
    export EVENTS LINKS
}

# The fake rdma keeps its links in $LINKS, in the format of rdma link show.
run_roce()
{
    rdma()
    {
        echo "rdma $*" >>"$EVENTS"
        case "$1 $2" in
        "link show") cat "$LINKS" ;;
        "link add") echo "link $3/1 state ACTIVE physical_state LINK_UP netdev $7 " >>"$LINKS" ;;
        esac
        return 0
    }
    modprobe() { echo "modprobe $*" >>"$EVENTS"; return 0; }
    mount() { echo "mount $*" >>"$EVENTS"; return 0; }
    systemctl() { echo "systemctl $*" >>"$EVENTS"; return 0; }
    . "$NICUTILS"
    configure_roce_nic "$@"
}

roce_mode()
{
    cat "$XCAT_RDMA_CM_CONFIGFS/$1/ports/1/default_roce_mode"
}

@test "a nic with no RDMA device gets a soft-RoCE link and RoCE v2" {
    run run_roce ens4
    [ "$status" -eq 0 ]
    grep -qx 'modprobe rdma_rxe' "$EVENTS"
    grep -qx 'rdma link add rxe_ens4 type rxe netdev ens4' "$EVENTS"
    [ "$(roce_mode rxe_ens4)" = 'RoCE v2' ]
}

@test "the RDMA device that the nic already has is kept" {
    echo 'link mlx5_0/1 state ACTIVE physical_state LINK_UP netdev ens4f0 ' >"$LINKS"
    run run_roce ens4f0
    [ "$status" -eq 0 ]
    ! grep -q 'rdma link add' "$EVENTS"
    ! grep -q 'modprobe rdma_rxe' "$EVENTS"
    [ "$(roce_mode mlx5_0)" = 'RoCE v2' ]
}

@test "a device on another nic with a longer name does not count" {
    echo 'link mlx5_0/1 state ACTIVE physical_state LINK_UP netdev ens4f0 ' >"$LINKS"
    run run_roce ens4
    [ "$status" -eq 0 ]
    grep -qx 'rdma link add rxe_ens4 type rxe netdev ens4' "$EVENTS"
}

@test "configfs is mounted when rdma_cm is not there" {
    rm -rf "$XCAT_RDMA_CM_CONFIGFS"
    run run_roce ens4
    grep -qx "mount -t configfs none ${BATS_TEST_TMPDIR}/config" "$EVENTS"
}

@test "a unit brings the link and RoCE v2 back after a reboot" {
    run run_roce ens4
    [ "$status" -eq 0 ]
    unit="$XCAT_SYSTEMD_UNIT_DIR/xcat-roce-ens4.service"
    [ -f "$unit" ]
    grep -qx 'ExecStart=/usr/sbin/modprobe rdma_rxe' "$unit"
    grep -q '^ExecStart=/bin/sh -c .*rdma link add rxe_ens4 type rxe netdev ens4' "$unit"
    grep -q "^ExecStart=/bin/sh -c .*echo RoCE v2 >$XCAT_RDMA_CM_CONFIGFS/rxe_ens4/ports/1/default_roce_mode" "$unit"
    grep -qx 'systemctl enable xcat-roce-ens4.service' "$EVENTS"
}

@test "the unit of a hardware RoCE nic sets the mode and adds no link" {
    echo 'link mlx5_0/1 state ACTIVE physical_state LINK_UP netdev ens4f0 ' >"$LINKS"
    run run_roce ens4f0
    [ "$status" -eq 0 ]
    unit="$XCAT_SYSTEMD_UNIT_DIR/xcat-roce-ens4f0.service"
    ! grep -q 'rdma link add' "$unit"
    ! grep -q 'rdma_rxe' "$unit"
    grep -q "echo RoCE v2 >$XCAT_RDMA_CM_CONFIGFS/mlx5_0/ports/1/default_roce_mode" "$unit"
}

@test "a failed rdma link add fails the nic" {
    run_fail()
    {
        rdma()
        {
            echo "rdma $*" >>"$EVENTS"
            [ "$2" = add ] && return 1
            return 0
        }
        modprobe() { return 0; }
        mount() { return 0; }
        systemctl() { return 0; }
        . "$NICUTILS"
        configure_roce_nic ens4
    }
    run run_fail
    [ "$status" -ne 0 ]
    [ ! -s "$XCAT_RDMA_CM_CONFIGFS/rxe_ens4/ports/1/default_roce_mode" ]
}
