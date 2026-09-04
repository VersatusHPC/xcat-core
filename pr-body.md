fix(xcat-core): nodeset reports success for a node yaboot could not configure

nodeset returns 0 for a node the yaboot plugin could not configure. On an EL9 management node,
a node whose name does not resolve gets a warning, no boot loader entry, and exit code 0. The
xnba, grub2 and petitboot plugins each return an error in the same situation, so a user who
reads the exit code learns nothing about a node that will not boot.

setstate in xCAT-server/lib/xcat/plugins/yaboot.pm returns bare on every failure, so the caller
reads an empty rc and sends no error. process_request keeps no record of the nodes that failed,
and it sends the message setstate returned under the key errorc, which no client reads.

setstate now returns (1, message) on failure and (0, "") on success, the shape petitboot uses.
process_request records each failed node and answers with "Failed to generate yaboot
configurations for some node(s)", the message the three sibling plugins already send.

xCAT-test/unit/yaboot_unresolvable_node.t extracts setstate, pass_along and process_request and
runs them in a scratch package, because yaboot.pm needs a management node to load. It drives one
nodeset request for a node whose address does not resolve. Six of its eight assertions fail on
the test commit.

Commits: 3b646679f test, f2b40dc0c fix
LANDING ORDER: land together with 4a888f12a on fix/xcat-test-cases, which supplies the xcatmaster precondition nodeset_yaboot needs. Either alone leaves the case red.
