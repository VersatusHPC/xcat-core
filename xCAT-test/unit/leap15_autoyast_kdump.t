#!/usr/bin/env perl
#
# The Leap 15 AutoYaST profiles and kdump.
#
# The @base pattern installs kdump, and YaST enables kdump.service and kdump-early.service when
# the profile has no <kdump> section. The <bootloader><append> of the profile replaces the kernel
# command line that YaST proposes, so no crashkernel= reaches the node, and both units fail at
# every boot with "Memory for crashkernel is not reserved".
use strict;
use warnings;

use FindBin;
use Test::More;
use XML::Simple qw(XMLin);

my $dir = "$FindBin::Bin/../../xCAT-server/share/xcat/install/sles";

for my $tmpl (qw(compute.leap15.tmpl service.leap15.tmpl)) {
    my $profile = XMLin("$dir/$tmpl", KeepRoot => 0, ForceArray => 0);
    my $kdump = $profile->{kdump};
    ok(ref($kdump) eq 'HASH', "$tmpl has a <kdump> section");
    my $add = ref($kdump) eq 'HASH' ? $kdump->{add_crash_kernel} : undef;
    is(ref($add) eq 'HASH' ? $add->{content} : $add, 'false', "$tmpl does not add a crash kernel");
    is(ref($add) eq 'HASH' ? $add->{'config:type'} : undef, 'boolean', "$tmpl types add_crash_kernel as a boolean");
}

done_testing();
