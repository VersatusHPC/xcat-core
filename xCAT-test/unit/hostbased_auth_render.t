#!/usr/bin/env perl
# mkhostbased-auth renders ssh_known_hosts and shosts.equiv from the host keys,
# the node names and the zones. xCAT::HostbasedAuthUtils holds those decisions.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More;

require xCAT::HostbasedAuthUtils;

is_deeply([ xCAT::HostbasedAuthUtils::allowed_key_types(0) ],
    [qw(rsa ecdsa ed25519)], 'no FIPS: rsa, ecdsa and ed25519, never dsa');
is_deeply([ xCAT::HostbasedAuthUtils::allowed_key_types(1) ],
    [qw(rsa ecdsa)], 'FIPS: no ed25519');

is(xCAT::HostbasedAuthUtils::key_type_of_file('/etc/xcat/hostkeys/ssh_host_ecdsa_key.pub'),
    'ecdsa', 'key type from a public key path');
is(xCAT::HostbasedAuthUtils::key_type_of_file('ssh_host_rsa_key'),
    undef, 'a private key is not a public key');

is_deeply([ xCAT::HostbasedAuthUtils::host_entries('cn1', 'lab', '10.0.0.10') ],
    [qw(cn1 cn1.lab 10.0.0.10)], 'host entries carry the name, the FQDN and the IP');
is_deeply([ xCAT::HostbasedAuthUtils::host_entries('cn1.lab', 'lab', '10.0.0.10', '10.0.0.10', '') ],
    [qw(cn1.lab 10.0.0.10)], 'no FQDN for a qualified name, no duplicate or empty address');

my @hosts = (
    {
        names => [qw(sn1 sn1.lab 10.0.0.21)],
        keys  => {
            rsa     => "ssh-rsa AAAArsa root\@sn1\n",
            ed25519 => 'ssh-ed25519 AAAAed root@sn1',
        },
    },
    {
        names => [qw(cn1 cn1.lab 10.0.0.10)],
        keys  => { ecdsa => 'ecdsa-sha2-nistp256 AAAAecdsa' },
    },
);

is_deeply(
    [ xCAT::HostbasedAuthUtils::known_hosts_lines(\@hosts, [qw(rsa ecdsa)]) ],
    [
        'sn1,sn1.lab,10.0.0.21 ssh-rsa AAAArsa',
        'cn1,cn1.lab,10.0.0.10 ecdsa-sha2-nistp256 AAAAecdsa',
    ],
    'known_hosts: one line per host and allowed type, comment dropped, ed25519 left out');

is_deeply(
    [ xCAT::HostbasedAuthUtils::shosts_equiv_lines([ @hosts, $hosts[1] ]) ],
    [qw(sn1 sn1.lab 10.0.0.21 cn1 cn1.lab 10.0.0.10)],
    'shosts.equiv: every name and address once');

my ($scopes, $left_out) = xCAT::HostbasedAuthUtils::scope_sets(
    [qw(cn2 cn1 sn1 cn3 cn4)],
    { cn1 => 'zA', cn2 => 'zA', cn3 => 'zB', cn4 => '' },
    { zA => 'yes', zB => 'no' });
is_deeply($scopes, { zA => [qw(cn1 cn2)], default => [qw(cn4 sn1)] },
    'scopes: one per zone, nodes in no zone in "default"');
is_deeply($left_out, ['cn3'], 'a zone with sshbetweennodes=no gives no scope');

is(xCAT::HostbasedAuthUtils::postbootscripts_with('otherpkgs, confighostbasedauth zA', 'default'),
    'otherpkgs,confighostbasedauth default', 'postbootscripts: the entry is replaced, not added twice');
is(xCAT::HostbasedAuthUtils::postbootscripts_with('otherpkgs,confighostbasedauth zA', undef),
    'otherpkgs', 'postbootscripts: -r removes the entry');
is(xCAT::HostbasedAuthUtils::postbootscripts_with(undef, 'default'),
    'confighostbasedauth default', 'postbootscripts: empty value');

done_testing();
