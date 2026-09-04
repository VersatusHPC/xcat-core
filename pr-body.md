fix(xCAT-test): the makedhcp DHCP restart is asserted by nothing

The cases makedhcp_a_d, makedhcp_a_d_ubuntu and makedhcp_d restart the DHCP daemon and then continue with no check. A failed restart leaves the case green. The trailing "makedhcp -a", which puts the compute node back into DHCP for the cases that follow, is also unchecked.

The three cases in xCAT-test/autotest/testcase/makedhcp/cases0 run the restart as one shell command with no check line after it. The command also ends with the restart itself, so the case reads no state back from the daemon.

The restart command now selects the unit once, holds it in a variable, restarts it and asks for its state. The unit is not uniform: an Ubuntu management node uses Kea, and an EL management node uses ISC or Kea. The selection ladder is the one the rest of the suite uses. Each restart gets check:rc==0 and check:output=~^active$. Each trailing "makedhcp -a" gets check:rc==0.

The change is the assertion, so there is no separate test commit. The guard was verified by mutation: with the restart forced to fail, makedhcp_a_d and makedhcp_d report Passed before the change, and Failed after it, on el10 with Kea and on el9 with ISC.

Commits: 427d9e2 fix
