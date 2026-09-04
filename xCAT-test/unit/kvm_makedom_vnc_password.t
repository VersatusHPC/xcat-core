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

# Helpers the fix may add. Each is pulled in when it exists so that this test measures the
# behaviour of makedom, not the presence of a subroutine.
my @routines = ($makedom);
for my $name (qw(vnc_password_rejected set_graphics_listen)) {
    my ($routine) = $content =~ /^(sub \Q$name\E\s*\{.*?^\})/ms;
    push(@routines, $routine) if $routine;
}

# kvm.pm needs a management node to load, so makedom runs in a scratch package. Only the
# routines that reach libvirt, the client or the xCAT database are replaced.
my $harness = <<'PERL';
package KVMMakedom;
use XML::LibXML;
our ($node, $confdata, $hypconn, $parser, $callback);
$parser = XML::LibXML->new();
sub genpassword { return 'genpw123'; }
sub refresh_vm  { return 1; }

package xCAT::MsgUtils;
sub trace   { return 1; }
sub message { return 1; }

package xCAT::SvrUtils;
our @sent;
sub sendmsg { my ($text, $cb, $n) = @_; push(@sent, { text => $text, node => $n }); return 1; }

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
    <graphics type="vnc" autoport="yes" listen="192.0.2.1"/>
  </devices>
</domain>
XML

# What mkvm stores in the kvm_nodedata table is a description libvirt itself wrote, and
# libvirt writes the listen address twice. It refuses a description where the attribute and
# the child element disagree:
#   graphics 'listen' attribute '127.0.0.1' must match 'address' attribute of first listen
#   element (found '0.0.0.0')
my $stored_domain_xml = <<'XML';
<domain type="kvm">
  <name>cn1</name>
  <devices>
    <emulator>/usr/local/bin/qemu-system-riscv64</emulator>
    <graphics type="vnc" port="5914" autoport="yes" listen="0.0.0.0">
      <listen type="address" address="0.0.0.0"/>
    </graphics>
  </devices>
</domain>
XML

# Run makedom for node cn1 against $hyp, with the given vm table attributes.
sub run_makedom {
    my ($hyp, %arg) = @_;
    my $xml = delete($arg{xml}) || $domain_xml;
    local $KVMMakedom::node     = 'cn1';
    local $KVMMakedom::hypconn  = $hyp;
    local $KVMMakedom::callback = sub { return 1; };
    local $KVMMakedom::confdata = {
        vm       => { cn1 => [ { host => 'hyp1', %arg } ] },
        nodetype => { cn1 => [ { arch => 'riscv64' } ] },
    };
    @xCAT::SvrUtils::sent = ();
    return KVMMakedom::makedom('cn1', undef, $xml);
}

sub graphics_attr {
    my ($xml, $name) = @_;
    my $element = XML::LibXML->new()->parse_string($xml)->findnodes('//graphics')->[0];
    return undef unless $element;
    return $element->getAttribute($name);
}

# The address libvirt binds the console to: the listen attribute, and the child listen
# element libvirt writes beside it. A description where the two disagree does not start, so
# both are read.
sub listen_addresses {
    my ($xml) = @_;
    my $element = XML::LibXML->new()->parse_string($xml)->findnodes('//graphics')->[0];
    return () unless $element;
    my @addresses = ($element->getAttribute('listen'));
    push(@addresses, $_->getAttribute('address')) for $element->findnodes('./listen');
    return @addresses;
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

# A console with no password is an unauthenticated root shell on the node, so a domain that
# gives up the password must not offer that console off the hypervisor.
is_deeply([ listen_addresses($rv->{tried}->[-1]) ], ['127.0.0.1'],
    'a console with no VNC password listens on the loopback address only');

# The operator has to learn that the console of the node is unlocked. rpower prints what
# makedom sends to the client; the syslog trace on the management node is not read by the
# caller.
is(scalar(@xCAT::SvrUtils::sent), 1, 'makedom warns the caller once about the unlocked console');
is($xCAT::SvrUtils::sent[0]->{node}, 'cn1', 'the warning names the node');
like($xCAT::SvrUtils::sent[0]->{text}, qr/VNC password/,
    'the warning tells the caller that the console has no VNC password');

# The stored description carries the listen address twice. Both copies must move together,
# or libvirt refuses the description and the node never starts.
my $stored = FakeHyp->new(reject => qr/passwd=/, message => $des_error);
($dom, $err) = run_makedom($stored, xml => $stored_domain_xml);
is($err, undef, 'makedom starts a stored domain description without the VNC password');
is_deeply([ listen_addresses($stored->{tried}->[-1]) ], [ '127.0.0.1', '127.0.0.1' ],
    'the listen attribute and the listen element agree on the loopback address');

# An emulator that takes a VNC password keeps it, and keeps the console reachable. Binding
# every console to the loopback address would break rvidconsole for every other node.
my $ok = FakeHyp->new();
($dom, $err) = run_makedom($ok);
is($err, undef, 'makedom reports no error on an emulator that takes a VNC password');
is(scalar(@{ $ok->{tried} }), 1, 'makedom starts the domain once');
is(graphics_attr($ok->{tried}->[-1], 'passwd'), 'genpw123',
    'the domain keeps its VNC password on an emulator that takes one');
is_deeply([ listen_addresses($ok->{tried}->[-1]) ], ['0.0.0.0'],
    'a console with a VNC password stays reachable off the hypervisor');
is(scalar(@xCAT::SvrUtils::sent), 0, 'makedom warns nobody when the VNC password is kept');

# vm.vidpassword names the console password. It reaches the domain unchanged.
my $vid = FakeHyp->new();
($dom, $err) = run_makedom($vid, vidpassword => 'fromvmtable');
is(graphics_attr($vid->{tried}->[-1], 'passwd'), 'fromvmtable',
    'vm.vidpassword reaches the domain that starts');

# Any other libvirt error is reported. A domain must not lose its VNC password, or its listen
# address, because of a failure that has nothing to do with the password.
my $other = FakeHyp->new(reject => qr/./, message => 'Cannot access storage file');
($dom, $err) = run_makedom($other);
like($err, qr/Cannot access storage file/, 'makedom reports an unrelated libvirt error');
is(scalar(@{ $other->{tried} }), 1, 'makedom does not retry after an unrelated libvirt error');
is_deeply([ listen_addresses($other->{tried}->[-1]) ], ['0.0.0.0'],
    'an unrelated libvirt error does not move the console to the loopback address');

done_testing();
