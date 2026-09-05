fix(xcat-core): the 2.18 Ubuntu management node has no NTP daemon that can serve time

**This targets the `2.18` release branch, not master.** The change is already on
`xcat2/xcat-core` master (`067eda810` and six follow-ups) and on `release/2.19-rc1`. Base this
review on `2.18`.

makentp returns 1 on an Ubuntu management node and reports "Please make sure ntpd is installed".
Ubuntu ships systemd-timesyncd only, and timesyncd is an SNTP client that cannot serve time, so
compute nodes pointed at `<xcatmaster>` get no time source and the gated case
`reg_linux_diskfull_installation_flat` fails on the makentp check. `xcat-core-stable-ubuntu-cd`
builds `2.18`, where `perl-xCAT/xCAT/NTP/Backend.pm` does not exist.

Three things produce it. `makentp.pm` probes `/usr/sbin/chronyd` itself, so there is no selector
and no way to state which daemon the cluster wants. `xCAT/debian/control` and `xCAT/xCAT.spec`
declare no time daemon, so nothing installs one. `xCAT/postscripts/setupntp` requires `hwclock`
through `check_exec_or_exit` and aborts the whole NTP setup when it is absent, which it is on
Ubuntu 24.04 where hwclock moved to `util-linux-extra`.

`xCAT::NTP::Backend` selects the daemon from `site.ntpbackend`, defaults per distro family, and
downgrades to whichever of chrony or ntpd is installed. makentp selects through it and passes the
choice to setupntp as `--backend`, so the same daemon is configured on the management node and on
the nodes. The xcat metapackage Depends on `chrony | ntp` and the xCAT rpm Requires
`(chrony or ntp)`. setupntp uses hwclock when present, and stops systemd-timesyncd above the
hand-off to `setupntp.traditional` so both backends reach it.

`xCAT-test/unit/ntp_backend_selection.t`, `makentp_backend_call_site.t`, `makentp_ntp_deps.t` and
`setupntp_timesyncd_both_backends.t` are taken verbatim from master. All four fail on `2.18`
before the fix commit: three `BAIL_OUT` on routines and script sections that do not exist, and
`ntp_backend_selection.t` cannot load the module. After it, 90 assertions pass and the rest of
`prove -r xCAT-test/unit` is unchanged.

### What this backport leaves out

The master series is fifteen commits. This branch takes the end state of the NTP files, not the
first commit alone: `067eda810` by itself carries defects that five later commits fixed --- the
selector reporting chrony available where makentp will not use it (`a6212e838`), timesyncd left
running on the ntpd path (`994b47a94`), `--backend ntpd` configuring an absent daemon
(`670ea2df5`), the backend not reaching the nodes (`a13a74f4c`), and an untestable call site
(`124e2782d`). Taking the end state touches the same files.

`xCAT/debian/control` on master also moves `bind9` from Recommends to Depends and adds the
`xcat-genesis-openembedded-*` Recommends. Both come from unrelated fixes and are not here. Only
`chrony | ntp` and `util-linux-extra` are added.

Commits: 43ed0bcc5 test, a1b90bf48 fix
