#!/usr/bin/env perl
use strict;
use warnings;

use File::Find;
use File::Spec;
use FindBin;
use Test::More;

# Six modules read $::XCATROOT without ever setting it: esx.pm, PPC.pm,
# conserver.pm, mknb.pm, xnba.pm and FSPcfg.pm. They are loaded with require by
# a program that has already set the global, and a require'd file cannot see a
# lexical, so whoever loads them has to set it.
#
# Replacing the global with a lexical in xcatd left those modules reading undef,
# and mknb.pm asked for /share/xcat/netboot instead of /opt/xcat/share/xcat/
# netboot. No test noticed: nothing here loads a plugin under a daemon, and the
# two mknb tests set the global themselves.

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..', '..' );
die "Unable to resolve the repository root from $FindBin::Bin" unless -d $repo_root;

sub slurp {
    my ($path) = @_;
    open( my $fh, '<', $path ) or die "Unable to read $path: $!";
    my $text = do { local $/; <$fh> };
    close($fh);
    return $text;
}

# Modules that read the global but never assign it. Anything loading these has
# to provide it.
my @consumers;
find(
    {
        no_chdir => 1,
        wanted   => sub {
            return unless /\.pm$/;
            return if $File::Find::name =~ m{/(?:dist|\.git|xCAT-rmc)/};
            my $text = slurp($File::Find::name);
            return if $text =~ /\$::XCATROOT\s*=/;
            my @live = grep { !/^\s*#/ && /\$::XCATROOT/ } split( /\n/, $text );
            return unless @live;
            ( my $rel = $File::Find::name ) =~ s{^\Q$repo_root\E/}{};
            push @consumers, $rel;
        },
    },
    $repo_root
);

cmp_ok( scalar(@consumers), '>', 0, 'found modules that read $::XCATROOT without setting it' )
  or diag('the search is wrong if this is zero, not the tree');

# Programs that load those modules with require. A plugin directory is loaded
# wholesale, so naming the directory is enough to count as a loader.
my @loaders = qw(
  xCAT-server/sbin/xcatd
  xCAT-server/sbin/xcat_traphandler
);

foreach my $rel (@loaders) {
    my $path = File::Spec->catfile( $repo_root, $rel );
    SKIP: {
        skip "$rel is not in this checkout", 2 unless -f $path;
        my $text = slurp($path);

        like( $text, qr/xCAT_plugin|plugins_dir/,
            "$rel still loads plugins, so this test still applies" );

        # A lexical is not enough. The global is what a require'd file can read.
        like(
            $text,
            qr/^\s*\$::XCATROOT\s*=/m,
            "$rel sets \$::XCATROOT for the modules it loads"
        ) or diag( "modules that would read undef:\n  " . join( "\n  ", @consumers ) );
    }
}

done_testing();
