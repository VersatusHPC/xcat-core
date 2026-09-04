#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

my $source = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/destiny.pm";
open(my $source_fh, '<', $source) or die "open $source: $!";
my $content = do { local $/; <$source_fh> };
close($source_fh) or die "close $source: $!";

my ($routine) =
  $content =~ /^(sub _genesis_runimage_refusal\s*\{.*?^\})/ms;
BAIL_OUT('could not extract _genesis_runimage_refusal from destiny.pm')
  unless $routine;
eval $routine;    ## no critic (BuiltinFunctions::ProhibitStringyEval)
BAIL_OUT("could not load the runimage refusal helper: $@") if $@;

my $tftp = tempdir(CLEANUP => 1);
make_path("$tftp/xcat");

sub write_marker {
    my ($arch) = @_;
    open(my $fh, '>', "$tftp/xcat/genesis.exact-arch.$arch")
      or die "create the Genesis export marker for $arch: $!";
    close($fh) or die "close the Genesis export marker for $arch: $!";
    return;
}

is(
    _genesis_runimage_refusal($tftp, 'x86_64'),
    undef,
    'the legacy Genesis image accepts runimage',
);

write_marker('ppc64le');
is(
    _genesis_runimage_refusal($tftp, 'x86_64'),
    undef,
    'an export for another architecture does not refuse runimage',
);

write_marker('x86_64');
my $refusal = _genesis_runimage_refusal($tftp, 'x86_64');
ok(defined($refusal), 'the OpenEmbedded Genesis image refuses runimage');
like($refusal, qr/runimage/, 'the refusal names the rejected task');
like($refusal, qr/OpenEmbedded/, 'the refusal names the Genesis generation');
like($refusal, qr/x86_64/, 'the refusal names the architecture');
like($refusal, qr/runcmd/, 'the refusal names a task the image does run');

like(
    $content,
    qr/_genesis_runimage_refusal\(\$tftpdir, \$arch\)/,
    'setdestiny asks the tested helper before it accepts runimage',
);

done_testing();
