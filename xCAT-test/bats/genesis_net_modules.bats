#!/usr/bin/env bats
#
# Drive xcat_x86_net_modules() out of the Genesis dracut cmdline hook. The hook cannot be
# sourced (see genesis_console_mode.bats), so the one function is extracted and run.

load 'helpers/shell_source'

setup()
{
    EL_HOOK="$(repo_path 'xCAT-genesis-base/dracut_105/el/xcat-cmdline.sh')"
    UBUNTU_HOOK="$(repo_path 'xCAT-genesis-base/dracut_105/ubuntu/xcat-cmdline.sh')"
    [ -r "$EL_HOOK" ]
    [ -r "$UBUNTU_HOOK" ]
    MODULES_DEP="$BATS_TEST_TMPDIR/modules.dep"
    printf '%s\n' \
        'kernel/drivers/net/ethernet/intel/e1000e/e1000e.ko.xz:' \
        'kernel/drivers/net/virtio_net.ko.xz: kernel/net/core/failover.ko.xz' \
        'kernel/drivers/net/xen-netfront.ko.xz:' \
        'kernel/drivers/net/bonding/bonding.ko.xz:' \
        'kernel/drivers/block/loop.ko.xz:' \
        >"$MODULES_DEP"
}

net_modules()
{
    local body
    body="$(extract_shell_function "$1" xcat_x86_net_modules)" ||
        { echo "xcat_x86_net_modules() not found in $1" >&2; return 99; }
    (
        eval "$body"
        xcat_x86_net_modules "$MODULES_DEP"
    )
}

assert_net_modules()
{
    run net_modules "$1"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'e1000e\nvirtio_net')" ]
}

@test "el: the driver loop leaves out xen-netfront, which the hook loads quietly" {
    assert_net_modules "$EL_HOOK"
}

@test "ubuntu: the driver loop leaves out xen-netfront, which the hook loads quietly" {
    assert_net_modules "$UBUNTU_HOOK"
}
