#!/usr/bin/env bats
#
# grep 3.8 made egrep a wrapper that prints "egrep: warning: egrep is obsolescent" on every
# call. xcatroot runs it twice per line of "ip link show", so a diskless boot on openEuler
# 24.03 filled the console with the warning. The stateless initrd uses grep -E and carries
# no egrep.
#
# The test runs the module's install script with every dracut helper replaced by a recorder
# and reads the programs it asks dracut to install.

load 'helpers/shell_source'

record_install()
{
    local script="$1"
    log="${BATS_TEST_TMPDIR}/install.log"
    : >"$log"
    (
        for helper in dracut_install inst inst_simple inst_multiple inst_binary inst_script \
                      inst_symlink inst_dir inst_hook inst_rules instmods; do
            eval "$helper() { printf '%s\n' \"\$@\" >>'$log'; return 0; }"
        done
        command_not_found_handle() { return 0; }
        moddir="${BATS_TEST_TMPDIR}"; drivers=''
        . "$script" >/dev/null 2>&1 || true
    )
}

@test "the dracut_047 stateless initrd installs grep and no egrep" {
    record_install "$(require_repo_file 'xCAT-server/share/xcat/netboot/rh/dracut_047/install.netboot')"
    grep -qx 'grep' "$log"
    ! grep -qx 'egrep' "$log"
}

@test "the dracut_033 stateless initrd installs grep and no egrep" {
    record_install "$(require_repo_file 'xCAT-server/share/xcat/netboot/rh/dracut_033/install.netboot')"
    grep -qx 'grep' "$log"
    ! grep -qx 'egrep' "$log"
}
