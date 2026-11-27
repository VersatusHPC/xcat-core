#!/usr/bin/env bats
#
# The kickstart %post of an EL node writes the FIPS state of the installer kernel to
# /var/log/xcat/xcat.log. Anaconda installs the node in FIPS mode only when the installer
# itself runs with fips=1, so that line tells an operator which mode the install ran in.

load 'helpers/shell_source'

setup()
{
    SCRIPT_LIB="$(require_repo_file 'xCAT-server/share/xcat/install/scripts/scriptlib')"
    export SCRIPT_LIB
}

fips_state_of()
{
    # shellcheck disable=SC1090
    source "$SCRIPT_LIB"
    xcat_fips_state "$1"
}

@test "an installer in FIPS mode is reported as fips_enabled=1" {
    printf '1\n' >"$BATS_TEST_TMPDIR/fips_enabled"
    run fips_state_of "$BATS_TEST_TMPDIR/fips_enabled"
    [ "$status" -eq 0 ]
    [ "$output" = 'fips_enabled=1' ]
}

@test "an installer not in FIPS mode is reported as fips_enabled=0" {
    printf '0\n' >"$BATS_TEST_TMPDIR/fips_enabled"
    run fips_state_of "$BATS_TEST_TMPDIR/fips_enabled"
    [ "$status" -eq 0 ]
    [ "$output" = 'fips_enabled=0' ]
}

@test "a kernel without the FIPS file is reported as unknown, not as 0" {
    run fips_state_of "$BATS_TEST_TMPDIR/absent"
    [ "$status" -eq 0 ]
    [ "$output" = "fips_enabled=unknown: cannot read $BATS_TEST_TMPDIR/absent" ]
}
