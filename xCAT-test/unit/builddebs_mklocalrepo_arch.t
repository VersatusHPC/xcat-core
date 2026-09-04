#!/usr/bin/perl
#
# mklocalrepo.sh points apt at the local repo the build produced. It maps the
# machine name uname reports to the Debian architecture name apt asks for. A
# machine the map does not know gets amd64, and apt then reports "Unable to
# locate package xcat" on a repo that does carry the right deb.
#
# builddebs.pl emits the script as text, so the test extracts that text, runs it
# with uname shadowed, and reads the architecture it wrote.

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Basename qw(dirname);
use File::Spec;

my $root = File::Spec->rel2abs(dirname(__FILE__) . '/../..');
my $builder = "$root/builddebs.pl";
plan skip_all => "builddebs.pl is not in this tree" unless -f $builder;

open my $fh, '<', $builder or die "read $builder: $!";
my $text = do { local $/; <$fh> };
close $fh;

my ($script) = $text =~ /write_script\(\s*"\$repodir\/mklocalrepo\.sh",\s*<<'SCRIPT'\);\n(.*?)\nSCRIPT\n/s;
BAIL_OUT("the mklocalrepo.sh heredoc in builddebs.pl stopped matching") unless $script;

# Two couplings to the host are replaced, and nothing else: the lsb-release read
# and the write into /etc. Both substitutions must match, or the test measures a
# script it did not intend to run.
my $dir = tempdir(CLEANUP => 1);
my $out = "$dir/xcat-core.list";
my $subs = ($script =~ s{^\. /etc/lsb-release$}{DISTRIB_CODENAME=noble}m)
         + ($script =~ s{> /etc/apt/sources\.list\.d/xcat-core\.list}{> "$out"});
BAIL_OUT("the mklocalrepo.sh host couplings stopped matching") unless $subs == 2;

my $bin = "$dir/bin";
mkdir $bin or die $!;

# uname -m is the input under test. bash finds the shadow ahead of PATH.
sub arch_for {
    my ($machine) = @_;
    open my $u, '>', "$bin/uname" or die $!;
    print $u "#!/bin/sh\necho $machine\n";
    close $u;
    chmod 0755, "$bin/uname" or die $!;
    unlink $out;

    open my $s, '>', "$dir/mklocalrepo.sh" or die $!;
    print $s $script;
    close $s;
    chmod 0755, "$dir/mklocalrepo.sh" or die $!;

    system("PATH=$bin:\$PATH /bin/sh $dir/mklocalrepo.sh") == 0
      or die "mklocalrepo.sh failed for $machine";
    open my $r, '<', $out or die "no sources list written for $machine: $!";
    my $line = <$r>;
    close $r;
    chomp $line;
    my ($arch) = $line =~ /\[arch=(\S+)\]/;
    return ($arch, $line);
}

my %expected = (
    'x86_64'  => 'amd64',
    'ppc64le' => 'ppc64el',
    'riscv64' => 'riscv64',
);

for my $machine (sort keys %expected) {
    my ($arch, $line) = arch_for($machine);
    is($arch, $expected{$machine},
        "mklocalrepo.sh asks apt for $expected{$machine} on a $machine machine");
    like($line, qr/^deb \[arch=\S+\] file:\/\/.* noble main$/,
        "the sources.list entry for $machine keeps its shape");
}

done_testing();
