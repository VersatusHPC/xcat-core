#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(mkpath);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

# Regression: the four encrypted_passwd_*_diskfull cases read /install/autoinst/<node> as a
# file. debian.pm:1157 calls mkpath for a Subiquity node, so on Ubuntu that path is a
# DIRECTORY and the hash is in user-data inside it. The cases reported
# "grep: /install/autoinst/xcat24-cn: Is a directory" on every Ubuntu x86_64 cell, while the
# product wrote the hash correctly -- compute.subiquity.tmpl:21 carries the
# CRYPTORLOCKED passwd substitution.
#
# The commands are driven here against a scratch tree in both layouts, so the case stops
# depending on which distribution installed the management node.

my $repo_root = File::Spec->rel2abs(
    File::Spec->catdir( $FindBin::Bin, '..', '..' )
);
my $case_file = File::Spec->catfile(
    $repo_root, 'xCAT-test', 'autotest', 'testcase', 'passwd', 'case0'
);
plan skip_all => "passwd/case0 not found" unless -f $case_file;

my $src = do { local $/; open my $fh, '<', $case_file or die $!; <$fh> };

# The hash-reading command of each case, lifted from the case file. die when a case or its
# command stops matching, so a rename fails loudly instead of silently covering nothing.
my %HASH_PREFIX = (
    encrypted_passwd_md5_diskfull     => '$1$',
    encrypted_passwd_sha256_diskfull  => '$5$',
    encrypted_passwd_sha512_diskfull  => '$6$',
    encrypted_passwd_openssl_diskfull => '$6$',
);

sub autoinst_command {
    my ($case) = @_;
    my ($block) = $src =~ /^start:\Q$case\E$(.*?)^end$/ms;
    die "could not find case $case in passwd/case0\n" unless defined $block;
    my @cmds = grep { /autoinst/ } ( $block =~ /^cmd:(.*)$/mg );
    die "expected one autoinst command in $case, found " . scalar(@cmds) . "\n"
      unless @cmds == 1;
    return $cmds[0];
}

# Point every absolute path the command names at the scratch tree. A rewrite that stops
# matching must abort the test: CI runs as root, and a command still naming /install or /etc
# would act on the host.
sub sandbox {
    my ( $cmd, $root ) = @_;
    $cmd =~ s{/install/autoinst/}{$root/install/autoinst/}g;
    $cmd =~ s{/etc/\*release}{$root/etc/*release}g;
    $cmd =~ s{/tmp/instcryptedpasswd}{$root/instcryptedpasswd}g;
    $cmd =~ s/\$\$CN/testnode/g;
    die "sandbox left a real path in: $cmd\n"
      if $cmd =~ m{(?<!\Q$root\E)/install/autoinst} or $cmd =~ m{(?<!\Q$root\E)/etc/\*release};
    die "sandbox did not reach the autoinst path in: $cmd\n"
      unless $cmd =~ m{\Q$root\E/install/autoinst};
    return $cmd;
}

# $flavour is the autoinstall the management node writes for that node: 'subiquity' is a
# directory of cloud-init files, 'preseed' and 'kickstart' are plain files.
sub build_tree {
    my ( $root, $flavour, $hash ) = @_;
    my %RELEASE = (
        subiquity => qq{NAME="Ubuntu"\nVERSION="24.04.4 LTS (Noble Numbat)"\nID=ubuntu\n},
        preseed   => qq{NAME="Ubuntu"\nVERSION="20.04.6 LTS (Focal Fossa)"\nID=ubuntu\n},
        kickstart => qq{NAME="AlmaLinux"\nVERSION="9.4 (Seafoam Ocelot)"\nID="almalinux"\n},
    );
    mkpath("$root/etc");
    open my $rel, '>', "$root/etc/os-release" or die $!;
    print {$rel} $RELEASE{$flavour};
    close $rel;

    mkpath("$root/install/autoinst");
    if ( $flavour eq 'subiquity' ) {
        mkpath("$root/install/autoinst/testnode");
        open my $ud, '>', "$root/install/autoinst/testnode/user-data" or die $!;
        print {$ud} qq{#cloud-config\nautoinstall:\n  identity:\n    password: "$hash"\n};
        print {$ud} qq{  user-data:\n    chpasswd:\n      list:\n        - "root:$hash"\n};
        close $ud;
    }
    else {
        my $line =
          $flavour eq 'preseed'
          ? "d-i passwd/root-password-crypted password $hash\n"
          : "rootpw --iscrypted $hash\n";
        open my $fh, '>', "$root/install/autoinst/testnode" or die $!;
        print {$fh} $line;
        close $fh;
    }
}

my @FLAVOURS = (
    [ subiquity => 'the autoinstall directory of a Subiquity node' ],
    [ preseed   => 'the preseed file of an Ubuntu node' ],
    [ kickstart => 'the kickstart file of an EL node' ],
);

for my $case ( sort keys %HASH_PREFIX ) {
    my $hash = $HASH_PREFIX{$case} . 'rAnDoMsAlT$QQQQQQQQQQQQQQQQQQQQQQQQQQQQ';
    my $cmd  = autoinst_command($case);

    for my $f (@FLAVOURS) {
        my ( $flavour, $what ) = @$f;
        my $root = tempdir( CLEANUP => 1 );
        build_tree( $root, $flavour, $hash );
        my $rc = system( 'sh', '-c', sandbox( $cmd, $root ) . ' >/dev/null 2>&1' );
        is( $rc, 0, "$case finds the hash in $what" );
    }
}

# The openssl case does not only grep: it extracts the hash and diffs it against the passwd
# table. A wrong field index gives rc=0 on the grep and the wrong string here.
{
    my $case = 'encrypted_passwd_openssl_diskfull';
    my $hash = '$6$rAnDoMsAlT$QQQQQQQQQQQQQQQQQQQQQQQQQQQQ';
    my $cmd  = autoinst_command($case);

    for my $f (@FLAVOURS) {
        my ( $flavour, $what ) = @$f;
        my $root = tempdir( CLEANUP => 1 );
        build_tree( $root, $flavour, $hash );
        system( 'sh', '-c', sandbox( $cmd, $root ) . ' >/dev/null 2>&1' );
        my $got = '';
        if ( open my $fh, '<', "$root/instcryptedpasswd" ) {
            $got = do { local $/; <$fh> };
            chomp $got;
        }
        is( $got, $hash, "$case extracts the hash itself from $what" );
    }
}

done_testing();
