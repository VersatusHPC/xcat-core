#!/usr/bin/env bats
#
# The DHCP unit that dracut leaves in /run on an installed Ubuntu 26.04 node.
#
# Ubuntu 26.04 builds the initrd with dracut. When the command line asks for no network, its
# systemd-networkd module copies a unit that runs DHCP on every NIC to
# /run/systemd/network/zzzz-dracut-default.network. The installed system keeps /run after the
# switch to the root, so the NICs that xCAT marks *NOIP* ask the management node for an address at
# every boot. A late-command masks that unit with a link to /dev/null in /etc/systemd/network and
# rebuilds the initrd, so the mask applies in the initrd too. Ubuntu 22.04 and 24.04 build the
# initrd with initramfs-tools and have no such module.
#
# The late-command is shell, so this is a bats test: it runs the command with /target moved into
# the test tree and curtin replaced by a function that records its arguments.

load 'helpers/shell_source'

UNIT='zzzz-dracut-default.network'
MODULE='usr/lib/dracut/modules.d/11systemd-networkd/networkd-config.sh'

setup()
{
    TARGET="${BATS_TEST_TMPDIR}/target"
    CURTIN_LOG="${BATS_TEST_TMPDIR}/curtin.log"
    mkdir -p "$TARGET"
}

# The late-command item of one template that masks the dracut DHCP unit.
late_command()
{
    local tmpl line
    tmpl="$(require_repo_file "xCAT-server/share/xcat/install/ubuntu/$1.subiquity.tmpl")"
    line="$(extract_first_matching_line "$tmpl" "^    - '.*$UNIT")" || return 1
    line="${line#    - \'}"
    line="${line%\'}"
    printf '%s\n' "$line"
}

run_late_command()
{
    local cmd
    cmd="$(late_command "$1")" || { echo "no late-command in $1.subiquity.tmpl masks $UNIT"; return 1; }
    cmd="${cmd//\/target/$TARGET}"
    bash -c "curtin() { printf '%s\n' \"\$*\" >>'$CURTIN_LOG'; }
set -e
$cmd"
}

# A target with the dracut networkd module, as Ubuntu 26.04 installs it.
dracut_target()
{
    mkdir -p "$TARGET/$(dirname "$MODULE")"
    printf '%s\n' "    cp -a /usr/lib/dracut/dracut-default.network /run/systemd/network/$UNIT" >"$TARGET/$MODULE"
}

@test "a dracut target masks the DHCP unit of the initrd" {
    for kind in compute service; do
        rm -rf "$TARGET" "$CURTIN_LOG"; mkdir -p "$TARGET"
        dracut_target
        run_late_command "$kind"
        [ "$(readlink "$TARGET/etc/systemd/network/$UNIT")" = '/dev/null' ]
    done
}

@test "the initrd is rebuilt in the target after the mask is written" {
    dracut_target
    run_late_command compute
    grep -qx -- "in-target --target $TARGET -- dracut --force --regenerate-all" "$CURTIN_LOG"
}

@test "a target without the dracut networkd module is left alone" {
    run_late_command compute
    [ ! -e "$TARGET/etc/systemd/network" ]
    [ ! -e "$CURTIN_LOG" ]
}
