#!/usr/bin/env bats
#
# Run each diskless postinstall script that writes the image fstab, in a sandbox, and read the
# fstab it writes. fsck checks block devices only: an entry for tmpfs, proc, sysfs, devpts or
# NFS with a non-zero pass makes systemd-fstab-generator log "Checking was requested for ...,
# but it is not a device" at each boot of the node.

load helpers/script_sandbox

setup()
{
    setup_script_sandbox cat chmod grep mkdir sed
}

# Print each postinstall script that writes $installroot/etc/fstab, once per real file.
fstab_postinstalls()
{
    local dir file
    for dir in xCAT-server/share/xcat/netboot xCAT-IBMhpc/share/xcat/IBMhpc; do
        for file in "$(repo_path "$dir")"/*/*.postinstall "$(repo_path "$dir")"/*.postinstall; do
            [ -f "$file" ] || continue
            grep -Eq '^[^#]*>[[:space:]]*"?\$installroot/etc/fstab' "$file" || continue
            readlink -f "$file"
        done
    done | sort -u
}

@test "diskless postinstall scripts write no fsck pass for network and pseudo file systems" {
    local scripts script name fstab bad count=0
    scripts=$(fstab_postinstalls)
    [ -n "$scripts" ]

    for script in $scripts; do
        name=${script#"$(readlink -f "$(repo_root)")"/}
        rm -rf "$fixture/tmp/root"
        mkdir -p "$fixture/tmp/root/etc"
        cp "$script" "$fixture/tmp/postinstall"
        run "${sandbox[@]}" /bin/sh /tmp/postinstall /tmp/root rhels9 x86_64 compute /tmp
        fstab="$fixture/tmp/root/etc/fstab"
        [ -s "$fstab" ] || { echo "$name wrote no fstab: $output"; return 1; }
        bad=$(awk '$1 !~ /^#/ && NF >= 6 && $3 ~ /^(tmpfs|proc|sysfs|devpts|nfs|nfs4)$/ && $6 != 0' "$fstab")
        [ -z "$bad" ] || { echo "$name: $bad"; return 1; }
        count=$((count + 1))
    done
    echo "checked $count scripts"
    [ "$count" -gt 0 ]
}

@test "the ubuntu diskless postinstall keeps the / entry that statelite marks read-only" {
    mkdir -p "$fixture/tmp/root/etc"
    cp "$(repo_path xCAT-server/share/xcat/netboot/ubuntu/compute.postinstall)" "$fixture/tmp/postinstall"
    run "${sandbox[@]}" /bin/sh /tmp/postinstall /tmp/root ubuntu24.04 x86_64 compute /tmp
    run awk '$2 == "/" { print $1, $3, $4 }' "$fixture/tmp/root/etc/fstab"
    [ "$output" = "compute_x86_64 tmpfs rw" ]
}
