#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use Test::More;
use XML::LibXML;

# The scratch package below declares these; the test names them once each.
no warnings 'once';

my $source = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/kvm.pm";
open(my $source_fh, '<', $source) or die "open $source: $!";
my $content = do { local $/; <$source_fh> };
close($source_fh) or die "close $source: $!";

my ($makedom) = $content =~ /^(sub makedom\s*\{.*?^\})/ms;
BAIL_OUT('could not extract makedom from kvm.pm') unless $makedom;

# A helper the fix may add. It is pulled in when it exists so that this test measures the
# behaviour of makedom, not the presence of a subroutine.
my @routines = ($makedom);
for my $name (qw(vnc_password_rejected)) {
    my ($routine) = $content =~ /^(sub \Q$name\E\s*\{.*?^\})/ms;
    push(@routines, $routine) if $routine;
}

# kvm.pm needs a management node to load, so makedom runs in a scratch package. Only the
# routines that reach libvirt or the xCAT database are replaced.
my $harness = <<'PERL';
package KVMMakedom;
use XML::LibXML;
our ($node, $confdata, $hypconn, $parser);
$parser = XML::LibXML->new();
sub genpassword { return 'genpw123'; }
sub refresh_vm  { return 1; }

package xCAT::MsgUtils;
sub trace   { return 1; }
sub message { return 1; }

package KVMMakedom;
PERL

eval $harness . join("\n", @routines) . "\n1;\n";    ## no critic (BuiltinFunctions::ProhibitStringyEval)
BAIL_OUT("could not load makedom: $@") if $@;

# A libvirt connection that records every domain description it is asked to start. $reject is
# a regular expression; a description that matches it is refused with $message, the way
# Sys::Virt reports a libvirt error.
{

    package FakeHyp;
    sub new {
        my ($class, %arg) = @_;
        return bless({ tried => [], %arg }, $class);
    }

    sub create_domain {
        my ($self, $xml) = @_;
        push(@{ $self->{tried} }, $xml);
        if ($self->{reject} and $xml =~ $self->{reject}) {
            die bless({ message => $self->{message} }, 'FakeVirtError');
        }
        return bless({}, 'FakeDom');
    }
}

# The message the riscv64 qemu on the CI hypervisor gives for a domain with a VNC password.
my $des_error =
  "internal error: QEMU unexpectedly closed the monitor (vm='cn1'): "
  . 'qemu-system-riscv64: -vnc 0.0.0.0:14,password=on,audiodev=audio1: '
  . 'Cipher backend does not support DES algorithm';

my $domain_xml = <<'XML';
<domain type="kvm">
  <name>cn1</name>
  <devices>
    <emulator>/usr/local/bin/qemu-system-riscv64</emulator>
    <graphics type="vnc" autoport="yes" listen="127.0.0.1"/>
  </devices>
</domain>
XML

# Run makedom for node cn1 against $hyp, with the given vm table attributes.
sub run_makedom {
    my ($hyp, %vm) = @_;
    local $KVMMakedom::node     = 'cn1';
    local $KVMMakedom::hypconn  = $hyp;
    local $KVMMakedom::confdata = {
        vm       => { cn1 => [ { host => 'hyp1', %vm } ] },
        nodetype => { cn1 => [ { arch => 'riscv64' } ] },
    };
    return KVMMakedom::makedom('cn1', undef, $domain_xml);
}

sub graphics_attr {
    my ($xml, $name) = @_;
    my $element = XML::LibXML->new()->parse_string($xml)->findnodes('//graphics')->[0];
    return undef unless $element;
    return $element->getAttribute($name);
}

# An emulator without a DES cipher backend refuses to start a domain that carries a VNC
# password. The node must still come up.
my $rv = FakeHyp->new(reject => qr/passwd=/, message => $des_error);
my ($dom, $err) = run_makedom($rv);
is($err, undef, 'makedom reports no error when the emulator refuses the VNC password');
ok(defined($dom), 'makedom starts the domain when the emulator refuses the VNC password');
is(scalar(@{ $rv->{tried} }), 2, 'makedom starts the domain again without the VNC password');
is(graphics_attr($rv->{tried}->[-1], 'passwd'), undef,
    'the description that starts carries no VNC password');
is(graphics_attr($rv->{tried}->[-1], 'listen'), '0.0.0.0',
    'the description that starts still offers the console off the hypervisor');

# An emulator that takes a VNC password keeps it. The password must not be dropped here.
my $ok = FakeHyp->new();
($dom, $err) = run_makedom($ok);
is($err, undef, 'makedom reports no error on an emulator that takes a VNC password');
is(scalar(@{ $ok->{tried} }), 1, 'makedom starts the domain once');
is(graphics_attr($ok->{tried}->[-1], 'passwd'), 'genpw123',
    'the domain keeps its VNC password on an emulator that takes one');

# vm.vidpassword names the console password. It reaches the domain unchanged.
my $vid = FakeHyp->new();
($dom, $err) = run_makedom($vid, vidpassword => 'fromvmtable');
is(graphics_attr($vid->{tried}->[-1], 'passwd'), 'fromvmtable',
    'vm.vidpassword reaches the domain that starts');

# Any other libvirt error is reported. A domain must not lose its VNC password because of a
# failure that has nothing to do with the password.
my $other = FakeHyp->new(reject => qr/./, message => 'Cannot access storage file');
($dom, $err) = run_makedom($other);
like($err, qr/Cannot access storage file/, 'makedom reports an unrelated libvirt error');
is(scalar(@{ $other->{tried} }), 1, 'makedom does not retry after an unrelated libvirt error');

done_testing();
