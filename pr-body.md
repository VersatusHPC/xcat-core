fix(xcat-core): the Debian genesis packages ignore the node architecture

A ppc64el management node installs the amd64 Genesis. The `xcat` and `xcatsn` packages declare `Architecture: amd64 ppc64el riscv64` and one unrestricted `Depends: xcat-genesis-scripts-amd64`. That package is `Architecture: all`, so apt reports no error, lays down the x86_64 Genesis tree and pulls the amd64 base. The node receives no Genesis for its own architecture. On ppc64el, `go-xcat install` stops with `E: Unable to locate package xcat-genesis-scripts-ppc64`, and apt refuses the whole transaction.

`xCAT/debian/control` and `xCATsn/debian/control` put no architecture restriction on the dependency. `xCAT-genesis-scripts/debian/control-ppc64el` builds `xcat-genesis-scripts-ppc64` and depends on `xcat-genesis-base-ppc64`. `debuild-xcat-genesis-base` maps only x86_64 to amd64, so the alien base deb keeps the rpm architecture. The dpkg branch of `GO_XCAT_INSTALL_LIST` in `xCAT-server/share/xcat/tools/go-xcat` names the same rpm architecture.

The two control files restrict the dependency by architecture, the way `xCAT.spec` does. `control-ppc64el` builds `xcat-genesis-scripts-ppc64el` against `xcat-genesis-base-ppc64el`. It declares `Conflicts:` and `Replaces: xcat-genesis-scripts-ppc64`, so apt removes the old package when it installs the new one. `debuild-xcat-genesis-base` gains an architecture map, and the go-xcat dpkg list names the Debian architecture.

`xCAT-test/unit/debian_control_arch_coverage.t` applies each architecture restriction the way `dpkg-gencontrol` does, and asserts that each architecture receives its own genesis scripts. `xCAT-test/unit/go_xcat_genesis_package_names.t` compares both go-xcat lists with the packaging. `xCAT-test/unit/genesis_base_deb_arch.t` drives `debuild-xcat-genesis-base` with `alien` shadowed. Each one fails without its fix commit.

Commits: 76d6967ed test, 6798db5fb fix; 8c87ecf8e test, b83d3379e fix; 4c8162824 fix with test
LANDING ORDER: promote xcat-dep to the latest channel before xcat-core 2.19 reaches latest. latest/xcat-dep carries no xcat-genesis-base-ppc64el on focal, jammy, noble or resolute, so apt refuses the ppc64el xcat install.
