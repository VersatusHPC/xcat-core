fix(xcat-core): the chain documentation offers runimage on a Genesis image that refuses it

An administrator follows the chain documentation, sets `nodeset <node> runimage=<url>`, and the node reports `UNSAFE_LEGACY_ACTION`. A default install pulls the OpenEmbedded Genesis image, because `xCAT.spec` recommends `xCAT-genesis-openembedded-<arch>` and `mknb` prefers that image.

`genesis-action` in `xCAT-genesis-builder/oe` refuses the runimage case unconditionally and calls `fail_action UNSAFE_LEGACY_ACTION`. Only the legacy Genesis image runs the task, in `doxcat`. The four documentation pages that describe runimage name no Genesis image, so a reader cannot tell which image runs the task.

The four pages now state that the legacy Genesis image runs runimage, and that the OpenEmbedded image refuses it with `UNSAFE_LEGACY_ACTION`. Each page names the replacement on OpenEmbedded: a signed system extension, built with `xCAT-genesis-builder/oe/export-extension`. The change is documentation only. It changes no code and no package.

This change adds no test. The two statements come from the runimage case of `xCAT-genesis-builder/oe/meta-xcat-genesis/recipes-core/xcat-genesis-init/files/genesis-action`, and from `xCAT-genesis-builder/oe/export-extension` in the same tree.

*unchecked* — no test covers these pages. A documentation build, and a reader comparing each note against the runimage case in `genesis-action`, would settle it.
