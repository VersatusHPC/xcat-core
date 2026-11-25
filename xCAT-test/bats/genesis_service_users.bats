#!/usr/bin/env bats
#
# The Genesis image must carry a passwd entry for each user its daemons run as.
#
# chronyd on Debian runs as _chrony and exits with "Could not get user/group ID of _chrony"
# when the image has no such entry, so an Ubuntu Genesis node has no time sync. dhcpcd on EL10
# drops privilege to the dhcpcd user and runs unsandboxed when the entry is absent. The user
# names differ by family, so the entries come from the build root, not from a fixed list.
#
# The test runs the module's install() against a fake build root and reads the image tree it
# writes.

load 'helpers/shell_source'

SYSROOT_PASSWD='root:x:0:0:root:/root:/bin/bash
_chrony:x:105:109:Chrony daemon,,,:/var/lib/chrony:/usr/sbin/nologin
dhcpcd:x:991:989:Minimalistic DHCP client:/var/lib/dhcpcd:/usr/sbin/nologin
sshd:x:74:74:Privilege-separated SSH:/usr/share/empty.sshd:/usr/sbin/nologin
nobody:x:65534:65534:Kernel Overflow User:/:/usr/sbin/nologin'

SYSROOT_GROUP='root:x:0:
_chrony:x:109:
dhcpcd:x:989:
sshd:x:74:
nobody:x:65534:'

# Run install() with every dracut helper replaced by a no-op, against the fake build root.
run_install()
{
    local module="$1"
    sysroot="${BATS_TEST_TMPDIR}/sysroot"
    image="${BATS_TEST_TMPDIR}/image"
    mkdir -p "$sysroot/etc" "$image/etc"
    printf '%s\n' "$SYSROOT_PASSWD" >"$sysroot/etc/passwd"
    printf '%s\n' "$SYSROOT_GROUP" >"$sysroot/etc/group"
    # dracut 99base writes root before the module runs on some releases.
    printf 'root::0:0::/root:/bin/sh\n' >"$image/etc/passwd"
    (
        for helper in dracut_install inst inst_simple inst_multiple inst_binary inst_script \
                      inst_symlink inst_dir inst_hook inst_rules instmods dfatal; do
            eval "$helper() { return 0; }"
        done
        command_not_found_handle() { return 0; }
        moddir="${BATS_TEST_TMPDIR}"; hostonly=''; srcmods=''
        initdir="$image"; dracutsysrootdir="$sysroot"
        . "$module" >/dev/null 2>&1 || true
        install >/dev/null 2>&1 || true
    )
}

assert_service_user()
{
    local name="$1" gid="$2" home="$3"
    [ "$(grep -c "^$name:" "$image/etc/passwd")" -eq 1 ]
    grep -q "^[^:]*:[^:]*:$gid:" "$image/etc/group"
    [ -d "$image$home" ]
}

@test "the ubuntu module gives the image the _chrony user of its build root" {
    run_install "$(require_repo_file 'xCAT-genesis-base/dracut_105/ubuntu/module-setup.sh')"
    assert_service_user _chrony 109 /var/lib/chrony
    assert_service_user sshd 74 /usr/share/empty.sshd
}

@test "the el module gives the image the dhcpcd and chrony users of its build root" {
    SYSROOT_PASSWD="${SYSROOT_PASSWD//_chrony:x:105:109:Chrony daemon,,,/chrony:x:995:991:chrony system user}"
    SYSROOT_GROUP="${SYSROOT_GROUP//_chrony:x:109:/chrony:x:991:}"
    run_install "$(require_repo_file 'xCAT-genesis-base/dracut_105/el/module-setup.sh')"
    assert_service_user chrony 991 /var/lib/chrony
    assert_service_user dhcpcd 989 /var/lib/dhcpcd
}

@test "a user the build root does not define is not invented, and root is kept" {
    run_install "$(require_repo_file 'xCAT-genesis-base/dracut_105/el/module-setup.sh')"
    ! grep -q '^chrony:' "$image/etc/passwd"
    ! grep -q '^rpcuser:' "$image/etc/passwd"
    [ "$(grep -c '^root:' "$image/etc/passwd")" -eq 1 ]
}
