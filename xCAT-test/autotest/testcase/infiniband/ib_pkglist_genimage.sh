#!/bin/bash
#
# ib_pkglist_genimage.sh <os> <arch>
#
# Build a diskless image from the netboot compute list and the InfiniBand list of the
# distribution, then check that the image holds the packages of the list and ib_ipoib.ko.
# The osimage is a copy of <os>-<arch>-netboot-compute, so the case leaves that osimage as it was.
# No IB card is needed.

os=$1
arch=$2
src="${os}-${arch}-netboot-compute"
img="${os}-${arch}-netboot-ibtest"
imgdir="/install/netboot/${os}/${arch}/ibtest"
release="${os//[^0-9.]/}"
list="/opt/xcat/share/xcat/ib/netboot/rh/ib.rhels${release%%.*}.${arch}.pkglist"

fail() { echo "ib_pkglist_genimage: $*" >&2; exit 1; }

cleanup()
{
    rmimage "$img" >/dev/null 2>&1
    rmdef -t osimage -o "$img" >/dev/null 2>&1
    rm -rf "$imgdir"
}
trap cleanup EXIT

[ -r "$list" ] || fail "no InfiniBand list $list"
lsdef -t osimage -o "$src" >/dev/null 2>&1 || fail "no osimage $src"
cleanup
lsdef -t osimage -o "$src" -z | sed "s/^${src}:/${img}:/" | mkdef -z || fail "cannot copy $src"
pkglist=$(lsdef -t osimage -o "$src" -i pkglist -c | sed 's/^[^=]*=//')
chdef -t osimage -o "$img" pkglist="${pkglist},${list}" rootimgdir="$imgdir" || fail "chdef $img"
lsdef -t osimage -o "$img" -i pkglist,rootimgdir

genimage "$img" || fail "genimage $img failed"

root="${imgdir}/rootimg"
packages=$(grep -v '^#' "$list" | tr '\n' ' ')
rpm --root "$root" -q $packages || fail "the image lacks a package of $list"
module=$(find "$root"/lib/modules "$root"/usr/lib/modules -name 'ib_ipoib.ko*' 2>/dev/null | head -1)
[ -n "$module" ] || fail "the image has no ib_ipoib kernel module"
echo "ib_ipoib module: ${module#$root}"
echo "The image holds the InfiniBand stack."
