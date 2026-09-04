fix(xcat-core): six xcattest checks pass on the failure they test for

A check whose expected pattern also appears in its own command is green whatever the command
does. nodeset_shell_lzma asserts "output=~genesis" on "ls -l /tftpboot/xcat/genesis.fs.*.lzma",
so the error "ls: cannot access '/tftpboot/xcat/genesis.fs.*.lzma'" matches too. Six checks have
this shape and are the only proof of the property their case exists to test.

xdcp_RP and xdcp_R write "test1" into /tmp/xdcp/test1/test1.txt, read it back and assert
"output=~test1", so "No such file or directory" matches. updatenode_diskful_syncfiles_dir has
the same shape for the files updatenode -F syncs. lsxcatd_null asserts "output=~lsxcatd" on the
command "lsxcatd". export_import_multiple_osimages_by_dir asserts "output=~site" on "ls -R
/opt/inventory/site".

The lzma check is now "rc==0", and ls returns 2 when the glob matches no file. The copied and
synced files carry a content marker the path does not repeat, so the check reads the bytes.
lsxcatd_null asserts a line of the usage text, and the two inventory listings assert the
exported osimage name. The case also installed xz-lzma-compat from a CentOS 8-Stream URL that
returns 404; that command and its paired yum remove are deleted.

The changed check is itself the assertion, so the branch adds no unit test. Each replaced check
and each new check was driven with the runcmd and check evaluation code of xCAT-test/xcattest,
with the behaviour present and with it removed.

Commits: 942729abe fix, 194dd4ec6 fix
*unchecked* — an xcattest run of genesis, xdcp, updatenode, lsxcatd and xcat_inventory with each behaviour removed would show every new check red.
