fix(servicenode): the service node postscript installs a third-party repository

The servicenode postscript runs "dnf -y install epel-release" on every EL service node. It adds a repository the administrator did not choose, and it makes service node setup depend on internet access.

The Linux branch of xCAT/postscripts/servicenode reads /etc/os-release, and calls runcmd("dnf -y install epel-release") when the platform is EL. The block is a workaround for the perl dependencies of xCAT-server, and it does not work: perl-IO-Tty lives in CRB on el8, el9 and el10, and in no EPEL release, so "dnf install xCATsn" still does not resolve with EPEL enabled. xcat-dep builds those perl packages for every EL target, so the service node gets them from the xcat-dep repository it already reads.

This change removes the block from the Linux branch.

xCAT-test/unit/servicenode_third_party_repo.t extracts the Linux branch, evaluates it with runcmd recording in place of running, and shadows grep so the branch takes its EL path. It asserts that no recorded command adds a repository. Four checks first confirm the branch ran, so the assertion cannot pass on an empty command list. The assertion fails without the change.

Commits: e54cd15 test, 4f180f4 fix
LANDING ORDER: land after fix/sn-perl-deps in xcat-dep, with signed ppc64le packages published to the dep channel. Reversed, this change removes epel-release before the replacement packages exist, and the service node install breaks.
