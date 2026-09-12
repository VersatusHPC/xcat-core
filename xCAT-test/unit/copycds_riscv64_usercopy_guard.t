#!/usr/bin/env perl
# copycds refuses to read an ISO on a riscv64 node whose kernel still has the hardened
# usercopy check.
#
# copycds.pm needs a management node to load, so the guard is lifted out and run in a scratch
# package. BAIL_OUT when the extraction stops matching, so this fails loudly rather than
# covering nothing.
use strict;
use warnings;

use FindBin;
use Test::More;

my $source = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/copycds.pm";
open my $fh, '<', $source or die "open $source: $!";
my $content = do { local $/; <$fh> };
close $fh;

my ($routine) = $content =~ /^(sub riscv64_usercopy_guard\s*\{.*?^\})/ms;
BAIL_OUT('could not extract riscv64_usercopy_guard from copycds.pm') unless $routine;

{
    package CopycdsGuard;
    ## no critic (BuiltinFunctions::ProhibitStringyEval)
    eval "$routine\n1;\n" or Test::More::BAIL_OUT("could not load the guard: $@");
}

my $UNPROTECTED = 'BOOT_IMAGE=/boot/vmlinuz root=UUID=1 ro console=ttyS0,115200';
my $PROTECTED   = "$UNPROTECTED hardened_usercopy=off";

# ------------------------------------------------------------------ the node that panics --
my $err = CopycdsGuard::riscv64_usercopy_guard(
    machine => 'riscv64', cmdline => $UNPROTECTED);
ok( defined $err, 'riscv64 without the option is refused' );
like( $err, qr/hardened_usercopy=off/, 'the refusal names the option to set' );
like( $err, qr/grubby/,                'the refusal says how to set it' );
like( $err, qr/reboot/i,               'the refusal says a reboot is needed' );
like( $err, qr/panic/i,                'the refusal says what happens otherwise' );
like( $err, qr/--i-know-what-i-am-doing/, 'the refusal names the way to continue anyway' );

# ------------------------------------------------------------------- the node that is safe --
is( CopycdsGuard::riscv64_usercopy_guard(machine => 'riscv64', cmdline => $PROTECTED),
    undef, 'riscv64 with the option runs' );

# The option must be its own word. A kernel command line that merely mentions it elsewhere,
# or sets it to on, is not protection.
ok( defined CopycdsGuard::riscv64_usercopy_guard(
        machine => 'riscv64', cmdline => "$UNPROTECTED hardened_usercopy=on"),
    'hardened_usercopy=on is still refused' );
ok( defined CopycdsGuard::riscv64_usercopy_guard(
        machine => 'riscv64', cmdline => "$UNPROTECTED xhardened_usercopy=off"),
    'a substring of another option is not the option' );

# --------------------------------------------------------------------- every other machine --
for my $machine (qw(x86_64 ppc64le aarch64 s390x)) {
    is( CopycdsGuard::riscv64_usercopy_guard(machine => $machine, cmdline => $UNPROTECTED),
        undef, "$machine is not affected and runs" );
}

# ------------------------------------------------------------------------------ the bypass --
is( CopycdsGuard::riscv64_usercopy_guard(
        machine => 'riscv64', cmdline => $UNPROTECTED, override => 1),
    undef, '--i-know-what-i-am-doing runs the command anyway' );

done_testing();
