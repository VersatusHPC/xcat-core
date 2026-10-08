#!/usr/bin/env bats
#
# Run the EL10 aarch64 netboot postinstall over a scratch image root and read the SELinux
# config it writes. genimage gives the image root as $1, so every write stays under it.

load 'helpers/shell_source'

SCRIPT_PATH='xCAT-server/share/xcat/netboot/rh/compute.rhels10.aarch64.postinstall'

setup()
{
    SCRIPT="$(require_repo_file "$SCRIPT_PATH")"
    IMAGE_ROOT="${BATS_TEST_TMPDIR}/rootimg"
    CONFIG="${IMAGE_ROOT}/etc/selinux/config"
    mkdir -p "${IMAGE_ROOT}/etc/selinux" "${IMAGE_ROOT}/tmp"
}

# The stock EL config. The third comment line holds the word permissive, which an unanchored
# pattern matches.
write_config()
{
    cat >"$CONFIG" <<END
# SELINUX= can take one of these three values:
#     enforcing - SELinux security policy is enforced.
#     permissive - SELinux prints warnings instead of enforcing.
#     disabled - No SELinux policy is loaded.
SELINUX=$1
SELINUXTYPE=targeted
END
}

# The arguments genimage gives a postinstall script.
run_postinstall()
{
    bash "$SCRIPT" "$IMAGE_ROOT" 10 aarch64 compute "${BATS_TEST_TMPDIR}/workdir" 2>&1
}

@test "an enforcing config becomes SELINUX=disabled" {
    write_config enforcing
    run run_postinstall
    [ "$status" -eq 0 ]
    grep -qx 'SELINUX=disabled' "$CONFIG"
}

@test "a permissive config becomes SELINUX=disabled and not SELINUX=SELINUX=disabled" {
    write_config permissive
    run run_postinstall
    [ "$status" -eq 0 ]
    grep -qx 'SELINUX=disabled' "$CONFIG"
    refute_grep -q 'SELINUX=SELINUX=' "$CONFIG"
}

@test "the comment that names permissive keeps its text" {
    write_config enforcing
    run run_postinstall
    [ "$status" -eq 0 ]
    grep -qxF '#     permissive - SELinux prints warnings instead of enforcing.' "$CONFIG"
}

@test "a config that is already disabled keeps every line" {
    write_config disabled
    cp "$CONFIG" "${BATS_TEST_TMPDIR}/before"
    run run_postinstall
    [ "$status" -eq 0 ]
    diff -u "${BATS_TEST_TMPDIR}/before" "$CONFIG"
}

@test "an absent SELinux config does not fail the script" {
    rm -f "$CONFIG"
    run run_postinstall
    [ "$status" -eq 0 ]
    [ ! -e "$CONFIG" ]
    # sed names the file it cannot read, so this text appears only when the script runs the
    # substitution on an image that has no SELinux config.
    [[ "$output" != *"selinux/config"* ]]
}
