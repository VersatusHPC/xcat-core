#!/usr/bin/env bats
# confighostbasedauth installs the files mkhostbased-auth rendered and turns
# host-based login on in sshd and ssh. Each test runs in a scratch /etc/ssh.

bats_require_minimum_version 1.5.0

load 'helpers/shell_source'

setup()
{
    SCRIPT="$(require_repo_file 'xCAT/postscripts/confighostbasedauth')"
    ETC="${BATS_TEST_TMPDIR}/etc/ssh"
    SRC="${BATS_TEST_TMPDIR}/hostbased"
    EVENTS="${BATS_TEST_TMPDIR}/events.log"
    mkdir -p "$ETC/sshd_config.d" "$ETC/ssh_config.d" "$SRC/zA"
    printf 'Include %s/sshd_config.d/*.conf\nPermitRootLogin yes\n' "$ETC" >"$ETC/sshd_config"
    printf 'Include %s/ssh_config.d/*.conf\nHost *\n' "$ETC" >"$ETC/ssh_config"
    echo 'cn1,10.0.0.10 ssh-rsa AAAA' >"$SRC/zA/ssh_known_hosts"
    printf 'cn1\n10.0.0.10\n' >"$SRC/zA/shosts.equiv"
    KEYSIGN="${BATS_TEST_TMPDIR}/ssh-keysign"
    printf '#!/bin/sh\n' >"$KEYSIGN"
    chmod +x "$KEYSIGN"
    export XCAT_SSH_ETC="$ETC" XCAT_HBA_SRC="$SRC" XCAT_LOGGER=true XCAT_HBA_KEYSIGN="$KEYSIGN"
    export EVENTS
}

# systemctl and dnf are shadowed by shell functions, so nothing on the host
# is restarted or installed.
run_script()
{
    systemctl() { echo "systemctl $*" >>"$EVENTS"; return 0; }
    dnf() { echo "dnf $*" >>"$EVENTS"; return 0; }
    restorecon() { return 0; }
    XCAT_HBA_SOURCED=1
    . "$SCRIPT"
    hba_main "$@"
}

@test "a scope installs both files and turns host-based login on" {
    run run_script zA
    [ "$status" -eq 0 ]
    [ "$(sed -n 2p "$ETC/ssh_known_hosts")" = 'cn1,10.0.0.10 ssh-rsa AAAA' ]
    [ "$(sed -n '2,$p' "$ETC/shosts.equiv")" = $'cn1\n10.0.0.10' ]
    [ "$(sed -n '2,$p' "$ETC/sshd_config.d/05-xcat-hostbased.conf")" = 'HostbasedAuthentication yes' ]
    [ "$(sed -n '2,$p' "$ETC/ssh_config.d/05-xcat-hostbased.conf")" = $'HostbasedAuthentication yes\nEnableSSHKeysign yes' ]
    grep -qx 'systemctl restart sshd.service' "$EVENTS"
}

@test "without an Include line the options go ahead of the existing ones" {
    printf 'PermitRootLogin yes\n' >"$ETC/sshd_config"
    run run_script zA
    [ "$status" -eq 0 ]
    [ "$(sed -n 2p "$ETC/sshd_config")" = 'HostbasedAuthentication yes' ]
    [ "$(tail -n 1 "$ETC/sshd_config")" = 'PermitRootLogin yes' ]
    run run_script zA
    [ "$(grep -c '^HostbasedAuthentication yes$' "$ETC/sshd_config")" -eq 1 ]
}

@test "-r removes what xCAT wrote and restores the original known_hosts" {
    echo 'other ssh-rsa BBBB' >"$ETC/ssh_known_hosts"
    run run_script zA
    [ "$status" -eq 0 ]
    run run_script -r
    [ "$status" -eq 0 ]
    [ ! -e "$ETC/sshd_config.d/05-xcat-hostbased.conf" ]
    [ ! -e "$ETC/ssh_config.d/05-xcat-hostbased.conf" ]
    [ ! -e "$ETC/shosts.equiv" ]
    [ "$(cat "$ETC/ssh_known_hosts")" = 'other ssh-rsa BBBB' ]
}

@test "a missing ssh-keysign is installed from openssh-keysign" {
    export XCAT_HBA_KEYSIGN="${BATS_TEST_TMPDIR}/absent"
    run run_script zA
    [ "$status" -eq 1 ]
    grep -qx 'dnf install -y openssh-keysign' "$EVENTS"
    [ ! -e "$ETC/shosts.equiv" ]
}

@test "an unknown scope fails and changes nothing" {
    run run_script zB
    [ "$status" -eq 1 ]
    [ ! -e "$ETC/sshd_config.d/05-xcat-hostbased.conf" ]
    run run_script ../zA
    [ "$status" -eq 2 ]
}
