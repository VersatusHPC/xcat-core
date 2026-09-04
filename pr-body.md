fix(ddns): makedns rewrites its own TSIG key and then fails against it

makedns exits 1 on a management node that runs Net::DNS below 1.36 and holds an hmac-sha256 key. It reports "Failure encountered updating <zone> with entry '', error was FORMERR". named rejects every dynamic update.

update_namedconf in xCAT-server/lib/xcat/plugins/ddns.pm rewrites the named.conf key stanza to hmac-md5 whenever Net::DNS is below 1.36, and ddns_tsig_algorithm returns hmac-md5 for the same reason. ddns_sign_update signs with site.dhcpomapialgorithm, which xcatconfig sets to hmac-sha256 on EL9 and later. named matches a TSIG key by name and by algorithm, so it answers NOTAUTH. send_ddns_update then signs the same packet again on each attempt. Net::DNS::Packet::sign_tsig appends the TSIG to the additional section, so the second attempt carries two TSIG records and named answers FORMERR. FORMERR is neither NOTAUTH nor SERVFAIL, so the retry loop stops.

The version test guarded the two-argument sign_tsig, which signs hmac-md5 only. This branch deletes the stanza rewrite and the version test, and signs with the algorithm the key stanza declares. OmapiPolicy->algorithm_rr_type maps that algorithm to its KEY RR number. ddns_update_request copies the prerequisite and update records into a new Net::DNS::Update, so each attempt signs a request of its own.

xCAT-test/unit/ddns_named_key_algorithm.t drives update_namedconf over a scratch named.conf and signs one update with the context of that run. xCAT-test/unit/ddns_update_retry.t drives send_ddns_update with a resolver that answers FORMERR to a message that carries more than one TSIG record. Both tests fail before their fix commit.

Commits: 5399c27 test, d2da944 fix, 6c56a66 test, 7b2042a fix
