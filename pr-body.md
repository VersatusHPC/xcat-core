fix(xcat-core): the documentation offers configraid and runimage on a Genesis image that refuses them

An administrator follows the hardware RAID page, sets `nodeset <node> runcmd="configraid ..."`, and the node reports `ACTION_COMMAND_NOT_APPROVED`. An administrator reads `nodeset(8)`, sets `runimage=<task>`, and the node reports `UNSAFE_LEGACY_ACTION`. A default install pulls the OpenEmbedded Genesis image, because `xCAT.spec` recommends `xCAT-genesis-openembedded-<arch>` and `mknb` prefers that image.

The OpenEmbedded image packages only `bmcsetup` under `/usr/libexec/xcat/genesis/actions`, so `run_approved_command` in `genesis-action` finds no `configraid` executor. A bare `configraid` action reports `LEGACY_STORAGE_ACTION`. Only the legacy image ships `xCAT-genesis-scripts/usr/bin/configraid`. `genesis-action` also refuses the runimage case unconditionally. Commit `16196f66a` fixed the four handwritten chain pages, but the generated man pages repeat runimage with no caveat.

The hardware RAID page now states that the legacy Genesis image runs `configraid`, and that the OpenEmbedded image refuses `runcmd=configraid`. The three man8 PODs and the chain table description in `Schema.pm` carry the same statement for runimage, and the six pages that `create_man_pages.py` generates from them carry the sentences byte-identical to the `pod2rst` and `db2man` output. The change is documentation only. It changes no code path and no package.

This change adds no test. The statements come from the `runcmd`, `runimage` and `configraid` cases of `xCAT-genesis-builder/oe/meta-xcat-genesis/recipes-core/xcat-genesis-init/files/genesis-action`, from the `FILES:${PN}` list of `xcat-genesis-bmcsetup_1.0.bb`, and from `xCAT-genesis-scripts/xCAT-genesis-scripts.spec`. `xCAT-test/unit/genesis_openembedded_actions.t` already asserts `configraid => LEGACY_STORAGE_ACTION`.

`sysclone` does not share the gap. Its documentation describes `imgcapture` and systemimager, never the chain action, so no page changed there.

Sphinx 7.2.6 builds `docs/source` with `build succeeded, 163 warnings`, the same count as before the change.
