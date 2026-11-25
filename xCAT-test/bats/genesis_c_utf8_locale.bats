#!/usr/bin/env bats
#
# Genesis exports LC_ALL=C.UTF-8. glibc accepts that locale only when every category loads,
# and LC_MESSAGES is a directory that holds SYS_LC_MESSAGES. An image without that file
# prints "setlocale: LC_ALL: cannot change locale (C.UTF-8)" from every bash it starts.
#
# The test runs the module's install() against a fake build root and reads the paths it asks
# dracut to install.

load 'helpers/shell_source'

record_install()
{
    local module="$1"
    sysroot="${BATS_TEST_TMPDIR}/sysroot"
    log="${BATS_TEST_TMPDIR}/install.log"
    locale="$sysroot/usr/lib/locale/C.utf8"
    mkdir -p "$locale/LC_MESSAGES" "$sysroot/etc"
    printf 'ctype' >"$locale/LC_CTYPE"
    printf 'time' >"$locale/LC_TIME"
    printf 'messages' >"$locale/LC_MESSAGES/SYS_LC_MESSAGES"
    : >"$log"
    (
        for helper in dracut_install inst inst_simple inst_multiple inst_binary inst_script \
                      inst_symlink inst_dir inst_hook inst_rules instmods; do
            eval "$helper() { printf '%s\n' \"\$@\" >>'$log'; return 0; }"
        done
        command_not_found_handle() { return 0; }
        dfatal() { return 0; }
        moddir="${BATS_TEST_TMPDIR}"; hostonly=''; srcmods=''
        initdir="${BATS_TEST_TMPDIR}/image"; dracutsysrootdir="$sysroot"
        mkdir -p "$initdir/etc"
        . "$module" >/dev/null 2>&1 || true
        install >/dev/null 2>&1 || true
    )
}

assert_locale_installed()
{
    grep -qx '/usr/lib/locale/C.utf8/LC_CTYPE' "$log"
    grep -qx '/usr/lib/locale/C.utf8/LC_TIME' "$log"
    grep -qx '/usr/lib/locale/C.utf8/LC_MESSAGES/SYS_LC_MESSAGES' "$log"
}

@test "the el module installs every file of the C.utf8 locale, LC_MESSAGES included" {
    [ ! -e /etc/openEuler-release ] || skip "the openEuler branch of install() reads the host locale"
    record_install "$(require_repo_file 'xCAT-genesis-base/dracut_105/el/module-setup.sh')"
    assert_locale_installed
}

@test "the ubuntu module installs every file of the C.utf8 locale, LC_MESSAGES included" {
    record_install "$(require_repo_file 'xCAT-genesis-base/dracut_105/ubuntu/module-setup.sh')"
    assert_locale_installed
}
