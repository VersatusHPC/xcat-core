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

# xcat_x86_present_net_modules keeps the drivers of the devices under a sysfs bus directory.
# modprobe -R is stubbed: it maps a device alias to the driver that the alias names.
present_net_modules()
{
    local body
    body="$(extract_shell_function "$1" xcat_x86_net_modules)" || return 99
    body+=$'\n'"$(extract_shell_function "$1" xcat_x86_present_net_modules)" ||
        { echo "xcat_x86_present_net_modules() not found in $1" >&2; return 99; }
    (
        modprobe() {
            [ "$1" = -R ] || return 1
            case "$2" in
            virtio:d00000001v*) echo virtio_net ;;
            pci:v00008086d000010D3*) echo e1000e ;;
            pci:v0000104Cd0000500*) echo tlan ;;
            esac
        }
        eval "$body"
        xcat_x86_present_net_modules "$MODULES_DEP" "$BUS"
    )
}

add_device()
{
    mkdir -p "$BUS/$1/devices/$2"
    printf '%s\n' "$3" >"$BUS/$1/devices/$2/modalias"
}

setup_bus()
{
    BUS="$BATS_TEST_TMPDIR/bus"
    mkdir -p "$BUS"
    printf '%s\n' 'kernel/drivers/net/ethernet/ti/tlan.ko.xz:' \
        'kernel/drivers/net/ethernet/3com/3c509.ko.xz:' >>"$MODULES_DEP"
}

@test "a driver with no device of this host is not loaded" {
    setup_bus
    add_device virtio virtio0 'virtio:d00000001v00001AF4'
    for hook in "$EL_HOOK" "$UBUNTU_HOOK"; do
        run present_net_modules "$hook"
        [ "$status" -eq 0 ]
        [ "$output" = "virtio_net" ]
    done
}

@test "the driver of every present NIC is loaded" {
    setup_bus
    add_device virtio virtio0 'virtio:d00000001v00001AF4'
    add_device pci 0000:00:03.0 'pci:v00008086d000010D3sv00008086sd0000A01Fbc02sc00i00'
    for hook in "$EL_HOOK" "$UBUNTU_HOOK"; do
        run present_net_modules "$hook"
        [ "$output" = "$(printf 'e1000e\nvirtio_net')" ]
    done
}

@test "no device loads no driver" {
    setup_bus
    for hook in "$EL_HOOK" "$UBUNTU_HOOK"; do
        run present_net_modules "$hook"
        [ "$status" -eq 0 ]
        [ "$output" = "" ]
    done
}
