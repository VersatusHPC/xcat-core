#!/bin/bash
#
# ib_pkglist_install_cn.sh <node>
#
# Install the InfiniBand stack of the distribution on a diskful node with updatenode -P ospkgs,
# from the install list install/rh/ib.<release>.<arch>.pkglist. ospkgs installs from the
# repositories of the osimage pkgdir, BaseOS and AppStream. The pkglist of the osimage is put
# back at the end. No IB card is needed.

node=$1
fail() { echo "ib_pkglist_install_cn: $*" >&2; exit 1; }
attr() { lsdef "$@" -c 2>/dev/null | sed 's/^[^=]*=//'; }

img=$(attr "$node" -i provmethod)
case "$img" in
    *-install-*) ;;
    *) fail "$node is not diskful: provmethod=$img" ;;
esac
os=$(attr "$node" -i os)
arch=$(attr "$node" -i arch)
release="${os//[^0-9.]/}"
list="/opt/xcat/share/xcat/install/rh/ib.rhels${release%%.*}.${arch}.pkglist"
netlist="/opt/xcat/share/xcat/ib/netboot/rh/ib.rhels${release%%.*}.${arch}.pkglist"
[ -r "$list" ] || fail "no install list $list"

old=$(attr -t osimage -o "$img" -i pkglist)
trap 'chdef -t osimage -o "$img" pkglist="$old" >/dev/null' EXIT
chdef -t osimage -o "$img" pkglist="$list" || fail "chdef $img"

updatenode "$node" -P ospkgs || fail "updatenode -P ospkgs failed"
xdsh "$node" "dnf -q repolist"
packages=$(grep -v '^#' "$netlist" | tr '\n' ' ')
xdsh "$node" "rpm -q $packages" || fail "$node lacks a package of $list"
echo "$node holds the InfiniBand stack."
