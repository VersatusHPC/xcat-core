#!/bin/bash
# Turn Apache HTTPS on or off on the management node for the REST API cases.
#
# Usage: restapi_ssl.sh setup|cleanup
#
# setup follows docs/source/advanced/restapi/restapi_setup: it enables mod_ssl and points the
# SSL virtual host at the xCAT server credential, which holds the key and the certificate.
# cleanup puts back the files that setup changed.
set -e

action=$1
cred=/etc/xcat/cert/server-cred.pem

os_family() {
    local id id_like
    id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
    id_like=$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"')
    case " $id $id_like " in
        *" debian "* | *" ubuntu "*) echo debian ;;
        *" suse "* | *" sles "* | *" opensuse "*) echo suse ;;
        *) echo redhat ;;
    esac
}

# The .xcattest-orig copy is what cleanup restores. Keep the first copy only, so a second setup
# does not save the edited file over the original.
use_xcat_cred() {
    local file=$1
    [ -f "$file.xcattest-orig" ] || cp -p "$file" "$file.xcattest-orig"
    # The xCAT CA has no OCSP responder, so stapling cannot work with the xCAT credential.
    sed -i -e "s|^\(\s*\)SSLCertificateFile.*$|\1SSLCertificateFile $cred|" \
        -e 's|^\(\s*SSLCertificateKeyFile.*\)$|#\1|' \
        -e 's|^\(\s*\)SSLUseStapling\s.*$|\1SSLUseStapling off|' "$file"
}

restore() {
    local file=$1
    if [ -f "$file.xcattest-orig" ]; then mv -f "$file.xcattest-orig" "$file"; fi
}

family=$(os_family)
case "$family/$action" in
    redhat/setup)
        # openEuler is in this branch: it ships httpd and mod_ssl with the RHEL layout.
        dnf install -y mod_ssl
        use_xcat_cred /etc/httpd/conf.d/ssl.conf
        systemctl restart httpd
        ;;
    redhat/cleanup)
        restore /etc/httpd/conf.d/ssl.conf
        dnf remove -y mod_ssl
        # httpd.service wants httpd-init.service, which left with mod_ssl. Without a reload
        # systemd still runs the removed unit and it fails.
        systemctl daemon-reload
        systemctl restart httpd
        ;;
    suse/setup)
        a2enmod ssl
        a2enflag SSL
        [ -f /etc/apache2/vhosts.d/vhost-ssl.conf ] ||
            cp /etc/apache2/vhosts.d/vhost-ssl.template /etc/apache2/vhosts.d/vhost-ssl.conf
        use_xcat_cred /etc/apache2/vhosts.d/vhost-ssl.conf
        systemctl restart apache2
        ;;
    suse/cleanup)
        rm -f /etc/apache2/vhosts.d/vhost-ssl.conf /etc/apache2/vhosts.d/vhost-ssl.conf.xcattest-orig
        a2disflag SSL
        a2dismod ssl
        systemctl restart apache2
        ;;
    debian/setup)
        a2enmod ssl
        a2ensite default-ssl
        use_xcat_cred /etc/apache2/sites-available/default-ssl.conf
        systemctl restart apache2
        ;;
    debian/cleanup)
        a2dissite default-ssl
        a2dismod ssl
        restore /etc/apache2/sites-available/default-ssl.conf
        systemctl restart apache2
        ;;
    *)
        echo "usage: $0 setup|cleanup" >&2
        exit 2
        ;;
esac
