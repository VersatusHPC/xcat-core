fix(xcat-core): the Ubuntu apt mirror ignores the node architecture

genimage fails to build a ppc64el netboot image. debootstrap reports "Couldn't download .../binary-ppc64el/Packages" from http://archive.ubuntu.com/ubuntu. That host carries amd64 and i386 only. ppc64el, riscv64, arm64 and s390x are on ports.ubuntu.com, and neither host serves the other's packages: archive.ubuntu.com/ubuntu/dists/jammy/main/binary-ppc64el/Packages.gz answers 404 and ports.ubuntu.com/ubuntu-ports/dists/jammy/main/binary-ppc64el/Packages.gz answers 200.

Two defaults name the primary archive for every architecture. The mirror fallback in xCAT-server/share/xcat/netboot/ubuntu/genimage reaches debootstrap and blocks the diskless image of every ports architecture. ubuntu_subiquity_apt_mirror in xCAT-server/lib/perl/xCAT/Template.pm reaches the Subiquity autoinstall as the primary apt mirror of a diskful install.

xCAT::Utils::ubuntu_apt_mirror returns the archive that serves an architecture. genimage passes the debootstrap architecture to it. Template.pm passes nodetype.arch of the node being templated, read by ubuntu_subiquity_arch with the fallback ubuntu_subiquity_release already uses. An unnamed architecture keeps the primary archive, and site.ubuntu_apt_mirror still overrides both defaults.

xCAT-test/unit/ubuntu_ports_apt_mirror.t evaluates the genimage mirror statement and calls Template.pm for amd64, i386, ppc64el, riscv64 and arm64, and checks that the site override still wins. The five ports assertions fail before the fix commit.

Commits: 58bcbdd test, 5fcc6a5 fix
