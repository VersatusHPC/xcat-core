fix(ddns): xCAT signs DNS updates with hmac-md5, which a FIPS named rejects

makedns fails on a management node in FIPS mode when the site table names no OMAPI algorithm. named reports no error for the key stanza it loaded, and then refuses every dynamic update signed with that key: it logs `tsig verify failure (BADSIG)`, answers SERVFAIL to the update, and makedns reports FORMERR.

xCAT::DHCP::OmapiPolicy->normalize_algorithm returned hmac-md5 when no algorithm is configured. xcatconfig writes site.dhcpomapialgorithm only on a first install, so a re-run of xcatconfig and an upgrade both keep hmac-md5. update_namedconf in xCAT-server/lib/xcat/plugins/ddns.pm replaced a key stanza only for a site that named an algorithm, so a site that named none kept its md5 stanza and kept signing with it. Net::DNS signs hmac-md5 in pure Perl and not through libcrypto, so xCAT sends a valid signature and named refuses it.

normalize_algorithm now returns hmac-sha256, and update_namedconf replaces a key stanza that is weaker than the algorithm makedns signs with. Three rules keep the change from moving a cluster that works:

* makedhcp passes the algorithm the running dhcpd.conf declares, so an upgraded cluster keeps its OMAPI key until makedhcp -n writes a new stanza.
* makedns keeps a named.conf key stanza that is at least as strong as the default, so a stanza an administrator set to hmac-sha512 survives. A site that names an algorithm still selects it, in both directions.
* A cluster whose DNS is external keeps hmac-md5 while the site table names no algorithm. xCAT does not manage that server and cannot rekey it, so an administrator adds the new key there and then sets the attribute.

new_install_default_algorithm writes hmac-md5 into the site table for a platform whose omshell rejects the key-algorithm command: Ubuntu 18.04, SLES 12, SLES 15 and openSUSE Leap 15. EL8 was on that list and does not belong there. On AlmaLinux 8.10 (dhcp-server-4.3.6-50.el8_10) omshell creates a host object over an hmac-sha256 OMAPI key, is rejected by the server with a wrong secret, and cannot connect at all with the command left out or given a bogus name. A site that names hmac-md5 is unchanged. The branch also carries the two fixes of fix/ddns-tsig-algorithm-downgrade: the named.conf stanza rewrite and the two TSIG records on a retry.

xCAT-test/unit/ddns_tsig_default_algorithm.t drives normalize_algorithm, the makedhcp OMAPI policy and update_namedconf over a scratch named.conf, then signs one update, for each rule above. Every fix commit follows the test commit that fails without it.

*unchecked*: the omshell of Ubuntu 18.04, SLES 12, SLES 15 and openSUSE Leap 15. No host of those was reachable (xcat-master-suse does not answer ARP), so those platforms keep the hmac-md5 pin. The EL8 probe (a dhcpd with an hmac-sha256 OMAPI key inside a network namespace, driven by omshell with and without key-algorithm) settles each of them in one run.

Reproduced on xcat52-mn, AlmaLinux 9.8 with FIPS mode enabled, xCAT-2.19.0-snap202609021541. With site.dhcpomapialgorithm unset and an hmac-md5 key stanza, makedns returns 1 and named logs `tsig verify failure (BADSIG)`; one update signed the way the plugin signs it answers SERVFAIL and the record does not resolve. With the two changed files installed, makedns returns 0, named logs the zone update, the stanza reads hmac-sha256 with the same secret, and the record resolves.
