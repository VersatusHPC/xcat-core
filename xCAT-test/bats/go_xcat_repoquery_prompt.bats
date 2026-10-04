#!/usr/bin/env bats

load 'helpers/go_xcat'

# dnf asks to import a repository key on stdout and does not end the question with a newline,
# so the first record it prints afterwards continues the question's line. go-xcat compares a
# whole line against the package name, so the joined line hides the package.
setup()
{
    go_xcat_require_source
    export GO_XCAT_ARCH=x86_64
    export PKG_PRESENT=1
    KEY_IMPORT_PROMPT='Importing GPG key 0x8D818E69:
 Userid     : "xCAT Signing Key <xcat-build@xcat.org>"
 Fingerprint: 6390 CEB7 8544 C1AF 4FD7 2DCC 64C8 2A86 8D81 8E69
 From       : http://xcat.org/files/xcat/repos/yum/devel/core-snap/repodata/repomd.xml.key
Is this ok [y/N]: '
    export KEY_IMPORT_PROMPT
}

# A stand-in for "dnf repoquery" that expands the --qf the caller passes. Expanding the format
# is what makes this test sensitive to it, and the unterminated question goes first, as dnf
# writes it.
run_repo_carries()
{
    go_xcat_load_functions repo_carries

    EL_EPEL_TEST_RPM=perl-Crypt-CBC

    dnf()
    {
        local qf="" record
        local -a names=()
        while [ $# -gt 0 ]; do
            case "$1" in
                --qf|--queryformat) qf="$2"; shift 2 ;;
                --qf=*|--queryformat=*) qf="${1#*=}"; shift ;;
                --arch) shift 2 ;;
                repoquery|-*) shift ;;
                *) names+=("$1"); shift ;;
            esac
        done
        printf '%s' "$KEY_IMPORT_PROMPT"
        [ "$PKG_PRESENT" = 1 ] || return 0
        record="${qf//'%{name}'/${names[0]}}"
        printf '%s\n' "$record"
    }

    action=dnf
    repo_carries "$EL_EPEL_TEST_RPM"
}

@test "repo_carries reads the package name that follows an unterminated key-import question" {
    run run_repo_carries
    [ "$status" -eq 0 ]
}

@test "repo_carries still says no when the question is all the query prints" {
    export PKG_PRESENT=0

    run run_repo_carries
    [ "$status" -ne 0 ]
}
