#!/usr/bin/env perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT::Build::Repository;

use strict;
use warnings;
use Exporter qw(import);
use File::Copy qw(copy);

our @EXPORT_OK = qw(
  default_packages finalize_repository remove_release_alias write_release_alias
);

sub default_packages {
    return qw(
      perl-xCAT xCAT xCATsn xCAT-buildkit xCAT-client xCAT-confluent
      xCAT-genesis-scripts xCAT-openbmc-py xCAT-probe xCAT-rmc xCAT-server
      xCAT-test xCAT-vlan xCAT-release
    );
}

sub write_release_alias {
    my ($repodir, $version, $release) = @_;
    my $alias = "$repodir/xCAT-release-latest.noarch.rpm";
    my @release_rpms = grep { -f }
      glob("$repodir/xCAT-release-$version-$release.noarch.rpm");
    return 0 unless @release_rpms == 1;

    copy($release_rpms[0], $alias)
      or die "copy $release_rpms[0] -> $alias: $!";
    chmod(0644, $alias) or die "chmod $alias: $!";
    return 1;
}

sub remove_release_alias {
    my ($repodir) = @_;
    my $alias = "$repodir/xCAT-release-latest.noarch.rpm";
    return 0 unless -e $alias;

    unlink($alias) or die "unlink $alias: $!";
    return 1;
}

sub finalize_repository {
    my (%step) = @_;
    $step{index}->();
    $step{sign}->() if $step{sign};
    $step{metadata}->();
    $step{alias}->();
    return;
}

1;
