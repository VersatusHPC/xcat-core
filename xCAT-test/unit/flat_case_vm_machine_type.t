#!/usr/bin/env perl
use strict;
use warnings;

use File::Temp qw(tempdir);
use FindBin;
use Test::More;

# reg_linux_diskless_installation_flat sets vm.othersettings to a valid machine
# type, then checks that the attribute holds one. The set command picks the type
# from the node architecture, so an architecture it does not name leaves the
# attribute empty and the check that follows fails. Run the case's own shell
# with lsdef and chdef shadowed, and read what it asks chdef to store.

my $CASE = "$FindBin::Bin/../autotest/testcase/installation/reg_linux_diskless_installation_flat";

plan tests => 9;

my @cmds = _case_commands($CASE);
my ($set)    = grep { /str2="machine:invalid"/ } @cmds;
my ($verify) = grep { /\$str =~ "machine"/ } @cmds;
my ($unset)  = grep { /str2=";"/ and /if \[ \$str1 == \$str3 \]/ } @cmds;

BAIL_OUT("the vm.othersettings commands are no longer in $CASE")
  unless ($set and $verify and $unset);

for my $arch (qw(riscv64 x86_64 ppc64le)) {
    my $stored = _run_set($set, $arch, "machine:invalid");
    like($stored, qr/machine:\S/, "$arch: the set command stores a machine type");

    my $rc = _run_verify($verify, $arch, $stored);
    is($rc, 0, "$arch: the check that follows the set command passes");

    my $left = _run_set($unset, $arch, $stored);
    unlike($left, qr/machine:/,
        "$arch: the unset command takes the machine type back out");
}

# Build one scratch tree per run so a test can never write outside it.
sub _run_set {
    my ($cmd, $arch, $current) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $out = _bash($cmd, $arch, $dir, "    vmothersetting=$current");
    my $stored = '';
    if (open(my $fh, '<', "$dir/chdef.args")) {
        $stored = do { local $/; <$fh> };
        close($fh);
    }
    chomp $stored;
    $stored =~ s/^.*vmothersetting=//s;
    return $stored;
}

sub _run_verify {
    my ($cmd, $arch, $stored) = @_;
    my $dir = tempdir(CLEANUP => 1);
    return _bash($cmd, $arch, $dir, "    vmothersetting=$stored");
}

sub _bash {
    my ($cmd, $arch, $dir, $lsdef_out) = @_;
    $cmd =~ s/__GETNODEATTR\(\$\$CN,mgt\)__/kvm/g;
    $cmd =~ s/__GETNODEATTR\(\$\$CN,arch\)__/$arch/g;
    $cmd =~ s/\$\$CN/cn1/g;

    my $script = "$dir/drive.sh";
    open(my $fh, '>', $script) or die "cannot write $script: $!";
    print $fh <<"SH";
lsdef() { printf '%s\\n' '$lsdef_out'; }
chdef() { printf '%s\\n' "\$*" > $dir/chdef.args; }
$cmd
SH
    close($fh);
    system("bash", $script);
    return $? >> 8;
}

sub _case_commands {
    my ($path) = @_;
    open(my $fh, '<', $path) or BAIL_OUT("cannot read $path: $!");
    my @cmds;
    while (my $line = <$fh>) {
        chomp $line;
        push @cmds, $1 if $line =~ /^cmd:(.*)$/;
    }
    close($fh);
    return @cmds;
}
