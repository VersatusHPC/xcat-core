#!/usr/bin/env perl
use strict;
use warnings;

use File::Find;
use File::Spec;
use FindBin;
use Test::More;

# A module that reads $::XCATROOT without setting it depends on whoever loaded
# it to have set the global first. xcatd did, so such a module worked under the
# daemon and nowhere else. It stopped working under the daemon too when xcatd
# briefly held the root in a lexical: a lexical does not cross into a required
# file, so mknb.pm asked for /share/xcat/netboot instead of
# /opt/xcat/share/xcat/netboot, and no test noticed.
#
# Every module now reads the environment itself, so this class is empty. This
# test keeps it empty. A module that sets the global before reading it is
# self-sufficient and is not the problem.

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..', '..' );
die "Unable to resolve the repository root from $FindBin::Bin" unless -d $repo_root;

sub slurp {
    my ($path) = @_;
    open( my $fh, '<', $path ) or die "Unable to read $path: $!";
    my $text = do { local $/; <$fh> };
    close($fh);
    return $text;
}

my ( @consumers, $scanned );
find(
    {
        no_chdir => 1,
        wanted   => sub {
            return unless /\.pm$/;
            return if $File::Find::name =~ m{/(?:dist|\.git|xCAT-rmc)/};
            $scanned++;

            my $text = slurp($File::Find::name);
            return if $text =~ /\$::XCATROOT\s*=/;

            my @live = grep { !/^\s*#/ && /\$::XCATROOT/ } split( /\n/, $text );
            return unless @live;

            ( my $rel = $File::Find::name ) =~ s{^\Q$repo_root\E/}{};
            push @consumers, "$rel: $live[0]";
        },
    },
    $repo_root
);

# A floor, so a misrooted or silently empty scan fails here instead of
# reporting that nothing reads the global.
cmp_ok( $scanned, '>', 200, 'the scan reached the perl modules' );

is( scalar(@consumers), 0, 'no perl module reads $::XCATROOT without setting it' )
  or diag( "these modules need their loader to set the global:\n  "
      . join( "\n  ", @consumers ) );

done_testing();
