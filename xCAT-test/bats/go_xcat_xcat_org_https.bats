#!/usr/bin/env bats
#
# xcat.org answers http:// with a 301 to https://. curl without -L saves the redirect page and
# exits 0, so go-xcat read an HTML page as the apt key. go-xcat must reach xcat.org over HTTPS
# and follow a redirect in a URL that a user gives.

load 'helpers/go_xcat'

setup()
{
    [ "$(uname -s)" = Linux ] || skip 'repository checks require Linux namespaces'
    command -v bwrap >/dev/null || skip 'bwrap is required'
    go_xcat_require_source
    [ -n "$BATS_TEST_TMPDIR" ] || return 1
    fixture="$BATS_TEST_TMPDIR/fixture"
    mkdir -p "$fixture/etc/apt/sources.list.d" "$fixture/tmp"
    # One armored block that holds a public key packet (0x99), as xcat.org publishes.
    printf '\231\000\002ab' >"$fixture/keyring.gpg"
    {
        printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n'
        base64 <"$fixture/keyring.gpg"
        printf '=AAAA\n-----END PGP PUBLIC KEY BLOCK-----\n'
    } >"$fixture/apt.key"
    export FIXTURE=/tmp/fixture
}

# curl against xcat.org: http:// is a 301 page unless -L follows it, a missing
# file is a 404 page unless -f fails it, and https://.../apt.key is the key.
curl()
{
    local out="" url="" follow=0 fail=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o) out="$2"; shift ;;
            -A) shift ;;
            -*) [[ "$1" == -*L* ]] && follow=1; [[ "$1" == -*f* ]] && fail=1 ;;
            *) url="$1" ;;
        esac
        shift
    done
    printf '%s\n' "$url" >>"$FIXTURE/curl.log"
    if [[ "$url" == http://xcat.org/* ]]; then
        if [ "$follow" = 0 ]; then
            printf '<html><head><title>301 Moved Permanently</title></head></html>\n' >"$out"
            return 0
        fi
        url="https://${url#http://}"
    fi
    if [[ "$url" == https://xcat.org/files/xcat/repos/apt/apt.key ]]; then
        cp "$FIXTURE/apt.key" "$out"
        return 0
    fi
    [ "$fail" = 1 ] && return 22
    printf '<html><head><title>404 Not Found</title></head></html>\n' >"$out"
}

# Run go-xcat with a private /etc that has an apt sources directory, so the apt code path is
# chosen on any host. Repository files are recorded, not written.
apt_default_channel()
{
    source /tmp/go-xcat || exit 70
    TMP_DIR=/tmp/fixture/tmp
    GO_XCAT_APT_KEY_FILE=/tmp/fixture/xcat.gpg
    add_repo_by_url_apt() { printf '%s %s\n' "$2" "$1" >>/tmp/fixture/repos.log; }
    add_xcat_core_repo_apt "" "$1" && add_xcat_dep_repo_apt "" "$1"
}

run_in_fixture()
{
    local -a alternatives=()
    [ -d /etc/alternatives ] && alternatives=(--ro-bind /etc/alternatives /etc/alternatives)
    export -f curl apt_default_channel
    bwrap --die-with-parent --unshare-net --ro-bind / / --dev /dev --proc /proc \
        --tmpfs /tmp --ro-bind "$GO_XCAT_SOURCE" /tmp/go-xcat \
        --bind "$fixture" /tmp/fixture --bind "$fixture/etc" /etc "${alternatives[@]}" \
        bash -c '"$@"' bash "$@"
}

@test "the default apt channels import the xCAT key and use HTTPS repositories" {
    for ver in devel latest; do
        rm -f "$fixture/xcat.gpg" "$fixture/repos.log"
        run run_in_fixture apt_default_channel "$ver"
        [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
        cmp "$fixture/keyring.gpg" "$fixture/xcat.gpg"
        [[ "$(cat "$fixture/repos.log")" != *http://* ]]
        grep -qx "xcat-dep https://xcat.org/files/xcat/repos/apt/$ver/xcat-dep" "$fixture/repos.log"
    done
}

@test "a download from an http:// URL that redirects saves the target, not the redirect page" {
    source "$GO_XCAT_SOURCE"
    TMP_DIR="$fixture/tmp"
    FIXTURE="$fixture"
    run download_file_curl http://xcat.org/files/xcat/repos/apt/apt.key "$fixture/got.key"
    [ "$status" -eq 0 ]
    cmp "$fixture/apt.key" "$fixture/got.key"
}

@test "a download of a missing file fails instead of saving the error page" {
    source "$GO_XCAT_SOURCE"
    TMP_DIR="$fixture/tmp"
    FIXTURE="$fixture"
    run download_file_curl https://xcat.org/files/xcat/repos/apt/missing.key "$fixture/got.key"
    [ "$status" -ne 0 ]
}

@test "the default yum channels use HTTPS repositories" {
    source "$GO_XCAT_SOURCE"
    GO_XCAT_LINUX_DISTRO=almalinux
    GO_XCAT_ARCH=x86_64
    dnf() { :; }
    add_repo_by_url_yum_or_zypper() { printf '%s %s\n' "$2" "$1" >>"$fixture/repos.log"; }
    add_xcat_core_repo_yum_or_zypper "" devel
    add_xcat_core_repo_yum_or_zypper "" latest
    [ "$(cat "$fixture/repos.log")" = "$(printf '%s\n' \
        'xcat-core https://xcat.org/files/xcat/repos/yum/devel/core-snap' \
        'xcat-core https://xcat.org/files/xcat/repos/yum/latest/xcat-core')" ]
}
