fix(xcat-core): nodeset accepts a runimage the OpenEmbedded node refuses

`nodeset <node> runimage=<url>` succeeds on a node that boots the OpenEmbedded Genesis image. That image refuses every runimage task, so the operator waits for a boot and then reads `ACTION_FAILED` on the console. On riscv64 the OpenEmbedded image is the only Genesis image, so runimage never runs there.

`setdestiny` in `xCAT-server/lib/xcat/plugins/destiny.pm` validated the image path and nothing else. `mknb` writes `/tftpboot/xcat/genesis.exact-arch.<arch>` for the OpenEmbedded export and removes it for the legacy image, so the tftp tree already records which image the node boots. `setdestiny` did not read that marker.

`_genesis_runimage_refusal` reads the marker for the architecture of the node, and `setdestiny` reports the refusal instead of writing the chain. The legacy image is unchanged, because the marker is absent for it. The refusal in `genesis-action` told the operator to package the work as a signed system extension. An extension is built into the image, so no xCAT command can assign one; the recovery text now names `runcmd`. `chain_tasks.rst` names the two Genesis images and the tasks that each one runs.

`xCAT-test/unit/destiny_runimage_generation.t` extracts `_genesis_runimage_refusal` from `destiny.pm` and drives it over a scratch tftp tree, with no marker, with a marker for another architecture, and with the marker for the node. `genesis_openembedded_actions.t` reads the recovery text of the refusal in `genesis-action`. The extraction has no match on the test commit, so the first test stops at `BAIL_OUT` there and the second reads the old recovery text.

Commits: fa877f0be test, d68678a81 fix
