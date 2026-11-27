#!/usr/bin/env bats
#
# makenamed.conf writes the DNSSEC lines of a service node named.conf from the bind version.
# bind 9.16 already reports "option 'dnssec-enable' is obsolete" at every load, and 9.18
# refuses the option. Validation stays off for 9.16.6 and later.

load 'helpers/shell_source'

setup()
{
    SCRIPT="$(require_repo_file 'xCAT-server/sbin/makenamed.conf')"
    MAKENAMED_LIB=1 . "$SCRIPT"
}

@test "bind 9.16.23 turns validation off without dnssec-enable" {
    run dnssec_options 9.16.23
    [ "$status" -eq 0 ]
    [ "$output" = "	dnssec-validation no;" ]
}

@test "bind 9.18 turns validation off" {
    run dnssec_options 9.18.28
    [ "$output" = "	dnssec-validation no;" ]
}

@test "bind 9.11 gets no DNSSEC line" {
    run dnssec_options 9.11.36
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "an unknown version gets no DNSSEC line" {
    run dnssec_options ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}
