fix(builddebs): mklocalrepo.sh points a riscv64 node at the amd64 packages

apt on a riscv64 management node reports "Unable to locate package xcat" after mklocalrepo.sh runs, although the local repository carries the riscv64 deb. The generated apt entry says arch=amd64.

write_repo_metadata in builddebs.pl emits mklocalrepo.sh from a heredoc. The architecture map in that heredoc returns ppc64el for ppc64le and amd64 for every other machine, so riscv64 falls through to amd64. The same map was corrected in build-ubunturepo before that script was removed; builddebs.pl keeps the old copy.

This branch replaces the if/else with a case that names riscv64, and keeps amd64 as the default arm. It also adds a comment at the heredoc: the map runs on the machine that installs xCAT, not on the build host, so it stays in the script and not in BuildUtils.

xCAT-test/unit/builddebs_mklocalrepo_arch.t extracts the heredoc, replaces the two host couplings, and runs the script with uname shadowed. It reads the arch= value from the sources list the script writes, for x86_64, ppc64le, riscv64, aarch64, s390x, i686 and an empty uname. The riscv64 assertion fails without the change. The file uses BAIL_OUT, not skip_all, so a tree without builddebs.pl stops the test instead of passing it.

Commits: 87dfe05 test, aa10ec6 fix, 3d4004d test, d89b6a3 docs
