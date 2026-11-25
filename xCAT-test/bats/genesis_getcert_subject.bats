#!/usr/bin/env bats
#
# The subject of the certificate request that legacy Genesis sends.
#
# credentials.pm signs a request only when its subject is CN=<node>. When getcert runs, the
# Genesis hostname is still "(none)" or the FQDN, so a subject built from the hostname never
# matches and the node runs with no /etc/xcat/cert.pem.

load 'helpers/shell_source'

setup()
{
    GETCERT="$(require_repo_file 'xCAT-genesis-scripts/usr/bin/getcert')"
    SUBJECT="${BATS_TEST_TMPDIR}/subject"
    export GETCERT SUBJECT
}

write_stub()
{
    local dir="$1" name="$2" body="$3"
    printf '#!/bin/sh\n%s\n' "$body" >"$dir/$name"
    chmod 0755 "$dir/$name"
}

# A PATH directory holding the commands getcert runs. openssl req records its -subj value and
# fails, so getcert gives up before it writes the request files under /tmp.
# getdestiny writes the metadata file the way the real one does, or fails when no name is given.
stub_dir()
{
    local hostname="$1" node="$2"
    local dir="${BATS_TEST_TMPDIR}/bin"

    rm -rf "$dir"
    mkdir -p "$dir"
    write_stub "$dir" allowcred.awk 'exec sleep 3'
    write_stub "$dir" hostname "echo '$hostname'"
    write_stub "$dir" logger 'echo "$@" >&2'
    write_stub "$dir" sleep 'exec /bin/sleep "$@"'
    write_stub "$dir" sed 'exec /bin/sed "$@"'
    write_stub "$dir" rm 'exec /bin/rm "$@"'
    write_stub "$dir" mktemp 'exec /bin/mktemp "$@"'
    write_stub "$dir" openssl "
if [ \"\$1\" = req ]; then
    while [ \$# -gt 0 ]; do
        [ \"\$1\" = -subj ] && printf '%s\n' \"\$2\" >'$SUBJECT'
        shift
    done
    exit 1
fi
exit 0"
    if [ -n "$node" ]; then
        write_stub "$dir" getdestiny "
while [ \$# -gt 0 ]; do
    [ \"\$1\" = --metadata ] && printf 'XCAT_NODE_NAME=%s\nXCAT_DESTINY=shell\n' '$node' >\"\$2\"
    shift
done
echo shell"
    else
        write_stub "$dir" getdestiny 'exit 1'
    fi
    printf '%s\n' "$dir"
}

run_getcert()
{
    local bin="$1"
    timeout -k 2 20 env PATH="$bin" TMPDIR="$BATS_TEST_TMPDIR" GETCERT_CSR_TIMEOUT=0 \
        /bin/bash "$GETCERT" 192.0.2.1:3001 >/dev/null 2>&1 </dev/null
    [ -s "$SUBJECT" ]
}

@test "getcert names the node xcatd reports, not the Genesis hostname" {
    run_getcert "$(stub_dir '(none)' cn1)"
    [ "$(cat "$SUBJECT")" = /CN=cn1 ]
}

@test "with no answer from xcatd, getcert names the short hostname" {
    run_getcert "$(stub_dir cn1.cluster.lab '')"
    [ "$(cat "$SUBJECT")" = /CN=cn1 ]
}
