fix(xcat-core): the genesis harness passes on a nodeset that failed and a node that never booted

The `nodeset_shell_incorrectmasterip` case passed while `nodeset testnode shell` failed with `"/tftpboot/boot/grub2/grub2.x86_64" does not exits`. Every genesis case reported `After 30 iterations node status: powering-on` and passed as well. A run that provisions nothing cannot be told from a run that works.

`check_destiny` in `xCAT-test/autotest/testcase/genesis/test.sh` discarded the return value of `runcmd` and read the boot configuration file, which `grub2.pm` writes before it stops on the missing boot loader. xCAT builds no grub2 network boot loader for x86_64, so that file is absent on a correct management node. `wait_for_boot` in `genesistest.pl` waited for the `nodelist.status` value `booted`. A Genesis node reports its destiny with `getdestiny`, and xcatd writes `shell`, `configuring` or `booting` from it, never `booted`. Every caller discarded the return value. The node reached none of those statuses either, because `getdestiny` makes its request file with `mktemp`, which the dracut module never installed.

`check_destiny` returns the status of `nodeset`. The grub2 check stages an empty `grub2.<arch>` when the management node has none, and removes it after. `wait_for_node_status` replaces `wait_for_boot`, takes the status the destiny implies, and each caller fails on it. The shell case moved into `run_nodeset_shell_test`, so its result can be read. The dracut modules install `mktemp`, and `verify-genesis-payload` requires it.

`xCAT-test/unit/genesis_incorrectmasterip_check.t` runs the check with a nodeset that fails. `genesis_testcase_helpers.t` drives the status wait with `lsdef` shadowed, and drives the shell case with every command it runs shadowed. Both extract `wait_for_node_status` and `run_nodeset_shell_test`, which the fix commit adds, so both stop at `BAIL_OUT` on the test commit.

Commits: 359776064 test, 8ecf0a806 fix
