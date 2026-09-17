#!/usr/bin/env perl
use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

# use lib runs at compile time. A "my" lexical assigned on an earlier line is
# still undef then, so use lib "$xcatroot/xdsh" put a rootless "/xdsh" on @INC.
# require Context::XCAT in DSHCLI.pm then failed to resolve and every xdsh to a
# node died with "Can't locate Context/XCAT.pm".
#
# The header of each script is executed here, not read, so the test measures the
# include path instead of matching the text that builds it.

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..', '..' );
die "Unable to resolve the repository root from $FindBin::Bin" unless -d $repo_root;

# DSHCLI resolves its contexts with require, so every program that loads it has
# to carry $XCATROOT/xdsh on @INC itself.
my @scripts = qw(
  xCAT-client/bin/xdsh
  xCAT-client/bin/xdshbak
  xCAT-client/bin/genimage
  xCAT-server/sbin/xcatd
);

sub header_through_last_use_lib {
    my ($path) = @_;
    open( my $fh, '<', $path ) or die "Unable to read $path: $!";
    my @lines = <$fh>;
    close($fh);

    my $last;
    for my $i ( 0 .. $#lines ) {
        $last = $i if $lines[$i] =~ /^\s*use\s+lib\b/;
    }
    die "$path has no 'use lib' line; this test no longer matches the file"
      unless defined $last;

    return join( '', @lines[ 0 .. $last ] );
}

my $root = tempdir( CLEANUP => 1 );

foreach my $rel (@scripts) {
    my $path = File::Spec->catfile( $repo_root, $rel );
  SKIP: {
        skip "$rel is not in this checkout", 2 unless -f $path;

        my $header = header_through_last_use_lib($path);

        my $probe = File::Temp->new( SUFFIX => '.pl' );
        print {$probe} $header, "\nprint join(qq{\\n}, \@INC), qq{\\n};\n";
        $probe->close;

        local $ENV{XCATROOT} = $root;
        my @inc = split( /\n/, `$^X $probe 2>&1` );

        ok( ( grep { $_ eq "$root/xdsh" } @inc ),
            "$rel puts \$XCATROOT/xdsh on \@INC" )
          or diag( "\@INC was:\n  " . join( "\n  ", @inc ) );

        ok( !( grep { $_ eq '/xdsh' } @inc ),
            "$rel does not put a rootless /xdsh on \@INC" );
    }
}

done_testing();
