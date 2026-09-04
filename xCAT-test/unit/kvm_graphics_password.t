#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use Test::More;

# The scratch package below declares these; the test names them once each.
no warnings 'once';

my $source = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/kvm.pm";
open(my $source_fh, '<', $source) or die "open $source: $!";
my $content = do { local $/; <$source_fh> };
close($source_fh) or die "close $source: $!";

my @routines;
for my $name (qw(build_xmldesc guest_arch_profile build_oshash build_diskstruct getUnits)) {
    my ($routine) = $content =~ /^(sub \Q$name\E\s*\{.*?^\})/ms;
    BAIL_OUT("could not extract $name from kvm.pm") unless $routine;
    push(@routines, $routine);
}

# kvm.pm needs a management node to load, so the domain builder runs in a scratch package.
my $harness = <<'PERL';
package KVMGraphics;
use XML::Simple qw(XMLout);
our ($node, $confdata, $updatetable, $hypconn);
sub getNodeUUID      { return '00000000-0000-0000-0000-000000000002'; }
sub get_multiple_paths_by_url { return {}; }
sub build_nicstruct  { return []; }
sub genpassword      { return 'generated'; }
PERL

eval $harness . join("\n", @routines) . "\n1;\n";    ## no critic (BuiltinFunctions::ProhibitStringyEval)
BAIL_OUT("could not load the kvm domain builder: $@") if $@;

# Build one domain description for a node of $guest_arch with the given vm table attributes.
sub domain_xml {
    my ($guest_arch, %vm) = @_;
    local $KVMGraphics::node     = 'cn1';
    local $KVMGraphics::confdata = {
        vm       => { cn1 => [ { host => 'hyp1', memory => 8192, cpus => 4, %vm } ] },
        nodetype => { cn1 => [ { arch => $guest_arch, os => 'rocky10.2' } ] },
        hyp1     => { cpumodel => 'x86_64' },
    };
    local $KVMGraphics::updatetable = {};
    my $xml = KVMGraphics::build_xmldesc('cn1');
    BAIL_OUT("build_xmldesc returned no XML for $guest_arch")
      unless defined $xml and !ref $xml;
    return $xml;
}

sub graphics_element {
    my ($xml) = @_;
    my ($element) = $xml =~ m{(<graphics\b[^>]*>)}s;
    BAIL_OUT('build_xmldesc produced no graphics element') unless defined $element;
    return $element;
}

# The attribute libvirt reads is "passwd". libvirt drops "password" silently, so a password
# written here has never reached a domain; makedom sets the real attribute on the running
# domain. A password in this description would also reach every emulator that cannot do VNC
# password authentication, such as a qemu built without a cipher backend.
for my $arch (qw(riscv64 x86_64)) {
    my $graphics = graphics_element(domain_xml($arch));
    like($graphics, qr/\btype="vnc"/,
        "a $arch domain description offers a vnc console");
    unlike($graphics, qr{\b(?:passwd|password)=},
        "a $arch domain description carries no VNC password attribute");
}

# vm.vidpassword names the password for rvidconsole. It is applied to the running domain, not
# written into the description that xCAT stores in the kvm_nodedata table.
my $graphics = graphics_element(domain_xml('x86_64', vidpassword => 'fromvmtable'));
unlike($graphics, qr/fromvmtable/,
    'vm.vidpassword is not written into the stored domain description');

done_testing();
