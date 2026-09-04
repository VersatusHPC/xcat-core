#!/usr/bin/env perl
use strict;
use warnings;

use File::Temp qw(tempdir);
use FindBin;
use Test::More;

# The scratch package below declares these; the test names them once each.
no warnings 'once';

my $source = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/yaboot.pm";
open(my $source_fh, '<', $source) or die "open $source: $!";
my $content = do { local $/; <$source_fh> };
close($source_fh) or die "close $source: $!";

my @routines;
for my $name (qw(setstate pass_along process_request)) {
    my ($routine) = $content =~ /^(sub \Q$name\E\s*\{.*?^\})/ms;
    BAIL_OUT("could not extract $name from yaboot.pm") unless $routine;
    push(@routines, $routine);
}

# yaboot.pm needs a management node to load, so the boot loader runs in a scratch package.
# Only the routines that reach the network, the xCAT database and the other plugins are
# replaced; the yaboot generator and its error reporting are the code under test.
my $harness = <<'PERL';
package Yaboot;
# yaboot.pm declares no pragma of its own and the extracted routines read package globals.
no strict;
no warnings;
use File::Path qw(mkpath);
use Getopt::Long;

our (%breaknetbootnodes, %normalnodes, %failurenodes, %usage);
our ($globaltftpdir, $errored, $resolvable);

sub syslog { return; }

package xCAT::NetworkUtils;
sub getipaddr         { return $Yaboot::resolvable ? '10.1.1.200' : undef; }
sub nodeonmynet       { return 1; }
sub determinehostname { return ('mn1'); }
sub my_ip_facing      { return (0, '10.1.1.1'); }

package xCAT::DBobjUtils;
sub getNetwkInfo { my (undef, $nodes) = @_; return map { $_ => { mgtifname => 'eth0' } } @$nodes; }

package xCAT::MsgUtils;
sub trace   { return; }
sub message { return; }

package xCAT::TableUtils;
# site.dhcpsetup=0 keeps process_request out of makedhcp, which needs a running xcatd.
sub get_site_attribute { return ('0'); }
sub getTftpDir         { return $Yaboot::globaltftpdir; }

package xCAT::Utils;
sub splitkcmdline    { return {}; }
sub parseMacTabEntry { my (undef, $macstring) = @_; return $macstring; }

package xCAT::Table;
sub new { my ($class, $name) = @_; return bless({ name => $name }, $class); }

sub getNodesAttribs {
    my ($self, $nodes) = @_;
    return {} unless ($self->{name} eq 'mac' or $self->{name} eq 'nodetype');
    my %answer;
    for my $node (@$nodes) {
        $answer{$node} = [ $self->{name} eq 'mac'
            ? { mac => 'e6:d4:d2:3a:ad:06' }
            : { os => 'fedora99', provmethod => 'install', arch => 'ppc64', profile => 'compute' } ];
    }
    return \%answer;
}

# fedora99 is the one osvers process_request neither rejects nor stages a yaboot binary for,
# so the run reaches the report without needing an install tree.
sub getAttribs {
    my ($self) = @_;
    return $self->{name} eq 'osimage' ? { osvers => 'fedora99' } : {};
}
PERL

eval $harness . "package Yaboot;\n" . join("\n", @routines) . "\n1;\n";    ## no critic (BuiltinFunctions::ProhibitStringyEval)
BAIL_OUT("could not load the yaboot boot loader: $@") if $@;

my $tftpdir = tempdir(CLEANUP => 1);
$Yaboot::globaltftpdir = $tftpdir;

my $kern = {
    kernel   => '/install/fedora99/ppc64/ppc/ppc64/vmlinuz',
    initrd   => '/install/fedora99/ppc64/ppc/ppc64/initrd.img',
    kcmdline => 'ks=http://10.1.1.1/install/autoinst/cn1 debug',
};

# Drive setstate for one node and hand back what it told its caller.
sub setstate_for {
    my ($resolvable) = @_;
    local $Yaboot::resolvable = $resolvable;
    local %Yaboot::normalnodes       = ();
    local %Yaboot::breaknetbootnodes = ();
    return Yaboot::setstate('cn1', { cn1 => [$kern] }, {}, { cn1 => [ { mac => 'e6:d4:d2:3a:ad:06' } ] },
        $tftpdir, {}, undef);
}

my ($rc, $errstr) = setstate_for(1);
is($rc, 0, 'setstate reports success for a node it configured');
is($errstr, '', 'a configured node carries no message');
ok(-e "$tftpdir/etc/cn1", 'setstate wrote the yaboot configuration of the node');

($rc, $errstr) = setstate_for(0);
ok($rc, 'setstate reports failure for a node whose address it cannot resolve');
like($errstr, qr/unable to resolve IP/i, 'the failure names the address it could not resolve');

# Drive one nodeset request through the plugin and hand back every response it sent.
sub nodeset_responses {
    my ($resolvable) = @_;
    local $Yaboot::resolvable = $resolvable;
    local %Yaboot::normalnodes       = ();
    local %Yaboot::breaknetbootnodes = ();
    local %Yaboot::failurenodes      = ();
    my @responses;
    local $::YABOOT_request = {
        command => ['nodeset'],
        node    => ['cn1'],
        arg     => ['osimage=fedora99-ppc64-install-compute'],
    };
    my $sub_req = sub {
        my ($request, $callback) = @_;
        return unless ($request->{command}->[0] eq 'setdestiny');
        $request->{bootparams}->{cn1} = [$kern];
        return;
    };
    Yaboot::process_request($::YABOOT_request, sub { push(@responses, $_[0]) }, $sub_req);
    return \@responses;
}

sub failure_reports {
    my ($responses) = @_;
    return grep { $_->{errorcode} and $_->{errorcode}->[0] } @$responses;
}

my @failed = failure_reports(nodeset_responses(0));
ok(scalar(@failed), 'nodeset reports an error for a node yaboot could not configure');
like(join('', map { @{ $_->{error} || [] } } @failed),
    qr/Failed to generate yaboot configurations/,
    'the error names yaboot as the loader that could not be generated');

is(scalar(failure_reports(nodeset_responses(1))), 0,
    'nodeset reports no error when every node was configured');

done_testing();
