#!/usr/bin/env bats
#
# restapi_ssl.sh cleanup removes mod_ssl on an EL management node and restarts httpd.
# mod_ssl ships httpd-init.service, and httpd.service has Wants=httpd-init.service. systemd keeps
# the removed unit loaded until a daemon-reload, so the restart starts httpd-init again and it
# fails on the deleted /usr/libexec/httpd-ssl-gencerts.

load helpers/script_sandbox

setup() {
    setup_script_sandbox cat cp mv rm sed tr
    mkdir -p "$fixture/etc/httpd/conf.d"
    printf 'ID="almalinux"\nID_LIKE="rhel centos fedora"\n' >"$fixture/etc/os-release"
    printf 'SSLCertificateFile /etc/pki/tls/certs/localhost.crt\n' >"$fixture/etc/httpd/conf.d/ssl.conf"
    sandbox+=(--ro-bind "$(repo_path xCAT-test/autotest/testcase/restapi/restapi_ssl.sh)" /run/restapi_ssl.sh)
    for tool in dnf systemctl; do
        printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >>/run/fixture/calls\n' "$tool" >"$fixture/bin/$tool"
        chmod +x "$fixture/bin/$tool"
    done
    : >"$fixture/calls"
}

@test "EL cleanup reloads systemd between the mod_ssl removal and the httpd restart" {
    run "${sandbox[@]}" /bin/bash /run/restapi_ssl.sh cleanup
    [ "$status" -eq 0 ]
    run cat "$fixture/calls"
    [ "${lines[0]}" = "dnf remove -y mod_ssl" ]
    [ "${lines[1]}" = "systemctl daemon-reload" ]
    [ "${lines[2]}" = "systemctl restart httpd" ]
}
