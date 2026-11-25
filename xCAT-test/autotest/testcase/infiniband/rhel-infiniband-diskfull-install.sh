#!/bin/bash

########
#
# Install a compute node diskful with an InfiniBand stack, then check the stack on the node.
#
# Without MLNX_ISO the script installs the rdma-core stack of the distribution from
# ${XCATROOT}/share/xcat/ib/netboot/rh/ib.<distro>.<arch>.pkglist. It needs no MLNX_OFED and no
# DKMS. With MLNX_ISO it installs MLNX_OFED with the mlnxofed_ib_install postscript, and
# DKMS_RPM names the dkms rpm that MLNX_OFED needs.
#
# Environment:
#   LINUX_DISTRO  osvers of the osimage, for example rhels10.0. Required.
#   LINUX_ARCH    default: the architecture of this host
#   COMPUTE_NODE  the node to install. Required.
#   RHEL_ISO      the installation DVD
#   MLNX_ISO      the MLNX_OFED ISO. Empty selects the distribution stack.
#   DKMS_RPM      the dkms rpm, for MLNX_OFED only
#   SOURCE_DIR    a directory to search for the three files above, when they are not set
#   INSTALL_DIR   default: /install
#   XCATROOT      default: /opt/xcat
#

[ -n "$LINUX_DISTRO" ] || { echo "Set LINUX_DISTRO, for example rhels10.0." >&2; exit 1; }
[ -n "$LINUX_ARCH" ] || LINUX_ARCH="$(uname -m)"
[ -n "$COMPUTE_NODE" ] || { echo "Set COMPUTE_NODE." >&2; exit 1; }
INSTALL_DIR="${INSTALL_DIR:-/install}"
XCATROOT="${XCATROOT:-/opt/xcat}"

########
# Search SOURCE_DIR for the files that the environment does not name.
#
# -rw-r--r-- 1 nobody nobody      79404 Jul 27 01:20 dkms-2.3-5.20170523git8c3065c.el7.noarch.rpm
# -rw-r--r-- 1 nobody nobody 29085696   Jul  9 09:24 MLNX_OFED_LINUX-4.1-1.0.2.0-rhel7.3-ppc64le.iso
# -rw-r--r-- 1 nobody nobody 3188944896 Oct 31  2016 RHEL-7.3-20161019.0-Server-ppc64le-dvd1.iso

if [ -n "${SOURCE_DIR}" ]; then
	[ -d "${SOURCE_DIR}" ] || { echo "Directory ${SOURCE_DIR} not found." >&2; exit 1; }
	for f in "${SOURCE_DIR}"/*
	do
		r="$(realpath "${f}")"
		[ -f "${r}" ] || continue
		case "${r##*/}" in
		"RHEL-"*"-"*"-Server-${LINUX_ARCH}-dvd1.iso")
			[ -n "${RHEL_ISO}" ] || RHEL_ISO="${r}"
			;;
		"MLNX_OFED_LINUX-"*"-"*"-${LINUX_DISTRO/s/}-${LINUX_ARCH}.iso")
			[ -n "${MLNX_ISO}" ] || MLNX_ISO="${r}"
			;;
		"dkms-"*".noarch.rpm")
			[ -n "${DKMS_RPM}" ] || DKMS_RPM="${r}"
			;;
		esac
	done
fi

DISTRO_MAJOR="${LINUX_DISTRO%%.*}"
if [ -n "${MLNX_ISO}" ]; then
	IB_STACK="mlnx"
else
	IB_STACK="ib"
fi

echo "Installation DVD: ${RHEL_ISO}"
if [ "${IB_STACK}" = "mlnx" ]; then
	echo "MLNX_OFED ISO: ${MLNX_ISO}"
	echo "dkms rpm: ${DKMS_RPM}"
else
	echo "InfiniBand stack: rdma-core of the distribution"
fi

########

OSIMAGE_NAME="${LINUX_DISTRO}-${LINUX_ARCH}-install-${IB_STACK}"
OSIMAGE_OTHERPKGDIR="${INSTALL_DIR}/post/otherpkgs/${LINUX_DISTRO}/${LINUX_ARCH}"
CUSTOM_DIR="${INSTALL_DIR}/custom/install/rh"
PKGLIST="${CUSTOM_DIR}/${IB_STACK}.${DISTRO_MAJOR}.${LINUX_ARCH}.pkglist"
OTHERPKGLIST="${CUSTOM_DIR}/${IB_STACK}.${DISTRO_MAJOR}.${LINUX_ARCH}.otherpkgs.pkglist"
IB_PKGLIST="${XCATROOT}/share/xcat/ib/netboot/rh/ib.${DISTRO_MAJOR}.${LINUX_ARCH}.pkglist"

[ -f "${RHEL_ISO}" ] || { echo "File ${RHEL_ISO} not found." >&2; exit 1; }
[ -f "${IB_PKGLIST}" ] || { echo "File ${IB_PKGLIST} not found." >&2; exit 1; }
copycds "${RHEL_ISO}"
[ "$?" -ne "0" ] && echo "Copy CD failed." >&2 && exit 1

rmdef -t osimage "${OSIMAGE_NAME}"
mkdef -z <<-EOF
# <xCAT data object stanza file>

${OSIMAGE_NAME}:
    objtype=osimage
    imagetype=linux
    osarch=${LINUX_ARCH}
    osdistroname=${LINUX_DISTRO}-${LINUX_ARCH}
    osname=Linux
    osvers=${LINUX_DISTRO}
    otherpkgdir="${OSIMAGE_OTHERPKGDIR}"
    otherpkglist=${OTHERPKGLIST}
    pkgdir=${INSTALL_DIR}/${LINUX_DISTRO}/${LINUX_ARCH}
    pkglist=${PKGLIST}
    profile=compute
    provmethod=install
    template=${XCATROOT}/share/xcat/install/rh/compute.${DISTRO_MAJOR}.tmpl
EOF
[ "$?" -ne "0" ] && echo "Make osimage definition failed." >&2 && exit 1

mkdir -p "${CUSTOM_DIR}"

(
	cat "${XCATROOT}/share/xcat/install/rh/compute.${DISTRO_MAJOR}.pkglist"
	echo
	cat "${IB_PKGLIST}"
) >"${PKGLIST}"

: >"${OTHERPKGLIST}"

rm -rf "${OSIMAGE_OTHERPKGDIR}"
mkdir -p "${OSIMAGE_OTHERPKGDIR}"

if [ "${IB_STACK}" = "mlnx" ]; then
	[ -f "${MLNX_ISO}" ] || { echo "File ${MLNX_ISO} not found." >&2; exit 1; }
	mkdir -p "${INSTALL_DIR}/mlnx"
	cp "${MLNX_ISO}" "${INSTALL_DIR}/mlnx"
	cp "${XCATROOT}/share/xcat/ib/scripts/Mellanox/mlnxofed_ib_install" \
		"${INSTALL_DIR}/postscripts/mlnxofed_ib_install"
	chdef "${COMPUTE_NODE}" "postscripts=syslog,remoteshell,syncfiles,mlnxofed_ib_install -p ${INSTALL_DIR}/mlnx/${MLNX_ISO##*/} -m --add-kernel-support"

	# MLNX_OFED builds its kernel modules with DKMS.
	mkdir -p "${OSIMAGE_OTHERPKGDIR}"/dkms
	if [ -f "${DKMS_RPM}" ]; then
		cp "${DKMS_RPM}" "${OSIMAGE_OTHERPKGDIR}/dkms"
	else
		echo "File ${DKMS_RPM} not found." >&2
	fi
fi

( cd "${OSIMAGE_OTHERPKGDIR}" && createrepo . )

makedhcp -n
rinstall "${COMPUTE_NODE}" "osimage=${OSIMAGE_NAME}"

INSTALL_TIMEOUT=1800
declare -i WAIT=0

while sleep 10
do
	(( WAIT += 10 ))
	nodestat "${COMPUTE_NODE}" | grep ': sshd$'
	[ "$?" -eq "0" ] && break
	[ "${WAIT}" -le "${INSTALL_TIMEOUT}" ]
	[ "$?" -ne "0" ] && echo "Operating system installation failed." >&2 && exit 1
done

# For workaround the GitHub issue #3549
sleep 5

xdsh "${COMPUTE_NODE}" date
[ "$?" -ne "0" ] && echo "Failed connect to compute node via SSH." >&2 && exit 1

if [ "${IB_STACK}" = "mlnx" ]; then
	xdsh "${COMPUTE_NODE}" 'rpm -qa' | grep 'mlnx'
	[ "$?" -ne "0" ] && echo "MLNX OFED installation checking failed." >&2 && exit 1
else
	xdsh "${COMPUTE_NODE}" "rpm -q $(grep -v '^#' "${IB_PKGLIST}" | tr '\n' ' ')"
	[ "$?" -ne "0" ] && echo "The InfiniBand packages are not installed." >&2 && exit 1
fi

xdsh "${COMPUTE_NODE}" 'lspci'
xdsh "${COMPUTE_NODE}" 'ibv_devinfo'
xdsh "${COMPUTE_NODE}" 'iblinkinfo'

exit 0
