#!/usr/bin/env perl
use strict;
use warnings;

use File::Find;
use File::Spec;
use FindBin;
use Test::More;

# A BEGIN block runs at compile time. A "my" lexical declared below it is not
# assigned yet, and in a file where "use strict" comes later the name resolves
# to an undefined package global instead of failing, so the mistake is silent.
#
# buildkit hit exactly this: $::XCATSHARE = $xcatroot . '/share/xcat' inside a
# BEGIN, with "my $xcatroot" declared below it. $::XCATSHARE became
# '/share/xcat' and the script copied its kit templates from there.
#
# xdsh_context_include_path.t covers the same class for four named programs by
# executing them. This test is the general rule and needs no execution: it is a
# structural fact about where a name is declared.
#
# An "our" declaration is a different variable. It aliases a package global, so
# a BEGIN may read it freely; only a "my" declared below the block is a defect.

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..', '..' );
die "Unable to resolve the repository root from $FindBin::Bin" unless -d $repo_root;

sub begin_blocks {
    my ($lines) = @_;
    my @blocks;
    for my $i ( 0 .. $#$lines ) {
        next unless $lines->[$i] =~ /^\s*BEGIN\b/;
        my ( $depth, $seen ) = ( 0, 0 );
        for my $j ( $i .. $#$lines ) {
            $depth += ( $lines->[$j] =~ tr/{// );
            $depth -= ( $lines->[$j] =~ tr/}// );
            $seen = 1 if $lines->[$j] =~ /\{/;
            if ( $seen && $depth <= 0 ) { push @blocks, [ $i, $j ]; last }
        }
    }
    return @blocks;
}

my ( @offenders, $scanned );
find(
    {
        no_chdir => 1,
        wanted   => sub {
            return unless -f $_;
            return if $File::Find::name =~ m{/(?:dist|\.git|xCAT-rmc)/};
            return unless /\.(?:pm|pl|t)$/ || -x $File::Find::name;

            open( my $fh, '<', $File::Find::name ) or return;
            my @lines = <$fh>;
            close($fh);
            return unless grep { /^\s*BEGIN\b/ } @lines;
            $scanned++;

            my @blocks = begin_blocks( \@lines );
            return unless @blocks;

            # File scope "my" declarations, and every name ever declared "our".
            my ( %my_at, %is_our );
            for my $i ( 0 .. $#lines ) {
                $is_our{$1} = 1 while $lines[$i] =~ /\bour\s*\(?\s*([\$\@\%]\w+)/g;
                next if grep { $i >= $_->[0] && $i <= $_->[1] } @blocks;
                $my_at{$1} = $i if $lines[$i] =~ /^my\s+(\$\w+)\s*=/;
            }

            ( my $rel = $File::Find::name ) =~ s{^\Q$repo_root\E/}{};
            for my $block (@blocks) {
                my ( $from, $to ) = @$block;
                for my $i ( $from .. $to ) {
                    next if $lines[$i] =~ /^\s*#/;
                    my %seen_here;
                    while ( $lines[$i] =~ /(\$\w+)/g ) {
                        my $name = $1;
                        next if $seen_here{$name}++;
                        next if $is_our{$name};
                        next unless exists $my_at{$name};
                        next unless $my_at{$name} > $to;
                        push @offenders,
                          sprintf( '%s:%d reads %s, declared at line %d',
                            $rel, $i + 1, $name, $my_at{$name} + 1 );
                    }
                }
            }
        },
    },
    $repo_root
);

cmp_ok( $scanned, '>', 40, 'the scan reached files carrying a BEGIN block' );

is( scalar(@offenders), 0, 'no BEGIN block reads a lexical declared below it' )
  or diag( "these read an unassigned value at compile time:\n  "
      . join( "\n  ", @offenders ) );

done_testing();
