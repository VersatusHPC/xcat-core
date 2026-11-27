#!/usr/bin/env bats
#
# restapi_ssl.sh setup on openSUSE copies vhost-ssl.template, which sets SSLUseStapling on, and
# points it at the xCAT server credential. The xCAT CA has no OCSP responder, so Apache logs
# "ssl_stapling_init_cert: can't retrieve issuer certificate" at every start.

load helpers/script_sandbox

setup() {
    setup_script_sandbox cat cp grep mv rm sed tr
    mkdir -p "$fixture/etc/apache2/vhosts.d"
    printf 'ID="opensuse-leap"\nID_LIKE="suse opensuse"\n' >"$fixture/etc/os-release"
    printf '<VirtualHost _default_:443>\n\tSSLUseStapling  on\n\tSSLCertificateFile /etc/apache2/ssl.crt/vhost-example.crt\n\tSSLCertificateKeyFile /etc/apache2/ssl.key/vhost-example.key\n</VirtualHost>\n' \
        >"$fixture/etc/apache2/vhosts.d/vhost-ssl.template"
    sandbox+=(--ro-bind "$(repo_path xCAT-test/autotest/testcase/restapi/restapi_ssl.sh)" /run/restapi_ssl.sh)
    for tool in a2enmod a2enflag systemctl; do
        printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/$tool"
        chmod +x "$fixture/bin/$tool"
    done
}

@test "openSUSE setup turns OCSP stapling off in the SSL virtual host" {
    run "${sandbox[@]}" /bin/bash /run/restapi_ssl.sh setup
    [ "$status" -eq 0 ]
    run grep -E '^\s*SSLUseStapling\s' "$fixture/etc/apache2/vhosts.d/vhost-ssl.conf"
    [ "$output" = "	SSLUseStapling off" ]
}

@test "openSUSE setup points the SSL virtual host at the xCAT server credential" {
    run "${sandbox[@]}" /bin/bash /run/restapi_ssl.sh setup
    [ "$status" -eq 0 ]
    run grep -E '^\s*SSLCertificateFile\s' "$fixture/etc/apache2/vhosts.d/vhost-ssl.conf"
    [ "$output" = "	SSLCertificateFile /etc/xcat/cert/server-cred.pem" ]
}
