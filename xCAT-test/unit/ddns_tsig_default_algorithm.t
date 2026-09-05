#!/usr/bin/env perl

# named.conf and dhcpd.conf declare ONE key name, and the "zone ... { key xcat_key; }"
# statements of dhcpd.conf point dhcpd at that stanza. Every host of the cluster that
# writes either file must therefore name one algorithm. The cluster-wide choice lives in
# site.dhcpomapialgorithm. A default that a host computes from its own platform, its own
# external-DNS flag or its own copy of /etc/xcat/ddns.key splits a cluster whose hosts
# differ, and no xCAT command repairs the split.
#
# Run this test with XCATROOT set to the tree under test. xCAT::Table does
# "use lib $::XCATROOT/lib/perl", so an installed /opt/xcat shadows the modules under test:
#   XCATROOT=$PWD/xCAT-server prove xCAT-test/unit/ddns_tsig_default_algorithm.t

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../xCAT-server/lib";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use lib "$FindBin::Bin/../../perl-xCAT";

use File::Temp qw(tempfile);
use Test::More;

$ENV{XCATCFG}  ||= 'SQLite:/tmp';
$ENV{XCATROOT} ||= "$FindBin::Bin/../../xCAT-server";

my $ddns_plugin_path = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/ddns.pm";
if ( -f $ddns_plugin_path ) { require $ddns_plugin_path; }
else                        { require xCAT_plugin::ddns; }

my $dhcp_plugin_path = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/dhcp.pm";
if ( -f $dhcp_plugin_path ) { require $dhcp_plugin_path; }
else                        { require xCAT_plugin::dhcp; }

BAIL_OUT('xCAT::DHCP::OmapiPolicy->normalize_algorithm is missing')
  unless xCAT::DHCP::OmapiPolicy->can('normalize_algorithm');
BAIL_OUT('xCAT_plugin::ddns::update_namedconf is missing')
  unless defined( &xCAT_plugin::ddns::update_namedconf );
BAIL_OUT('xCAT_plugin::dhcp::_omapi_settings is missing')
  unless defined( &xCAT_plugin::dhcp::_omapi_settings );
BAIL_OUT('xCAT_plugin::dhcp::_append_omapi_key_config is missing')
  unless defined( &xCAT_plugin::dhcp::_append_omapi_key_config );

# KEY RR algorithm numbers, as ddns_sign_update writes them for old Net::DNS.
my %ALGORITHM_OF_RR_TYPE = (
    157 => 'hmac-md5',
    161 => 'hmac-sha1',
    162 => 'hmac-sha224',
    163 => 'hmac-sha256',
    164 => 'hmac-sha384',
    165 => 'hmac-sha512',
);

my $SECRET = 'c2VjcmV0LXNlY3JldC1zZWNyZXQtc2VjcmV0LXNlY3I=';

my $no_key  = "options {\n};\n";
my $md5_key = key_stanza('hmac-md5');

# One host identity per row: the platform and the os string xCAT::Utils->osver answers.
my %HOST = (
    el8      => [ 'el8',  'alma,8.10' ],
    el9      => [ 'el9',  'alma,9.8' ],
    el10     => [ 'el10', 'alma,10.0' ],
    sles15   => [ '',     'sles,15.6' ],
    leap15   => [ '',     'opensuse-leap,15.6' ],
    ubuntu18 => [ '',     'ubuntu,18.04' ],
    ubuntu24 => [ '',     'ubuntu,24.04' ],
    debian12 => [ '',     'debian,12' ],
    rhels7   => [ '',     'rhels,7.9' ],
    unknown  => [ undef,  undef ],
);

subtest 'with nothing configured every host resolves one algorithm' => sub {

    # The management node writes named.conf and a service node writes dhcpd.conf. The two
    # hosts need not run the same operating system, and no attribute tells either of them
    # what the other resolved, so a default that reads the local platform splits the key.
    for my $host ( sort keys %HOST ) {
        my $settings = omapi_settings( host => $host );
        is( $settings->{algorithm}, 'hmac-md5',
            "$host resolves hmac-md5 when the site table names no algorithm" );
        ok( !$settings->{needs_omshell_key_algorithm},
            "$host asks omshell for no key-algorithm command it may not have" );
    }
};

subtest 'a new installation pins the cluster-wide algorithm in the site table' => sub {

    # xcatconfig writes one row. Every host of the cluster reads that row, so the choice
    # is made once, on a platform whose omshell accepts the key-algorithm command.
    for my $host (qw(el8 el9 el10 ubuntu24)) {
        is( new_install_pin($host), 'hmac-sha256',
            "a new $host installation pins hmac-sha256" );
    }

    # The omshell of these platforms has no key-algorithm command, so it authenticates
    # only against an hmac-md5 key. No pin leaves them on the hmac-md5 default.
    for my $host (qw(sles15 leap15 ubuntu18 debian12 rhels7 unknown)) {
        my $pin = new_install_pin($host);
        ok( !defined($pin) || $pin eq 'hmac-md5',
            "a new $host installation is not pinned to an algorithm its omshell may reject" );
    }

    is( new_install_pin( 'el9', is_new_install => 0 ),
        undef, 'an existing installation keeps the algorithm it has' );
};

# Every scenario writes one deployed state, then runs the makedns half on one host and the
# makedhcp half on another, and compares the two rendered key stanzas.
subtest 'named.conf and dhcpd.conf declare one algorithm' => sub {
    my @scenarios = (
        {
            name       => 'makedns -e with site.externaldns unset',
            deployed   => 'hmac-md5',
            dns_host   => 'el10',
            dhcp_host  => 'el10',
            external   => 1,
            externaldns_site => 0,
            expect     => 'hmac-md5',
        },
        {
            name      => 'an EL10 management node and a SLES 15 service node',
            deployed  => 'hmac-md5',
            dns_host  => 'el10',
            dhcp_host => 'sles15',
            expect    => 'hmac-md5',
        },
        {
            name      => 'an EL10 management node and a Debian 12 service node',
            deployed  => 'hmac-md5',
            dns_host  => 'el10',
            dhcp_host => 'debian12',
            expect    => 'hmac-md5',
        },
        {
            name      => 'no key file on the host that writes dhcpd.conf',
            deployed  => 'hmac-md5',
            dns_host  => 'el10',
            dhcp_host => 'el10',
            key_file  => 'missing',
            expect    => 'hmac-md5',
        },
        {
            name      => 'a key file the host cannot read',
            deployed  => 'hmac-md5',
            dns_host  => 'el10',
            dhcp_host => 'el10',
            key_file  => 'unreadable',
            expect    => 'hmac-md5',
        },
        {
            name      => 'a key stanza that names no algorithm',
            deployed  => 'none',
            dns_host  => 'el10',
            dhcp_host => 'el10',
            expect    => 'hmac-md5',
        },
        {
            name      => 'a cluster with no key stanza deployed yet',
            deployed  => undef,
            dns_host  => 'el10',
            dhcp_host => 'el10',
            expect    => 'hmac-md5',
        },
        {
            name           => 'a site that names an algorithm, read by two platforms',
            deployed       => 'hmac-md5',
            dns_host       => 'el10',
            dhcp_host      => 'sles15',
            site_algorithm => 'hmac-sha256',
            expect         => 'hmac-sha256',
        },
        {
            name           => 'a pinned cluster whose DNS server xCAT does not manage',
            deployed       => 'hmac-md5',
            dns_host       => 'el9',
            dhcp_host      => 'el9',
            external       => 1,
            externaldns_site => 1,
            site_algorithm => 'hmac-sha512',
            expect         => 'hmac-sha512',
        },
    );

    for my $scenario (@scenarios) {
        my $result = run_both_halves( %{$scenario} );
        is( $result->{named}, $result->{dhcpd},
            "$scenario->{name}: named.conf and dhcpd.conf declare one algorithm" );
        is( $result->{named}, $scenario->{expect},
            "$scenario->{name}: that algorithm is $scenario->{expect}" );
    }
};

subtest 'the pinned algorithm reaches the key stanza and the signed update' => sub {

    # This is the FIPS repair. named loads an hmac-md5 key stanza without an error and
    # then answers SERVFAIL to every update signed with that key.
    my $result = run_makedns( named_conf => $md5_key, site_algorithm => 'hmac-sha256' );

    is( $result->{named_algorithm}, 'hmac-sha256',
        'the stanza a FIPS named answers SERVFAIL for is replaced' );
    is( $result->{signing_algorithm}, 'hmac-sha256',
        'the update is signed with the pinned algorithm' );
    is( $result->{restartneeded}, 1, 'named is restarted for the new stanza' );

    my $created = run_makedns( named_conf => $no_key, site_algorithm => 'hmac-sha256' );
    is( $created->{named_algorithm}, 'hmac-sha256',
        'a key created where none existed takes the pinned algorithm' );
    is( $created->{signing_algorithm}, 'hmac-sha256',
        'that key signs the update' );
};

subtest 'a stanza the site table already names is left alone' => sub {
    my $result =
      run_makedns( named_conf => key_stanza('hmac-sha256'), site_algorithm => 'hmac-sha256' );

    is( $result->{named_algorithm}, 'hmac-sha256', 'the stanza is unchanged' );
    is( $result->{restartneeded},   0,             'named is not restarted' );

    my $unpinned = run_makedns( named_conf => key_stanza('hmac-sha512'), site_algorithm => undef );
    is( $unpinned->{named_algorithm}, 'hmac-sha512',
        'a stanza an administrator wrote survives an unpinned makedns' );
    is( $unpinned->{restartneeded}, 0, 'named is not restarted for it' );
};

subtest 'Kea D2 takes the algorithm the cluster pinned' => sub {
    my $kea_key = xCAT_plugin::dhcp->can('kea_ddns_key');
    ok( $kea_key, 'the Kea D2 key reader is present' ) or return;

    no warnings qw(redefine once);
    local *xCAT::TableUtils::get_site_attribute = sub { return; };
    local *xCAT::Utils::osver = sub { return 'el10'; };
    local *xCAT::Table::new = sub { return bless {}, 'Local::TSIG::KeaPasswdTable'; };
    my ( undef, $missing ) = tempfile( UNLINK => 1 );
    unlink($missing);
    local $xCAT_plugin::dhcp::ddns_key_path = $missing;

    # A service node holds no /etc/xcat/ddns.key. The passwd table carries the secret and
    # the site table carries the algorithm, so both come from the cluster, not the host.
    local %::XCATSITEVALS = ( externaldns => 1 );
    my ($external_algorithm) = $kea_key->();
    is( $external_algorithm, 'HMAC-MD5',
        'an external-DNS cluster that pinned nothing keeps hmac-md5' );

    local %::XCATSITEVALS = ( dhcpomapialgorithm => 'hmac-sha256' );
    my ($pinned_algorithm) = $kea_key->();
    is( $pinned_algorithm, 'HMAC-SHA256', 'a pinned cluster takes its pin' );

    local %::XCATSITEVALS = ();
    my ($unpinned_algorithm) = $kea_key->();
    is( $unpinned_algorithm, 'HMAC-MD5',
        'an unpinned cluster takes the algorithm every other writer takes' );

    # A directory at the path fails open() for every user, including the root the unit
    # suite runs as.
    my $dir = File::Temp->newdir();
    mkdir("$dir/ddns.key") or die "Unable to create $dir/ddns.key: $!";
    local $xCAT_plugin::dhcp::ddns_key_path = "$dir/ddns.key";
    local %::XCATSITEVALS = ( dhcpomapialgorithm => 'hmac-sha256' );
    my ($unreadable_algorithm) = $kea_key->();
    is( $unreadable_algorithm, 'HMAC-SHA256',
        'a key file the host cannot read does not change the algorithm' );
};

done_testing();

#---------------------------------------------------------------------------

=head3 key_stanza

    Description: Build a named.conf holding one xcat_key stanza.
    Arguments:   the algorithm the stanza declares, or "none" for a stanza with no
                 algorithm line
    Returns:     the file content

=cut

#---------------------------------------------------------------------------
sub key_stanza {
    my ($algorithm) = @_;

    my $line = $algorithm eq 'none' ? '' : "\talgorithm $algorithm;\n";
    return "options {\n};\nkey \"xcat_key\" {\n$line\tsecret \"$SECRET\";\n};\n";
}

#---------------------------------------------------------------------------

=head3 omapi_settings

    Description: Resolve the OMAPI policy for one host, with no xCAT database.
    Arguments:   host (a key of %HOST), site_algorithm
    Returns:     the settings hash reference

=cut

#---------------------------------------------------------------------------
sub omapi_settings {
    my (%args) = @_;

    my ( $platform, $os ) = @{ $HOST{ $args{host} || 'el10' } };

    no warnings qw(redefine once);
    local *xCAT::Utils::osver = sub {
        my $type = pop;
        return $platform if defined($type) && $type eq 'platform';
        return $os;
    };
    local %::XCATSITEVALS = ();

    my $settings = xCAT::DHCP::OmapiPolicy->settings(
        site_values => {
            dhcpomapialgorithm => $args{site_algorithm},
            dhcpomapikeyname   => undef,
            dhcpomshellpath    => undef,
        },
    );
    die "Unusable OMAPI settings: $settings->{error}" if $settings->{error};
    return $settings;
}

#---------------------------------------------------------------------------

=head3 new_install_pin

    Description: Name the algorithm xcatconfig writes into the site table for one host.
    Arguments:   host (a key of %HOST), is_new_install (1 by default)
    Returns:     the algorithm, or undef when nothing is written

=cut

#---------------------------------------------------------------------------
sub new_install_pin {
    my ( $host, %args ) = @_;

    my ( $platform, $os ) = @{ $HOST{$host} };
    return xCAT::DHCP::OmapiPolicy->new_install_default_algorithm(
        is_new_install => exists( $args{is_new_install} ) ? $args{is_new_install} : 1,
        platform       => $platform,
        os             => $os,
    );
}

#---------------------------------------------------------------------------

=head3 run_makedns

    Description: Run update_namedconf over a scratch named.conf, then sign one update
                 with the context that run produced.
    Arguments:   named_conf (the file content), site_algorithm (undef for none)
    Returns:     hash reference with named_algorithm, signing_algorithm, restartneeded

=cut

#---------------------------------------------------------------------------
sub run_makedns {
    my (%args) = @_;

    my ( $named_fh, $named_path ) = tempfile( UNLINK => 1 );
    print {$named_fh} $args{named_conf};
    close($named_fh) or die "Unable to close $named_path: $!";

    my $settings = omapi_settings( site_algorithm => $args{site_algorithm} );

    my $ctx = {
        omapi_settings => $settings,
        privkey        => $SECRET,
        zonesdir       => '/tmp',
        dbdir          => '/tmp',
        zonestotouch   => {},
        adzones        => {},
        dnsupdaters    => [],
        adservers      => [],
        restartneeded  => 0,
    };

    no warnings qw(redefine once);
    local *xCAT_plugin::ddns::get_conf             = sub { return $named_path; };
    local *xCAT_plugin::ddns::ensure_ddns_key_file = sub { return; };
    local *xCAT::TableUtils::get_site_attribute    = sub { return; };
    local *xCAT::Utils::runcmd                     = sub { return (); };
    local *xCAT::Utils::isAIX                      = sub { return 0; };
    local *xCAT::Utils::isLinux                    = sub { return 1; };
    local *xCAT::Table::new = sub { return bless {}, 'Local::TSIG::PasswdTable'; };

    my $update = Local::TSIG::Update->new();
    {
        # Old Net::DNS signs every algorithm except MD5 through a KEY RR, so the recorded
        # call names the algorithm this run selected.
        local $Net::DNS::VERSION = '1.25';
        xCAT_plugin::ddns::update_namedconf( $ctx, 0 );
        xCAT_plugin::ddns::ddns_sign_update( $ctx, $update );
    }

    return {
        named_algorithm   => stanza_algorithm( read_file($named_path) ),
        signing_algorithm => signing_algorithm($update),
        restartneeded     => $ctx->{restartneeded} ? 1 : 0,
    };
}

#---------------------------------------------------------------------------

=head3 signing_algorithm

    Description: Name the TSIG algorithm one recorded sign_tsig call selects.
    Arguments:   the recording update object
    Returns:     the algorithm name, or "keyfile" for the key-file interface

=cut

#---------------------------------------------------------------------------
sub signing_algorithm {
    my ($update) = @_;

    my $calls = $update->{sign_tsig_calls};
    is( scalar( @{$calls} ), 1, 'the update is signed once' );
    my $args = $calls->[0];

    return 'keyfile' if @{$args} == 1 && !ref( $args->[0] );
    return 'hmac-md5' if @{$args} == 2;

    my $rr_type = $args->[0]->algorithm;
    return $ALGORITHM_OF_RR_TYPE{$rr_type} || "KEY RR algorithm $rr_type";
}

{

    package Local::TSIG::Update;

    sub new {
        return bless { sign_tsig_calls => [] }, shift;
    }

    sub sign_tsig {
        my ( $self, @args ) = @_;
        push @{ $self->{sign_tsig_calls} }, \@args;
        return;
    }
}

{

    package Local::TSIG::PasswdTable;

    sub setAttribs {
        return 1;
    }

    sub getAttribs {
        return;
    }
}

{

    package Local::TSIG::KeaPasswdTable;

    sub getAttribs {
        return { password => 'kea-secret' };
    }
}

#---------------------------------------------------------------------------

=head3 run_both_halves

    Description: Write the deployed state of one cluster, then run the makedns half on
                 one host and the makedhcp half on another. Both halves write the same
                 key name, so both rendered stanzas must declare the same algorithm.
    Arguments:   deployed (the algorithm every deployed file declares; "none" for a
                 stanza with no algorithm line, undef for no stanza), dns_host,
                 dhcp_host, external (the makedns -e flag), externaldns_site,
                 key_file ("missing" or "unreadable"), site_algorithm
    Returns:     hash reference with the algorithm each half rendered

=cut

#---------------------------------------------------------------------------
sub run_both_halves {
    my (%args) = @_;

    my $dir        = File::Temp->newdir();
    my $named_path = "$dir/named.conf";
    my $dhcpd_path = "$dir/dhcpd.conf";
    my $key_path   = "$dir/ddns.key";

    write_file( $named_path,
        defined( $args{deployed} ) ? key_stanza( $args{deployed} ) : $no_key );
    write_file( $dhcpd_path, deployed_dhcpd_conf( $args{deployed} ) );

    my $key_state = $args{key_file} || 'present';
    if ( $key_state eq 'unreadable' ) {

        # A directory at the path fails open() for every user, including the root the
        # unit suite runs as.
        mkdir($key_path) or die "Unable to create $key_path: $!";
    } elsif ( $key_state ne 'missing' ) {
        write_file( $key_path,
            defined( $args{deployed} ) && $args{deployed} ne 'none'
            ? qq{key "xcat_key" {\n\talgorithm $args{deployed};\n\tsecret "$SECRET";\n};\n}
            : qq{key "xcat_key" {\n\tsecret "$SECRET";\n};\n} );
    }

    my %sitevals = ( dnshandler => 'ddns' );
    $sitevals{dhcpomapialgorithm} = $args{site_algorithm}
      if defined( $args{site_algorithm} );
    $sitevals{externaldns} = 1 if $args{externaldns_site};

    # makedns skips update_namedconf when DNS is external, so the key file it renders and
    # the update it signs are the only artifacts of that half.
    my $named =
      $args{external}
      ? render_external_dns( $args{dns_host}, \%sitevals )
      : render_named_conf( $named_path, $args{dns_host}, \%sitevals );
    my $dhcpd = render_dhcpd_conf( $dhcpd_path, $key_path, $args{dhcp_host}, \%sitevals );

    return { named => $named, dhcpd => $dhcpd };
}

#---------------------------------------------------------------------------

=head3 render_named_conf

    Description: Run the makedns half on one host.
    Arguments:   the named.conf path, the host, the site values
    Returns:     the algorithm the rendered key stanza declares

=cut

#---------------------------------------------------------------------------
sub render_named_conf {
    my ( $named_path, $host, $sitevals ) = @_;

    my ( $platform, $os ) = @{ $HOST{ $host || 'el10' } };

    no warnings qw(redefine once);
    local *xCAT::TableUtils::get_site_attribute    = sub { return; };
    local *xCAT::Utils::runcmd                     = sub { return (); };
    local *xCAT::Utils::isAIX                      = sub { return 0; };
    local *xCAT::Utils::isLinux                    = sub { return 1; };
    local *xCAT::Utils::osver                      = sub {
        my $type = pop;
        return $platform if defined($type) && $type eq 'platform';
        return $os;
    };
    local *xCAT::Table::new = sub { return bless {}, 'Local::TSIG::PasswdTable'; };
    local *xCAT_plugin::ddns::get_conf             = sub { return $named_path; };
    local *xCAT_plugin::ddns::ensure_ddns_key_file = sub { return; };
    local %::XCATSITEVALS                          = %{$sitevals};

    my $ctx = {
        privkey       => $SECRET,
        zonesdir      => '/tmp',
        dbdir         => '/tmp',
        zonestotouch  => {},
        adzones       => {},
        dnsupdaters   => [],
        adservers     => [],
        restartneeded => 0,
    };
    $ctx->{omapi_settings} = xCAT::DHCP::OmapiPolicy->settings();
    die "Unusable OMAPI settings: $ctx->{omapi_settings}->{error}"
      if $ctx->{omapi_settings}->{error};

    xCAT_plugin::ddns::update_namedconf( $ctx, 0 );
    return stanza_algorithm( read_file($named_path) );
}

#---------------------------------------------------------------------------

=head3 render_external_dns

    Description: Run the makedns half against an external DNS server on one host, as
                 makedns does with -e or site.externaldns: no named.conf is written, so
                 the key file and the signed update carry the algorithm.
    Arguments:   the host, the site values
    Returns:     the algorithm the rendered key file declares

=cut

#---------------------------------------------------------------------------
sub render_external_dns {
    my ( $host, $sitevals ) = @_;

    my ( $platform, $os ) = @{ $HOST{ $host || 'el10' } };

    no warnings qw(redefine once);
    local *xCAT::TableUtils::get_site_attribute = sub { return; };
    local *xCAT::Utils::osver                   = sub {
        my $type = pop;
        return $platform if defined($type) && $type eq 'platform';
        return $os;
    };
    local %::XCATSITEVALS = %{$sitevals};

    my $settings = xCAT::DHCP::OmapiPolicy->settings();
    die "Unusable OMAPI settings: $settings->{error}" if $settings->{error};

    my $ctx = {
        omapi_settings => $settings,
        privkey        => $SECRET,
        external       => 1,
    };

    my $update = Local::TSIG::Update->new();
    my $key_contents;
    {
        # Old Net::DNS signs every algorithm except MD5 through a KEY RR, so the recorded
        # call names the algorithm this run selected.
        local $Net::DNS::VERSION = '1.25';
        $key_contents = xCAT_plugin::ddns::ddns_key_contents($ctx);
        xCAT_plugin::ddns::ddns_sign_update( $ctx, $update );
    }

    my $signed = signing_algorithm($update);
    my $named  = stanza_algorithm($key_contents);
    is( $signed, $named, 'the external key file and the signed update agree' );
    return $named;
}

#---------------------------------------------------------------------------

=head3 render_dhcpd_conf

    Description: Run the makedhcp half on one host, as newconfig and addnet render the
                 OMAPI key stanza the "zone ... { key xcat_key; }" statements point at.
    Arguments:   the dhcpd.conf path, the key file path, the host, the site values
    Returns:     the algorithm the rendered key stanza declares

=cut

#---------------------------------------------------------------------------
sub render_dhcpd_conf {
    my ( $dhcpd_path, $key_path, $host, $sitevals ) = @_;

    my ( $platform, $os ) = @{ $HOST{ $host || 'el10' } };

    no warnings qw(redefine once);
    local *xCAT::TableUtils::get_site_attribute = sub { return; };
    local *xCAT::Utils::osver                   = sub {
        my $type = pop;
        return $platform if defined($type) && $type eq 'platform';
        return $os;
    };
    local *xCAT::Table::new = sub { return bless {}, 'Local::TSIG::PasswdTable'; };
    local %::XCATSITEVALS                   = %{$sitevals};
    local $xCAT_plugin::dhcp::dhcpconffile  = $dhcpd_path;
    local $xCAT_plugin::dhcp::ddns_key_path = $key_path;

    my $settings = xCAT_plugin::dhcp::_omapi_settings( sub { die "@_" } );
    die "Unusable OMAPI settings: $settings->{error}" if $settings->{error};

    my @dhcpd_config;
    xCAT_plugin::dhcp::_append_omapi_key_config( \@dhcpd_config, $settings, 7911,
        sub { return; }, bless( {}, 'Local::TSIG::PasswdTable' ) );
    return stanza_algorithm( join( '', @dhcpd_config ) );
}

#---------------------------------------------------------------------------

=head3 deployed_dhcpd_conf

    Description: Build a dhcpd.conf holding one OMAPI key stanza and the zone statement
                 that points dhcpd at that key when it updates DNS.
    Arguments:   the algorithm the stanza declares; "none" for no algorithm line, undef
                 for no stanza
    Returns:     the file content

=cut

#---------------------------------------------------------------------------
sub deployed_dhcpd_conf {
    my ($algorithm) = @_;

    my $conf = "#xCAT generated dhcp configuration\nomapi-port 7911;\n";
    if ( defined($algorithm) ) {
        $conf .= "key xcat_key {\n";
        $conf .= "  algorithm $algorithm;\n" unless $algorithm eq 'none';
        $conf .= "  secret \"$SECRET\";\n};\n";
        $conf .= "omapi-key xcat_key;\n";
    }
    $conf .= "subnet 192.0.2.0 netmask 255.255.255.0 {\n"
      . "    zone example.com. {\n"
      . "       primary 192.0.2.1; key xcat_key; \n"
      . "    }\n}\n";
    return $conf;
}

#---------------------------------------------------------------------------

=head3 stanza_algorithm

    Description: Name the algorithm the xcat_key stanza of one rendered file declares.
    Arguments:   the file content
    Returns:     the algorithm in lower case, or undef

=cut

#---------------------------------------------------------------------------
sub stanza_algorithm {
    my ($contents) = @_;

    my ($algorithm) =
      ( $contents =~ /key\s+"?xcat_key"?[^{]*\{[^}]*?algorithm\s+([^;\s]+)\s*;/s );
    return defined($algorithm) ? lc($algorithm) : undef;
}

#---------------------------------------------------------------------------

=head3 write_file / read_file

    Description: Read and write one scratch file.
    Arguments:   the path, and for write_file the content
    Returns:     the content, for read_file

=cut

#---------------------------------------------------------------------------
sub write_file {
    my ( $path, $contents ) = @_;

    open( my $fh, '>', $path ) or die "Unable to write $path: $!";
    print {$fh} $contents;
    close($fh) or die "Unable to close $path: $!";
    return;
}

sub read_file {
    my ($path) = @_;

    open( my $fh, '<', $path ) or die "Unable to read $path: $!";
    local $/;
    my $contents = <$fh>;
    close($fh) or die "Unable to close $path: $!";
    return $contents;
}
