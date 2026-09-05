#!/usr/bin/env perl

# xCAT must not pick hmac-md5 when no algorithm is configured. hmac-md5 is not approved for
# FIPS mode: named starts with no complaint about an md5 key stanza and then answers SERVFAIL
# to every update signed with that key, so makedns fails on a FIPS management node.
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

my $no_key   = "options {\n};\n";
my $md5_key  = key_stanza('hmac-md5');
my $sha_key  = key_stanza('hmac-sha256');

subtest 'the policy default is an algorithm a FIPS named accepts' => sub {
    is( xCAT::DHCP::OmapiPolicy->normalize_algorithm(undef),
        'hmac-sha256', 'no value gives hmac-sha256' );
    is( xCAT::DHCP::OmapiPolicy->normalize_algorithm(''),
        'hmac-sha256', 'an empty value gives hmac-sha256' );

    my $settings = omapi_settings();
    is( $settings->{algorithm}, 'hmac-sha256',
        'settings default to hmac-sha256' );
    is( $settings->{key_rr_type}, 163, 'the KEY RR type follows the default' );
    ok( !$settings->{algorithm_explicit},
        'the default is not reported as an administrator choice' );
    ok( $settings->{needs_omshell_key_algorithm},
        'omshell is told the algorithm the default selects' );
};

subtest 'an installation whose omshell cannot name an algorithm pins hmac-md5' => sub {
    for my $os ( 'ubuntu,18.04', 'sles,15.6', 'opensuse-leap,15.6' ) {
        is(
            xCAT::DHCP::OmapiPolicy->new_install_default_algorithm(
                is_new_install => 1, os => $os ),
            'hmac-md5',
            "a new $os installation pins hmac-md5 in the site table"
        );
    }

    # The omshell of dhcp-server-4.3.6-50.el8_10 runs key-algorithm hmac-sha256 against a
    # dhcpd that declares that algorithm, and cannot connect without the command.
    for my $platform (qw(el8 el9 el10)) {
        is(
            xCAT::DHCP::OmapiPolicy->new_install_default_algorithm(
                is_new_install => 1, platform => $platform ),
            'hmac-sha256',
            "a new $platform installation pins hmac-sha256"
        );
    }
    is(
        xCAT::DHCP::OmapiPolicy->new_install_default_algorithm(
            is_new_install => 0, platform => 'el9' ),
        undef,
        'an existing installation is left alone'
    );
};

subtest 'a deployed key wins over the default, and the site table wins over both' => sub {
    my $deployed = omapi_settings( deployed_algorithm => 'hmac-sha384' );
    is( $deployed->{algorithm}, 'hmac-sha384',
        'an unconfigured site takes the algorithm already deployed' );
    is( $deployed->{key_rr_type}, 164, 'the KEY RR type follows the deployed key' );
    ok( !$deployed->{algorithm_explicit},
        'a deployed algorithm is not an administrator choice' );

    my $chosen = omapi_settings(
        site_algorithm     => 'hmac-sha512',
        deployed_algorithm => 'hmac-md5',
    );
    is( $chosen->{algorithm}, 'hmac-sha512',
        'the site table wins over the deployed key' );

    my $unreadable = omapi_settings( deployed_algorithm => 'hmac-nonsense' );
    is( $unreadable->{algorithm}, 'hmac-sha256',
        'a deployed value that names no known algorithm falls back to the default' );
};

subtest 'makedhcp reads the algorithm makedns recorded, and never lowers the default' => sub {
    my $read_deployed = xCAT_plugin::dhcp->can('_ddns_key_algorithm');
    ok( $read_deployed, 'makedhcp reads the shared DDNS key file' )
      or return;

    is( $read_deployed->( ddns_key_file('hmac-sha512') ),
        'hmac-sha512', 'the algorithm is read out of the key file' );

    is( dhcp_omapi_settings( ddns_key_file('hmac-sha512') )->{algorithm},
        'hmac-sha512', 'a key file stronger than the default raises it' );

    is( dhcp_omapi_settings( ddns_key_file('hmac-md5') )->{algorithm},
        'hmac-sha256', 'a key file weaker than the default does not lower it' );

    my ( undef, $empty ) = tempfile( UNLINK => 1 );
    is( dhcp_omapi_settings($empty)->{algorithm},
        'hmac-sha256', 'a missing key file takes the default' );
};

subtest 'makedns replaces an md5 key stanza when the site names no algorithm' => sub {
    my $result = run_makedns( named_conf => $md5_key, site_algorithm => undef );

    is( $result->{named_algorithm}, 'hmac-sha256',
        'the stanza a FIPS named answers SERVFAIL for is replaced' );
    is( $result->{signing_algorithm}, 'hmac-sha256',
        'the update is signed with the replacement algorithm' );
    is( $result->{restartneeded}, 1, 'named is restarted for the new stanza' );
};

subtest 'makedns generates a new key with the default algorithm' => sub {
    my $result = run_makedns( named_conf => $no_key, site_algorithm => undef );

    is( $result->{named_algorithm}, 'hmac-sha256',
        'a key created where none existed uses hmac-sha256' );
    is( $result->{signing_algorithm}, 'hmac-sha256',
        'the update is signed with hmac-sha256' );
};

subtest 'a site that names hmac-md5 keeps hmac-md5' => sub {
    my $result = run_makedns( named_conf => $md5_key, site_algorithm => 'hmac-md5' );

    is( $result->{named_algorithm}, 'hmac-md5',
        'the administrator choice is not replaced' );
    is( $result->{signing_algorithm}, 'hmac-md5',
        'the update is signed with hmac-md5' );
    is( $result->{restartneeded}, 0, 'named is not restarted' );
};

subtest 'a matching stanza is left alone' => sub {
    my $result = run_makedns( named_conf => $sha_key, site_algorithm => undef );

    is( $result->{named_algorithm}, 'hmac-sha256', 'the stanza is unchanged' );
    is( $result->{restartneeded},   0,             'named is not restarted' );
};

subtest 'an external DNS server keeps the algorithm xCAT already signs with' => sub {
    my $unset = run_external_makedns( site_algorithm => undef );

    is( $unset->{signing_algorithm}, 'hmac-md5',
        'a site that names no algorithm keeps signing hmac-md5' );
    like( $unset->{key_contents}, qr/algorithm hmac-md5;/,
        'the key file names the algorithm the external server holds' );

    my $chosen = run_external_makedns( site_algorithm => 'hmac-sha256' );

    is( $chosen->{signing_algorithm}, 'hmac-sha256',
        'the site table selects the algorithm for an external server' );
    like( $chosen->{key_contents}, qr/algorithm hmac-sha256;/,
        'the key file follows the site table' );
};

subtest 'a stronger stanza survives the default' => sub {
    my $sha512 = key_stanza('hmac-sha512');
    my $result = run_makedns( named_conf => $sha512, site_algorithm => undef );

    is( $result->{named_algorithm}, 'hmac-sha512',
        'the default does not replace a stronger stanza' );
    is( $result->{signing_algorithm}, 'hmac-sha512',
        'the update is signed with the stanza named restarted with' );
    is( $result->{restartneeded}, 0, 'named is not restarted' );

    my $chosen = run_makedns(
        named_conf     => $sha512,
        site_algorithm => 'hmac-sha256',
    );

    is( $chosen->{named_algorithm}, 'hmac-sha256',
        'the site table still selects a weaker algorithm' );
    is( $chosen->{restartneeded}, 1, 'named is restarted for that choice' );
};

subtest 'a weaker stanza is still replaced' => sub {
    for my $weak (qw(hmac-md5 hmac-sha1 hmac-sha224)) {
        my $result =
          run_makedns( named_conf => key_stanza($weak), site_algorithm => undef );
        is( $result->{named_algorithm}, 'hmac-sha256',
            "a $weak stanza is replaced by the default" );
    }
};

# The two files declare ONE key. A test that asserts named.conf says one algorithm and
# dhcpd.conf says another, in two separate subtests, passes on a cluster whose DNS and DHCP
# disagree. Compare the two rendered stanzas instead.
subtest 'one key name declares one algorithm in named.conf and dhcpd.conf' => sub {
    my @scenarios = (
        {
            name      => 'an upgraded EL cluster that names no algorithm',
            deployed  => 'hmac-md5',
            os        => 'alma,10.0',
            platform  => 'el10',
            expect    => 'hmac-sha256',
        },
        {
            name      => 'an upgraded cluster whose omshell cannot name an algorithm',
            deployed  => 'hmac-md5',
            os        => 'sles,15.6',
            platform  => '',
            expect    => 'hmac-md5',
        },
        {
            name      => 'a cluster whose DNS server xCAT does not manage',
            deployed  => 'hmac-md5',
            os        => 'alma,10.0',
            platform  => 'el10',
            external  => 1,
            expect    => 'hmac-md5',
        },
        {
            name           => 'a site that names an algorithm',
            deployed       => 'hmac-md5',
            os             => 'alma,10.0',
            platform       => 'el10',
            site_algorithm => 'hmac-sha512',
            expect         => 'hmac-sha512',
        },
        {
            name      => 'a new cluster whose DNS server xCAT does not manage',
            deployed  => undef,
            os        => 'alma,10.0',
            platform  => 'el10',
            external  => 1,
            expect    => 'hmac-md5',
        },
        {
            name      => 'a cluster with no key stanza deployed yet',
            deployed  => undef,
            os        => 'alma,10.0',
            platform  => 'el10',
            expect    => 'hmac-sha256',
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

subtest 'a key stanza that names no algorithm is repaired' => sub {
    my $stanza = qq{options {\n};\nkey "xcat_key" {\n\tsecret "$SECRET";\n};\n};
    my $result = run_makedns( named_conf => $stanza, site_algorithm => undef );

    is( $result->{named_algorithm}, 'hmac-sha256',
        'a stanza with no algorithm line takes the default' );
    is( $result->{restartneeded}, 1, 'named is restarted for the repaired stanza' );
};

subtest 'Kea DDNS to an external server takes the algorithm that server holds' => sub {
    my $kea_key = xCAT_plugin::dhcp->can('kea_ddns_key');
    ok( $kea_key, 'the Kea D2 key reader is present' ) or return;

    no warnings qw(redefine once);
    local *xCAT::TableUtils::get_site_attribute = sub { return; };
    local *xCAT::Utils::osver = sub { return 'el10'; };
    local *xCAT::Table::new = sub { return bless {}, 'Local::TSIG::KeaPasswdTable'; };
    my ( undef, $missing ) = tempfile( UNLINK => 1 );
    unlink($missing);
    local $xCAT_plugin::dhcp::ddns_key_path = $missing;

    local %::XCATSITEVALS = ( externaldns => 1 );
    my ($external_algorithm) = $kea_key->();
    is( $external_algorithm, 'HMAC-MD5',
        'no key file on an external-DNS cluster falls to hmac-md5' );

    local %::XCATSITEVALS = ();
    my ($local_algorithm) = $kea_key->();
    is( $local_algorithm, 'HMAC-SHA256',
        'no key file on a cluster xCAT manages falls to the default' );
};

done_testing();

#---------------------------------------------------------------------------

=head3 key_stanza

    Description: Build a named.conf holding one xcat_key stanza.
    Arguments:   the algorithm the stanza declares
    Returns:     the file content

=cut

#---------------------------------------------------------------------------
sub key_stanza {
    my ($algorithm) = @_;

    return <<"NAMED";
options {
};
key "xcat_key" {
\talgorithm $algorithm;
\tsecret "$SECRET";
};
NAMED
}

#---------------------------------------------------------------------------

=head3 omapi_settings

    Description: Resolve the OMAPI policy for one site, with no xCAT database.
    Arguments:   site_algorithm, deployed_algorithm
    Returns:     the settings hash reference

=cut

#---------------------------------------------------------------------------
sub omapi_settings {
    my (%args) = @_;

    my $settings = xCAT::DHCP::OmapiPolicy->settings(
        site_values => {
            dhcpomapialgorithm => $args{site_algorithm},
            dhcpomapikeyname   => undef,
            dhcpomshellpath    => undef,
        },
        deployed_algorithm => $args{deployed_algorithm},
    );
    die "Unusable OMAPI settings: $settings->{error}" if $settings->{error};
    return $settings;
}

#---------------------------------------------------------------------------

=head3 dhcp_omapi_settings

    Description: Run the makedhcp OMAPI policy against one scratch dhcpd.conf.
    Arguments:   the path of the dhcpd.conf to read
    Returns:     the settings hash reference

=cut

#---------------------------------------------------------------------------
sub dhcp_omapi_settings {
    my ($path) = @_;

    no warnings qw(redefine once);
    local *xCAT::TableUtils::get_site_attribute = sub { return; };
    local *xCAT::Utils::osver = sub { return 'el10'; };
    local %::XCATSITEVALS = ();
    local $xCAT_plugin::dhcp::ddns_key_path = $path;
    return xCAT_plugin::dhcp::_omapi_settings( sub { die "@_" } );
}

#---------------------------------------------------------------------------

=head3 ddns_key_file

    Description: Write a scratch /etc/xcat/ddns.key naming one algorithm.
    Arguments:   the algorithm the key file declares
    Returns:     the path of the file

=cut

#---------------------------------------------------------------------------
sub ddns_key_file {
    my ($algorithm) = @_;

    my ( $fh, $path ) = tempfile( UNLINK => 1 );
    print {$fh} qq{key "xcat_key" {\n\talgorithm $algorithm;\n\tsecret "$SECRET";\n};\n};
    close($fh) or die "Unable to close $path: $!";
    return $path;
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

    open( my $result_fh, '<', $named_path )
      or die "Unable to read $named_path: $!";
    local $/;
    my $contents = <$result_fh>;
    close($result_fh) or die "Unable to close $named_path: $!";

    my ($named_algorithm) =
      ( $contents =~ /key\s+"?xcat_key"?[^{]*\{[^}]*?algorithm\s+([^;\s]+)\s*;/s );

    return {
        named_algorithm   => defined($named_algorithm) ? lc($named_algorithm) : undef,
        signing_algorithm => signing_algorithm($update),
        restartneeded     => $ctx->{restartneeded} ? 1 : 0,
    };
}

#---------------------------------------------------------------------------

=head3 run_external_makedns

    Description: Sign one update the way makedns does against an external DNS server.
                 makedns skips update_namedconf there, so no named.conf names the
                 algorithm and nothing on the management node holds the answer.
    Arguments:   site_algorithm (undef for none)
    Returns:     hash reference with signing_algorithm and key_contents

=cut

#---------------------------------------------------------------------------
sub run_external_makedns {
    my (%args) = @_;

    my $settings = omapi_settings( site_algorithm => $args{site_algorithm} );

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

    return {
        signing_algorithm => signing_algorithm($update),
        key_contents      => $key_contents,
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

#---------------------------------------------------------------------------

=head3 run_both_halves

    Description: Write the deployed state of one cluster, then run the makedns half and
                 the makedhcp half over it. Both halves write the same key name, so both
                 rendered stanzas must declare the same algorithm.
    Arguments:   deployed (the algorithm every deployed file declares, undef for none),
                 os, platform, external, site_algorithm
    Returns:     hash reference with the algorithm each half rendered

=cut

#---------------------------------------------------------------------------
sub run_both_halves {
    my (%args) = @_;

    my $dir = File::Temp->newdir();
    my $named_path = "$dir/named.conf";
    my $dhcpd_path = "$dir/dhcpd.conf";
    my $key_path   = "$dir/ddns.key";

    write_file( $named_path,
        defined( $args{deployed} ) ? key_stanza( $args{deployed} ) : $no_key );
    write_file( $dhcpd_path, deployed_dhcpd_conf( $args{deployed} ) );
    write_file( $key_path,
        defined( $args{deployed} )
        ? qq{key "xcat_key" {\n\talgorithm $args{deployed};\n\tsecret "$SECRET";\n};\n}
        : '' );

    my %sitevals = ( dnshandler => 'ddns' );
    $sitevals{dhcpomapialgorithm} = $args{site_algorithm}
      if defined( $args{site_algorithm} );
    $sitevals{externaldns} = 1 if $args{external};

    no warnings qw(redefine once);
    local *xCAT::TableUtils::get_site_attribute    = sub { return; };
    local *xCAT::Utils::runcmd                     = sub { return (); };
    local *xCAT::Utils::isAIX                      = sub { return 0; };
    local *xCAT::Utils::isLinux                    = sub { return 1; };
    local *xCAT::Utils::osver                      = sub {
        my $type = pop;
        return $args{platform} if $type eq 'platform';
        return $args{os};
    };
    local *xCAT::Table::new = sub { return bless {}, 'Local::TSIG::PasswdTable'; };
    local *xCAT_plugin::ddns::get_conf             = sub { return $named_path; };
    local *xCAT_plugin::ddns::ensure_ddns_key_file = sub { return; };
    local %::XCATSITEVALS                          = %sitevals;
    local $xCAT_plugin::dhcp::dhcpconffile         = $dhcpd_path;
    local $xCAT_plugin::dhcp::ddns_key_path        = $key_path;

    # makedns half. update_namedconf resolves the policy itself, the way process_request
    # leaves it to when no context is prepared.
    my $ctx = {
        privkey       => $SECRET,
        zonesdir      => "$dir",
        dbdir         => "$dir",
        zonestotouch  => {},
        adzones       => {},
        dnsupdaters   => [],
        adservers     => [],
        restartneeded => 0,
        external      => ( $args{external} ? 1 : 0 ),
    };
    xCAT_plugin::ddns::update_namedconf( $ctx, 0 );

    # makedhcp half, as newconfig and addnet render the OMAPI key stanza that the
    # "zone ... { key xcat_key; }" statements of the same file point at.
    my $settings = xCAT_plugin::dhcp::_omapi_settings( sub { die "@_" } );
    die "Unusable OMAPI settings: $settings->{error}" if $settings->{error};
    my @dhcpd_config;
    xCAT_plugin::dhcp::_append_omapi_key_config( \@dhcpd_config, $settings, 7911,
        sub { return; }, bless( {}, 'Local::TSIG::PasswdTable' ) );

    return {
        named => stanza_algorithm( read_file($named_path) ),
        dhcpd => stanza_algorithm( join( '', @dhcpd_config ) ),
    };
}

#---------------------------------------------------------------------------

=head3 deployed_dhcpd_conf

    Description: Build a dhcpd.conf holding one OMAPI key stanza and the zone statement
                 that points dhcpd at that key when it updates DNS.
    Arguments:   the algorithm the stanza declares, undef for no stanza
    Returns:     the file content

=cut

#---------------------------------------------------------------------------
sub deployed_dhcpd_conf {
    my ($algorithm) = @_;

    my $conf = "#xCAT generated dhcp configuration\nomapi-port 7911;\n";
    if ( defined($algorithm) ) {
        $conf .= "key xcat_key {\n  algorithm $algorithm;\n  secret \"$SECRET\";\n};\n";
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

{

    package Local::TSIG::KeaPasswdTable;

    sub getAttribs {
        return { password => 'kea-secret' };
    }
}
