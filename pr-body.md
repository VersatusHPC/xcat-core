fix(xcat-core): updatenode -F cases set the synclist on an osimage the node is not on

Ten file-sync cases in xCAT-test/autotest/testcase/updatenode/cases0 fail on an EL cell. The
node reports "There were no syncfiles defined to process" and the assertion that the synced file
arrived fails.

Each case sets synclists on the osimage named <os>-<arch>-install-compute, then runs updatenode
-F against the compute node. updatenode resolves the synclist through nodetype.provmethod, in
SvrUtils::getsynclistfile, so the attribute is invisible whenever the node is bound to another
image. The flat CD bundle provisions the compute node stateless last, so provmethod names the
netboot image. updatenode_diskful_syncfiles, updatenode_diskful_syncfiles_dir and
updatenode_diskful_syncfiles_P_script1 fail on every EL cell. The other seven cases pass only
because updatenode_diskful_syncfiles_failing runs before them and binds the node again with
nodeset.

Each case now names the osimage as __GETNODEATTR($$CN,provmethod)__, the form
updatenode_syncfile_EXECUTE in the same file already uses. The cases no longer depend on the
bundle order or on the image provisioned last.

The changed cases are themselves the assertion, so the branch adds no unit test. The case
asserts that the synced file arrived on the node, which holds only when updatenode reads the
synclist of the image the node is bound to.

Commits: 773da0421 fix
*unchecked* — an xcattest run of updatenode on an EL9 x86_64 management node, with the node bound to the netboot image, would show the cases red before the change.
