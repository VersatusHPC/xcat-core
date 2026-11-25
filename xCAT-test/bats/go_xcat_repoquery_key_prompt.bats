#!/usr/bin/env bats
#
# go-xcat adds xcat-dep-common with repo_gpgcheck=1. Until its key is imported, dnf asks
# "Is this ok [y/N]: " on stdout, without a newline, before the query result. go-xcat reads
# that stdout as package names, so the repository queries must not leave the prompt open.

load 'helpers/go_xcat'

setup()
{
    GO_XCAT_SOURCE=${XCAT_TEST_GO_XCAT:-$(go_xcat_default_source)}
    [ -r "$GO_XCAT_SOURCE" ] || { echo "Required go-xcat is unreadable: $GO_XCAT_SOURCE" >&2; return 1; }
    export CALLS="${BATS_TEST_TMPDIR:?bats-core 1.4 or newer is required}/calls"
    export GO_XCAT_ARCH=x86_64
    export GO_XCAT_LINUX_DISTRO=almalinux
    export GO_XCAT_LINUX_VERSION=10.1
}

load_go_xcat_with_unimported_key()
{
    rm -f "$CALLS"
    source "$GO_XCAT_SOURCE" || return

    # dnf with one repository whose key is not imported yet: it asks before it answers,
    # unless the command line already says yes. The query result follows on the same line.
    dnf()
    {
        echo "dnf $*" >>"$CALLS"
        local arg assume=0
        for arg in "$@"; do
            [[ $arg == -y || $arg == --assumeyes ]] && assume=1
        done
        [[ " $* " == *" repoquery "* ]] || return 0
        [[ $assume == 1 ]] || printf 'Is this ok [y/N]: '
        case "$*" in
            *--repoid=xcat-dep*) printf '%s\n' xnba-undi elilo-xcat ;;
            *"%{version}-%{release}"*) printf '%s\n' 'xCAT 2.21.0-snap202611240000' 'perl-xCAT 2.21.0-snap202611240000' ;;
            *) printf '%s\n' "${@: -1}" ;;
        esac
    }
    yum() { dnf "$@"; }
}

@test "the EPEL and CRB check finds EPEL while the xcat-dep-common key is not imported" {
    load_go_xcat_with_unimported_key
    run el_epel_and_crb_check dnf
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [[ "$output" != *'requires EPEL repository'* ]]
}

@test "the yum path of the EPEL and CRB check finds EPEL too" {
    load_go_xcat_with_unimported_key
    run el_epel_and_crb_check yum
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "the package list of a repository holds package names only" {
    load_go_xcat_with_unimported_key
    run get_package_list_dnf xcat-dep
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' xnba-undi elilo-xcat)" ]
}

@test "the repository version table finds every package it asks for" {
    load_go_xcat_with_unimported_key
    run check_repo_version_dnf xCAT perl-xCAT
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' 2.21.0-snap202611240000 2.21.0-snap202611240000)" ]
}
