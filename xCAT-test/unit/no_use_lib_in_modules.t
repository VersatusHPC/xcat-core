#!/usr/bin/env perl
use strict;
use warnings;

use File::Find;
use File::Spec;
use FindBin;
use Test::More;

# A module that calls "use lib" rewrites @INC while it compiles, after the caller
# has already set its own. The caller then cannot choose where the modules it
# loads come from: use lib, -I and PERL5LIB all lose to the later prepend. Only an
# entry point may set the include path.

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..', '..' );
die "Unable to resolve the repository root from $FindBin::Bin" unless -d $repo_root;

my @offenders;
my $scanned = 0;

find(
    {
        no_chdir => 1,
        wanted   => sub {
            return unless /\.pm$/;
            return if $File::Find::name =~ m{/(?:dist|\.git)/};
            $scanned++;
            open( my $fh, '<', $File::Find::name ) or die "Unable to read $File::Find::name: $!";
            while ( my $line = <$fh> ) {
                next if $line =~ /^\s*#/;
                next unless $line =~ /^\s*use\s+lib\b/;
                ( my $rel = $File::Find::name ) =~ s{^\Q$repo_root\E/}{};
                push @offenders, "$rel:$.: $line";
            }
            close($fh);
        },
    },
    $repo_root
);

cmp_ok( $scanned, '>', 300, 'the scan reached the perl modules' );
is( scalar(@offenders), 0, 'no perl module calls use lib' )
  or diag( "use lib belongs in an entry point, not a module:\n" . join( '', @offenders ) );

done_testing();
