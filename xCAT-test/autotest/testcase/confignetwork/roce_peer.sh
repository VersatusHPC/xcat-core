#!/bin/bash
###############################################################################
# roce_peer.sh - the management-node end of the soft-RoCE cases.
#
# Runs ON the MN. The compute node gets its RDMA link from confignetwork; this
# script gives the MN a peer for it: an address on the NIC that reaches the
# compute node, a soft-RoCE link on that NIC, and an rping or ib_send_bw server.
#
#   up    <cn-ip> <addr/prefix>   add <addr/prefix> and the link xcatci_rxe to the
#                                 NIC that routes to <cn-ip>
#   serve rping|ib_send_bw <addr> start that server on <addr> in the background
#   down  <cn-ip> <addr/prefix>   stop the servers, delete the link and the address
###############################################################################

LINK=xcatci_rxe
PIDDIR=${PIDDIR:-/tmp/xcatci-roce}

nic_to() {
    ip -o route get "$1" | sed -n 's/.* dev \([^ ]*\).*/\1/p'
}

case "$1" in
up)
    dev=$(nic_to "$2")
    [ -n "$dev" ] || { echo "Error: no route to $2"; exit 1; }
    modprobe rdma_rxe || { echo "Error: the kernel has no rdma_rxe module"; exit 1; }
    ip addr replace "$3" dev "$dev" || exit 1
    # A NIC carries one RDMA device. A second rdma link add on it fails.
    if ! rdma link show | grep -q " netdev $dev\$"; then
        rdma link add "$LINK" type rxe netdev "$dev" || exit 1
    fi
    rdma link show
    ;;
serve)
    mkdir -p "$PIDDIR"
    # The server exits after one client. timeout stops it when no client comes.
    case "$2" in
    rping) timeout 300 rping -s -a "$3" -C 10 -v </dev/null >"$PIDDIR/rping.log" 2>&1 & ;;
    ib_send_bw) timeout 300 ib_send_bw -R -n 1000 </dev/null >"$PIDDIR/ib_send_bw.log" 2>&1 & ;;
    *) echo "Error: unknown server $2"; exit 1 ;;
    esac
    echo $! >"$PIDDIR/$2.pid"
    sleep 2
    kill -0 "$(cat "$PIDDIR/$2.pid")" || { cat "$PIDDIR/$2.log"; exit 1; }
    ;;
down)
    for f in "$PIDDIR"/*.pid; do
        [ -e "$f" ] && kill "$(cat "$f")" 2>/dev/null
        rm -f "$f"
    done
    dev=$(nic_to "$2")
    rdma link delete "$LINK" 2>/dev/null
    [ -n "$dev" ] && ip addr del "$3" dev "$dev" 2>/dev/null
    true
    ;;
*)
    echo "Usage: $0 up|serve|down ..."
    exit 1
    ;;
esac
