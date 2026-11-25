#!/usr/bin/env perl
## no critic (TestingAndDebugging::ProhibitNoStrict)

# xcatconfig does not write a DSA host key where OpenSSH no longer accepts one, and ssh-keygen
# refuses ed25519 in FIPS mode. The remoteshell postscript still asks for both. credentials
# must tell the node that the key is absent, without an error in the xcatd log.

use strict;
use warnings;

use FindBin;
use File::Path qw(make_path);
use File::Slurper qw(write_text);
use File::Temp qw(tempdir);
use Test::More;
use lib "$FindBin::Bin/../lib";
use XCAT::Test::File qw(repo_path);
use lib repo_path('perl-xCAT');

BEGIN {
    package xCAT::Table;
    sub import { }
    sub new { return bless {}, shift; }
    sub getAttribs { return; }
    sub getNodeAttribs { return; }
    sub close { }
    $INC{'xCAT/Table.pm'} = 1;

    package xCAT::NodeRange;
    sub import {
        no strict 'refs';
        *{ caller() . '::noderange' } = \&noderange;
    }
    sub noderange { return ( $_[0] ); }
    $INC{'xCAT/NodeRange.pm'} = 1;

    package xCAT::Zone;
    sub import { }
    $INC{'xCAT/Zone.pm'} = 1;

    package xCAT::Utils;
    sub import { }
    sub isAIX { return 0; }
    sub isServiceNode { return 0; }
    $INC{'xCAT/Utils.pm'} = 1;

    package xCAT::NetworkUtils;
    sub import { }
    sub getipaddr { return (); }
    $INC{'xCAT/NetworkUtils.pm'} = 1;

    package xCAT::PasswordUtils;
    sub import { }
    $INC{'xCAT/PasswordUtils.pm'} = 1;

    package xCAT::TableUtils;
    sub import { }
    sub get_site_attribute { return; }
    $INC{'xCAT/TableUtils.pm'} = 1;

    package xCAT::MsgUtils;
    our @traces;
    sub import { }
    sub trace { push @traces, [ @_[ 2, 3 ] ]; }
    sub message {
        my ( $class, $type, $rsp, $callback ) = @_;
        $callback->($rsp) if ref($callback) eq 'CODE';
    }
    $INC{'xCAT/MsgUtils.pm'} = 1;
}

my $plugin = repo_path('xCAT-server/lib/xcat/plugins/credentials.pm');
require $plugin;

{
    no warnings qw(redefine once);
    *xCAT_plugin::credentials::ok_with_node = sub { return 1; };
}

my $keydir = tempdir( CLEANUP => 1 );
make_path("$keydir/cn2");
write_text( "$keydir/ssh_host_rsa_key",         "rsa-fixture\n" );
write_text( "$keydir/cn2/ssh_host_ed25519_key", "cn2-ed25519-fixture\n" );
$xCAT_plugin::credentials::HOSTKEYDIR = $keydir;

sub request_key {
    my ( $node, $parameter ) = @_;
    my @responses;
    @xCAT::MsgUtils::traces = ();
    xCAT_plugin::credentials::process_request(
        {
            command          => ['getcredentials'],
            arg              => [$parameter],
            _xcat_clienthost => [$node],
            callback_port    => [300],
        },
        sub { push @responses, @_; }
    );
    my ($data)  = grep { $_->{data} } @responses;
    my ($error) = grep { $_->{error} } @responses;
    my @errors  = map { $_->[1] } grep { $_->[0] eq 'E' } @xCAT::MsgUtils::traces;
    return {
        content => $data  ? $data->{data}->[0]->{content}->[0] : undef,
        error   => $error ? $error->{error}->[0]             : undef,
        logged  => \@errors,
    };
}

foreach my $type (qw(dsa ed25519)) {
    my $got = request_key( 'cn1', "ssh_${type}_hostkey" );
    is( $got->{content}, undef, "an absent $type host key sends no data" );
    like( $got->{error}, qr/\Q$keydir\E/,
        "the node is told that $keydir holds no $type host key" );
    is_deeply( $got->{logged}, [], "an absent $type host key logs no error" );
}

my $rsa = request_key( 'cn1', 'ssh_rsa_hostkey' );
is( $rsa->{content}, "\nrsa-fixture\n", 'the shared RSA host key is read from the key directory' );

my $per_node = request_key( 'cn2', 'ssh_ed25519_hostkey' );
is( $per_node->{content}, "\ncn2-ed25519-fixture\n", 'a per-node ed25519 host key comes before the shared one' );

unlink "$keydir/ssh_host_rsa_key";
my $no_rsa = request_key( 'cn1', 'ssh_rsa_hostkey' );
like( $no_rsa->{error}, qr/RSA/, 'an absent RSA host key is reported to the node' );
is( scalar( grep { /Unable to read private RSA key/ } @{ $no_rsa->{logged} } ), 1,
    'an absent RSA host key is still an error, because every node needs one' );

done_testing();
