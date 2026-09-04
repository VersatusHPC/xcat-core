fix(ddns): the DNS update failure message names no record

makedns reports a refused dynamic DNS update as "Failure encountered updating 100.100.100.IN-ADDR.ARPA. with entry '', error was FORMERR". The operator cannot see which record named refused, and the message is the same for every record of the zone.

add_or_delete_records in xCAT-server/lib/xcat/plugins/ddns.pm builds a batch of records in a foreach loop over the zone, then sends the last batch after the loop ends. It passes the foreach variable as the entry. Perl restores a foreach variable when the loop ends, so the entry is undefined at that call.

send_ddns_update now takes the records from the update it sends, through ddns_update_summary, and drops the entry parameter.

xCAT-test/unit/ddns_update_failure_names_records.t drives send_ddns_update against a resolver that answers FORMERR, and asserts that the failure message names the PTR record. It fails before the fix commit, where the message reports an empty entry.

Commits: 8ed2a47 test, 2bb053f fix
