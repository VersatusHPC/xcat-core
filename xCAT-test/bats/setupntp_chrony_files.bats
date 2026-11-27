#!/usr/bin/env bats
#
# setupntp writes chrony.conf. A keyfile or leapsectz directive that names an absent file makes
# chronyd log "Could not open keyfile /etc/chrony.keys" (EL 10 ships no key file) or "Timezone
# right/UTC failed leap second check" (Ubuntu 24.04 and later move right/ to tzdata-legacy).

load 'helpers/shell_source'

setup()
{
    SCRIPT="$(require_repo_file 'xCAT/postscripts/setupntp')"
    SETUPNTP_LIB=1 . "$SCRIPT"
}

@test "a key file that exists is named" {
    : >"${BATS_TEST_TMPDIR}/chrony.keys"
    run chrony_file_directive keyfile "${BATS_TEST_TMPDIR}/chrony.keys"
    [ "$status" -eq 0 ]
    [ "$output" = "keyfile ${BATS_TEST_TMPDIR}/chrony.keys" ]
}

@test "an absent key file is not named" {
    run chrony_file_directive keyfile "${BATS_TEST_TMPDIR}/absent.keys"
    [ "$output" = "" ]
}

@test "leapsectz names the zone when its file exists" {
    : >"${BATS_TEST_TMPDIR}/UTC"
    run chrony_file_directive leapsectz "${BATS_TEST_TMPDIR}/UTC" right/UTC
    [ "$output" = "leapsectz right/UTC" ]
}

@test "leapsectz is left out when the zone file is absent" {
    run chrony_file_directive leapsectz "${BATS_TEST_TMPDIR}/absent/UTC" right/UTC
    [ "$output" = "" ]
}
