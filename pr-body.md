fix(xcat-core): the legacy Genesis image for el10 carries no DHCP client

A compute node that boots the legacy Genesis image on el10 x86_64 never acquires an address. The serial console reports `/usr/bin/doxcat: line 293: dhclient: command not found` and then `It seems to be taking a while to acquire an IPv4 address`. The DHCP server side is sound. Kea leases the address and the node never asks for it. No legacy Genesis case passes on el10 x86_64.

AlmaLinux 10 and EPEL 10 package no ISC dhcp-client. `dracut_install` in `xCAT-genesis-builder/dracut_105/el/module-setup.sh` reports a missing binary and returns, so the module install function keeps going and the image ships with no client. `xCAT-genesis-scripts/usr/bin/doxcat` names `dhclient` at six call sites and offers no alternative.

`doxcat` now chooses its client at run time. `genesis_dhcp_command()` returns the command line for one interface and one address family. `genesis_start_dhcp()` runs that command line and reports when the image carries no client. The ISC client keeps its command line where a release packages it, so el8 and el9 are unchanged. Where it is absent, `dhcpcd` stands in, and it carries its own resolv.conf, hostname and ntp hooks. The dracut module installs whichever client the build root holds. The spec build-requires `dhcpcd` from rhel 10 on, and `verify-genesis-payload` requires it there.

`xCAT-test/unit/genesis_dhcp_client.t` extracts the two routines from `doxcat` and runs them with the clients shadowed by stubs that record their own argv. `doxcat` cannot be sourced. The test also reads the spec and the dracut module. Nine of its assertions fail on the test commit, where neither routine exists.

Commits: 5d2801f40 test, b9329998c fix
