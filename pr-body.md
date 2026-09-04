fix(xcat-core): three test cases fail on an AlmaLinux 9 management node

makedhcp_n reports "service: command not found" and fails. nodeset_yaboot fails on its
first nodeset with "Unable to find requested field <xcatmaster> from table <noderes>".
nodeset_grub2 reports "The testnode1 can not be resolved" and writes no configuration file.

The three makedhcp cases in xCAT-test/autotest/testcase/makedhcp/cases0 probe and restart the
DHCP daemon with service(8). AlmaLinux 9 and AlmaLinux 10 do not install initscripts, so the
command exits 127 and the case reads the empty output as a stopped daemon. In
xCAT-test/autotest/testcase/nodeset/cases0, nodeset_yaboot gives testnode1 an address on a
network the management node has no interface on, and sets no noderes.xcatmaster. nodeset_grub2
builds the address of testnode1 from $$SN, a name no conf defines, so lsdef fails and the node
gets the address ".1.200".

The makedhcp cases now select the DHCP unit in the branches and drive that one unit with
systemctl. The two nodeset cases read the address prefix from site.master and set
noderes.xcatmaster on the chdef that already sets netboot and addkcmdline.

xCAT-test/unit/makedhcp_service_probe.t reads the probe line makedhcp_n ships and runs it on a
PATH with no service(8), against a systemctl stub that reports one unit running. It covers EL
with ISC dhcpd, EL with Kea, and Ubuntu. The two service(8) branches report nothing, so the
test fails on the test commit.

Commits: e1669a334 test, 14ea3df81 fix, 4a888f12a fix, 965393faa fix
LANDING ORDER: 4a888f12a must land together with fix/yaboot-nodeset-exit-code. The first supplies the missing precondition of nodeset_yaboot, the second makes yaboot.pm::setstate report failure. Either alone leaves the case red.
*unchecked* — the two nodeset case changes carry no unit test. An xcattest run of nodeset_yaboot and nodeset_grub2 on an EL9 management node would settle them.
