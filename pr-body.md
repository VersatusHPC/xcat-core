fix(xcat-core): makedhcp_remote_network restores /etc/hosts from a backup no case wrote

makedhcp_remote_network appends "100.100.100.2 testnode" to /etc/hosts and ends with "cp -f
/etc/hosts.bak /etc/hosts". No command in the case writes /etc/hosts.bak. The copy carries no
check, so xcattest records the case as Passed whatever the copy does.

xcattest runs every case on one management node and shares one /etc. The copy either fails and
leaves the test line in /etc/hosts for every case that follows, or it reads what an unrelated
case left at that path. makehosts_regex in xCAT-test/autotest/testcase/makehosts/cases0 writes
/etc/hosts.bak and restores it with cp, so the file survives that case. When both cases run on
one management node, the copy overwrites /etc/hosts with the content makehosts_regex saw, and
the management node stops resolving its own name, which makedns needs.

makedhcp_remote_network now writes /etc/hosts.makedhcp_remote_network.bak before it appends, and
restores with mv, so the backup belongs to the case and does not outlive it. makehosts_regex
restores with mv for the same reason.

xCAT-test/unit/xcattest_case_backup_restore.t reads the case tree, pairs each copy from a backup
path with the writes of the same case, and reports the copies with no pair. A copy behind an
[ -f ] test is left out. The test reports makedhcp_remote_network on the test commit and fails
there.

Commits: a1d7f85ac test, eadeb7ace fix
