#!/usr/bin/env perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT::Genesis;

use strict;
use warnings;

sub boot_arch {
    my ($directory, $requested_arch) = @_;
    my $arch = $requested_arch eq 'ppc64el' ? 'ppc64le' : $requested_arch;

    if ($arch eq 'ppc64le'
        && !-r "$directory/xcat/genesis.kernel.ppc64le"
        && !-r "$directory/xcat/genesis.exact-arch.ppc64") {
        return 'ppc64';
    }
    return $arch;
}

sub uses_power_console {
    my ($arch) = @_;
    return $arch eq 'ppc64' || $arch eq 'ppc64le';
}

sub installed_architectures {
    my ($xcatroot) = @_;
    my @supported = qw(aarch64 armv7hf ppc64 ppc64le riscv64 x86 x86_64);
    my %supported = map { $_ => 1 } @supported;
    my %installed;

    my $openembedded = "$xcatroot/share/xcat/netboot/genesis-openembedded";
    if (opendir(my $dh, $openembedded)) {
        while (my $entry = readdir($dh)) {
            next unless $supported{$entry};
            my $path = "$openembedded/$entry";
            $installed{$entry} = 1 if -d $path && !-l $path;
        }
        closedir($dh);
    }

    my $legacy = "$xcatroot/share/xcat/netboot/genesis";
    foreach my $arch (@supported) {
        my $path = "$legacy/$arch";
        $installed{$arch} = 1 if -d $path;
    }

    return grep { $installed{$_} } @supported;
}

sub architectures_to_build {
    my ($xcatroot, $include_legacy) = @_;
    my @installed = installed_architectures($xcatroot);
    return @installed if $include_legacy;

    return grep {
        -d "$xcatroot/share/xcat/netboot/genesis-openembedded/$_"
          && !-l "$xcatroot/share/xcat/netboot/genesis-openembedded/$_"
    } @installed;
}

1;
