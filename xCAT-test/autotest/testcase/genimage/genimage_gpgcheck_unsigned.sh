#!/bin/bash
#
# genimage_gpgcheck_unsigned.sh <os> <arch>
#
# Build a diskless image with linuximage.gpgcheck=1 from a copy of <os>-<arch>-netboot-compute.
# The otherpkgdir of the copy holds an unsigned build of hostname with a higher version than the
# DVD. The otherpkgs pass installs nothing new, so the package update that follows it is the step
# that fails the signature check, and genimage must stop there.
# The case removes the copy, its image directory and its work directory on exit.

os=$1
arch=$2
src="${os}-${arch}-netboot-compute"
img="${os}-${arch}-netboot-gpgtest"
imgdir="/install/netboot/${os}/${arch}/gpgtest"
work="/tmp/genimage_gpgcheck_unsigned"
nvr="hostname-999-1.xcatgpgtest"

fail() { echo "genimage_gpgcheck_unsigned: $*" >&2; exit 1; }

cleanup()
{
    rmimage "$img" >/dev/null 2>&1
    rmdef -t osimage -o "$img" >/dev/null 2>&1
    rm -rf "$imgdir" "$work" "/tftpboot/xcat/osimage/$img"
}
trap cleanup EXIT

lsdef -t osimage -o "$src" >/dev/null 2>&1 || fail "no osimage $src"
command -v rpmbuild >/dev/null || fail "no rpmbuild"
createrepo=$(command -v createrepo_c || command -v createrepo) || fail "no createrepo"
cleanup

mkdir -p "$work/rpmbuild/SPECS" "$work/otherpkgs/gpgtest" || fail "cannot create $work"
cat >"$work/rpmbuild/SPECS/hostname.spec" <<SPEC
Name: hostname
Version: 999
Release: 1.xcatgpgtest
Summary: Unsigned package for genimage_gpgcheck_unsigned
License: EPL
BuildArch: noarch
%description
An unsigned package that the xCAT test genimage_gpgcheck_unsigned builds.
%files
SPEC
rpmbuild -bb --quiet --define "_topdir $work/rpmbuild" "$work/rpmbuild/SPECS/hostname.spec" ||
    fail "rpmbuild failed"
rpm=$(find "$work/rpmbuild/RPMS" -name "${nvr}.noarch.rpm")
[ -n "$rpm" ] || fail "rpmbuild made no ${nvr}.noarch.rpm"
sig=$(rpm -qp --qf '%{RSAHEADER:pgpsig}%{SIGPGP:pgpsig}%{OPENPGP:pgpsig}' "$rpm" 2>/dev/null)
[[ "$sig" =~ ^(\(none\))+$ ]] || fail "$rpm carries a signature: $sig"
cp "$rpm" "$work/otherpkgs/gpgtest/" && "$createrepo" -q "$work/otherpkgs/gpgtest" ||
    fail "cannot create the otherpkgs repository"

# bash is in the pkglist and the DVD has no newer bash, so this install pass changes nothing.
echo "gpgtest/bash" >"$work/otherpkgs.pkglist"

lsdef -t osimage -o "$src" -z | sed "s/^${src}:/${img}:/" | mkdef -z || fail "cannot copy $src"
chdef -t osimage -o "$img" gpgcheck=1 rootimgdir="$imgdir" otherpkgdir="$work/otherpkgs" \
    otherpkglist="$work/otherpkgs.pkglist" || fail "chdef $img"
lsdef -t osimage -o "$img" -i gpgcheck,otherpkgdir,otherpkglist,rootimgdir

out=$(genimage "$img" 2>&1)
rc=$?
echo "$out"
echo "genimage exit status: $rc"

[[ "$out" == *"$nvr"* ]] || fail "the package manager never reached $nvr"
[ "$rc" -ne 0 ] || fail "genimage exited 0 after the signature check of $nvr failed"
[[ "$out" == *"RPM package manager invocation failed"* ]] ||
    fail "genimage did not print the message of its package failure check"
rpm --root "$imgdir/rootimg" -q "$nvr" >/dev/null 2>&1 && fail "the image holds $nvr"
echo "genimage stopped on the unsigned package."
