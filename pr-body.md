fix(ddns): xCAT signs DNS updates with hmac-md5, which a FIPS named rejects

makedns fails on a management node in FIPS mode when the site table names no OMAPI algorithm. named answers SERVFAIL to every dynamic update, and reports no error for the key stanza it loaded.

xCAT::DHCP::OmapiPolicy->normalize_algorithm returns hmac-md5 when no algorithm is configured. xcatconfig writes site.dhcpomapialgorithm only on a first install, so a re-run of xcatconfig and an upgrade both keep hmac-md5. update_namedconf in xCAT-server/lib/xcat/plugins/ddns.pm replaced a key stanza only for a site that named an algorithm, so a site that named none kept its md5 stanza and kept signing with it. Net::DNS signs hmac-md5 in pure Perl and not through libcrypto, so xCAT sends a valid signature and named refuses it.

normalize_algorithm now returns hmac-sha256, and update_namedconf replaces a key stanza that does not declare the algorithm makedns signs with. new_install_default_algorithm writes hmac-md5 into the site table for a platform whose omshell rejects the key-algorithm command. settings takes a deployed_algorithm, and makedhcp passes the algorithm the running dhcpd.conf declares, so an upgraded cluster keeps its OMAPI key until makedhcp -n writes a new stanza. A site that names hmac-md5 is unchanged. The branch also carries the two fixes of fix/ddns-tsig-algorithm-downgrade: the named.conf stanza rewrite and the two TSIG records on a retry.

xCAT-test/unit/ddns_tsig_default_algorithm.t drives normalize_algorithm, the makedhcp OMAPI policy and update_namedconf over a scratch named.conf, then signs one update. Six of its eight subtests fail before the fix commit.

Commits: 6076881 test, 7f24d32 fix, 174684e test, ea6bf93 fix, 0b82463 test, b7bd733 fix
