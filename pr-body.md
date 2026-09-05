fix(xcat-core): nodeset refuses a POWER Ubuntu live-server image

nodeset on a ppc64el node reports "The network boot initrd.gz is not found in /install/<osvers>/ppc64el/install/netboot. This is provided by Ubuntu, please download and retry." and skips the node, so the node never gets a boot configuration. The Ubuntu live-server ISO that copycds imports has an empty install/ directory. Its kernel and initrd are casper/vmlinux and casper/initrd on 22.04, 24.04 and 26.04, and casper/vmlinux with casper/initrd.gz on 20.04.

Two places in xCAT-server/lib/xcat/plugins/debian.pm read the debian-installer layout. mkinstall gates a POWER node on install/netboot/initrd.gz or install/netboot/ubuntu-installer/<darch>/initrd.gz, which live media does not carry, and reports the message above. The ppc64 rows of %INSTALL_BOOT_FILES name the same two netboot layouts and no live layout, so install_boot_files resolves nothing even when the gate is passed. Driving install_boot_files over a copy of the 22.04.5 ppc64el layout returns nothing.

The gate now passes media that is_ubuntu_live_media recognises, and the ppc64 rows carry the casper layouts: the hardware-enablement kernel before the release kernel, and initrd.gz for 20.04. The netboot rows keep their place, so a netboot tree still wins on media that has both. The x86 rows are unchanged. The two changed places are read only by debian.pm, so the change reaches Ubuntu and Debian POWER installs and no other platform. The Subiquity command line already carries boot=casper and an address-based nfsroot for every architecture, and is unchanged here.

xCAT-test/unit/debian_ppc64_netboot_media_gate.t lifts the gate out of mkinstall and drives it inside a loop over scratch media: a live-server tree, a netboot tree, and media with no installer. xCAT-test/unit/debian_install_boot_files.t resolves the POWER casper layouts. Seven assertions fail before the fix commit.

Commits: 719608b test, 7e06ad0 fix
