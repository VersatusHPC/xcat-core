Installing xCAT on a FIPS-enabled system
========================================

xCAT can run on a management node that was booted with the operating system's
FIPS mode enabled.  xCAT uses the system OpenSSL library for its CA, server,
client, and daemon TLS credentials.  It does not provide a separate validated
cryptographic module.

Supported platforms
-------------------

xCAT 2.21 supports FIPS mode on Enterprise Linux 9 and Enterprise Linux 10,
x86_64 only, for the management node and for diskful nodes.

These platforms are not supported in FIPS mode in xCAT 2.21:

* Enterprise Linux 8: BIND (``named``) does not start with the xCAT DNS
  configuration when the system runs in FIPS mode.
* Ubuntu and openSUSE: xCAT is not tested in FIPS mode on these
  distributions.
* Diskless and statelite nodes, and the ppc64le and aarch64 architectures.

Enable FIPS mode while installing the operating system, before installing
xCAT.  Follow the `Red Hat FIPS installation guidance
<https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/switching-rhel-to-fips-mode_security-hardening>`_.
After the management node boots, verify the kernel state before installing
xCAT: ::

    cat /proc/sys/crypto/fips_enabled
    update-crypto-policies --show

The first command must print ``1`` and the second ``FIPS``.  xCAT uses the
kernel value when choosing FIPS-compatible defaults.

Installation behavior
---------------------

During its initial RPM configuration, xCAT generates RSA 2048-bit CA, server,
and client keys.  The certificates use SHA-384 signatures.

In FIPS mode, DSA and Ed25519 SSH keys are not available.
xCAT retains its RSA keys and treats the unavailable key types as optional.

When their own kernel or switch OS runs in FIPS mode, legacy Genesis and
Cumulus discovery use P-256 bootstrap keys.  The management node's FIPS
setting does not enable FIPS mode on discovered nodes.  OpenEmbedded Genesis
uses RSA 2048-bit bootstrap keys.

After installing xCAT, verify the daemon and generated certificates: ::

    systemctl is-active xcatd
    openssl x509 -in /etc/xcat/ca/ca-cert.pem -noout -text | grep 'Signature Algorithm'
    openssl x509 -in /etc/xcat/cert/server-cert.pem -noout -text | grep 'Signature Algorithm'

The default xCAT TLS policy permits TLS 1.2 and newer.  Leave
``site.xcatsslversion`` empty and ``site.xcattlspolicy`` set to ``modern`` so
the system OpenSSL policy can select permitted protocols and ciphers.

Installing nodes in FIPS mode
-----------------------------

Set the osimage attribute ``fips`` to install the nodes of a diskful osimage
in FIPS mode: ::

    chdef -t osimage -o <osimage> fips=1
    nodeset <noderange> osimage=<osimage>

``nodeset`` adds ``fips=1`` to the installer kernel line.  The installer then
installs the node in FIPS mode and sets the FIPS crypto policy.  ``nodeset``
fails for a node when its osimage sets ``fips`` and the osimage is diskless,
statelite, not Enterprise Linux 9 or 10, or not x86_64.

After the install, verify the node: ::

    xdsh <noderange> cat /proc/sys/crypto/fips_enabled
    xdsh <noderange> update-crypto-policies --show

ISC DHCP and BIND
-----------------

When ``site.dhcpomapialgorithm`` is unset outside FIPS mode, xCAT uses
``hmac-md5``.  For new installations on Enterprise Linux 9 or later and
Ubuntu 20.04 or later, xCAT sets ``hmac-sha256`` during initialization.

On new FIPS installations, xCAT saves ``hmac-sha256`` in the site table so
management and service nodes use the same algorithm.  In FIPS mode, if
this attribute is unset, xCAT also selects ``hmac-sha256``.  In FIPS mode,
xCAT rejects an explicit ``site.dhcpomapialgorithm=hmac-md5``.  When regenerating BIND
keys, xCAT reconciles their algorithm with that policy.  To retain another
supported non-MD5 algorithm, set it explicitly in the site table before
regenerating DHCP and DNS configuration.

SHA-based OMAPI requires an ``omshell`` binary with the ``key-algorithm``
command.  Before using SHA-based OMAPI, ``makedhcp`` and ``dhcpop`` check the
configured binary without connecting to a server.  If this check fails,
upgrade ISC DHCP or set ``site.dhcpomshellpath`` to a compatible binary.

The RPMs do not impose a DHCP version requirement for SHA support.
xCAT skips the capability check for MD5.  Kea does not use OMAPI.
On RHEL 8, when SHA support is needed, update the ISC packages together: ::

    dnf upgrade dhcp-server dhcp-common dhcp-libs
    rpm -q --qf '%{EPOCH}:%{VERSION}-%{RELEASE}\n' dhcp-server

To migrate an existing installation, run these commands: ::

    chtab key=dhcpomapialgorithm site.value=hmac-sha256
    makedns -n
    makedhcp -n
    makedhcp -a

Validation boundary
-------------------

Installing a FIPS-enabled management node does not qualify its boot images
for FIPS mode.  Validate the Genesis image separately before adding
``fips=1`` to its kernel command line.  Legacy images can omit integrity
files required by their bundled cryptographic libraries.

FIPS validation applies to cryptographic modules, not to xCAT as a complete
product.  Hardware-management protocols and devices must be checked
separately.  In particular, IPMI, SNMP, PDUs, switches, and BMCs can require
legacy authentication or encryption algorithms that a FIPS policy disables.
Validate each enabled management path against the site's security policy.
