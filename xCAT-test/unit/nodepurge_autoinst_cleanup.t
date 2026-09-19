#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(mkpath);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

# Regression: nodepurge left the autoinstall configuration of an Ubuntu node on disk.
#
# debian.pm:1157 calls mkpath for a Subiquity node, so /install/autoinst/<node> is a
# DIRECTORY holding meta-data, user-data and vendor-data. nodepurge removed the node with
# unlink, which cannot remove a directory, so user-data stayed behind with the root password
# hash of a node that no longer exists. The preseed path writes a plain file and is removed
# correctly, which is why no EL cell reports this.
#
# Seen on ubuntu-24-x86_64-devel: after `nodepurge testnode1,testnode2`,
# `ls /install/autoinst/testnode1*` still listed meta-data, user-data and vendor-data.

my $repo_root = File::Spec->rel2abs(
    File::Spec->catdir( $FindBin::Bin, '..', '..' )
);
my $plugin = File::Spec->catfile(
    $repo_root, 'xCAT-server', 'lib', 'xcat', 'plugins', 'profilednodes.pm'
);
plan skip_all => "profilednodes.pm not found" unless -f $plugin;

my $src = do { local $/; open my $fh, '<', $plugin or die $!; <$fh> };

# Lift the routine into a scratch package: profilednodes.pm needs a management node to load.
# die rather than skip, so a rename fails loudly instead of silently covering nothing.
my ($body) = $src =~ /\n(sub remove_node_config_files \{.*?\n\})\n/s;
die "could not extract remove_node_config_files from profilednodes.pm\n"
  unless defined $body;

{
    package T;
    use File::Path qw(rmtree);
    eval "$body; 1" or die "could not eval remove_node_config_files: $@\n";
}

my $dir = tempdir( CLEANUP => 1 );

# A Subiquity node: the configuration is a directory.
mkpath("$dir/subiquitynode");
for my $f (qw(meta-data user-data vendor-data)) {
    open my $fh, '>', "$dir/subiquitynode/$f" or die $!;
    print {$fh} "x\n";
    close $fh;
}

# A preseed node: the configuration is a plain file, with its .pre and .post scripts.
for my $f (qw(preseednode preseednode.pre preseednode.post)) {
    open my $fh, '>', "$dir/$f" or die $!;
    print {$fh} "x\n";
    close $fh;
}

# A node that was never installed leaves nothing, and must not make the routine die.
T::remove_node_config_files( $dir, [ 'subiquitynode', 'preseednode', 'neverinstalled' ] );

ok( !-e "$dir/subiquitynode",
    'the autoinstall directory of a Subiquity node is removed' );
ok( !-e "$dir/preseednode",
    'the autoinstall file of a preseed node is removed' );
ok( !-e "$dir/preseednode.pre",  'the .pre script is removed' );
ok( !-e "$dir/preseednode.post", 'the .post script is removed' );

# The routine takes a node list, so it must not walk outside the names it was given.
open my $keep, '>', "$dir/othernode" or die $!;
print {$keep} "x\n";
close $keep;
T::remove_node_config_files( $dir, ['neverinstalled'] );
ok( -e "$dir/othernode", 'a node that was not named keeps its configuration' );

done_testing();
