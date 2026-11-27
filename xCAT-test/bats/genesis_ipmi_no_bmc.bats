#!/usr/bin/env bats
#
# doxcat loads ipmi_si to find an in-band BMC, then asks ipmitool whether one answers. On a
# node without a BMC the kernel refuses the module, and that refusal is the expected answer.

load 'helpers/doxcat_sandbox'

# modprobe refuses ipmi_si the way kmod does on a node without a BMC.
refuse_ipmi_si()
{
    cat >"$fixture/bin/modprobe" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>/run/fixture/modules
if [ "$1" = ipmi_si ]; then
    echo "modprobe: ERROR: could not insert 'ipmi_si': No such device" >&2
    exit 1
fi
SH
    chmod +x "$fixture/bin/modprobe"
}

@test "doxcat prints no modprobe error on a node without a BMC" {
    setup_doxcat
    refuse_ipmi_si
    add_doxcat_link eth0 BROADCAST,MULTICAST,UP ether aa:bb:cc:dd:ee:ff
    run_genesis 0 --setenv BOOTIF 01-aa-bb-cc-dd-ee-ff
    grep -Fxq ipmi_si "$fixture/modules"
    [[ "$output" != *"could not insert 'ipmi_si'"* ]]
}
