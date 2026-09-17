#!/usr/bin/env perl
use strict;
use warnings;

use File::Find;
use File::Spec;
use FindBin;
use Test::More;

# A module that changes @INC decides where its caller's dependencies come from.
# It runs after the caller has set its own path and wins, so use lib, -I and
# PERL5LIB all lose to it. Only an entry point may set the include path, and it
# spells the root ( $ENV{XCATROOT} || '/opt/xcat' ) rather than naming a
# directory.
#
# "use lib" is not the only spelling. lib->import, unshift @INC, push @INC and an
# assignment to @INC do the same thing, so the check covers all of them.

my %SKIP_PACKAGE = (
    'xCAT-rmc' => 'not built for Debian, not deployed and not tested here',
);

# Exemptions are per file with a reason, so an exception is visible in the test
# output instead of hidden in a pattern.
my %EXEMPT = (
    'xCAT-server/lib/perl/xCAT_plugin/openbmc.pm' =>
      'reaches HTTP::Async, a declared dependency that installs outside the vendor path',
);

my @PATTERNS = (
    [ qr/^\s*use\s+lib\b/                   => 'use lib' ],
    [ qr/\blib->import\b/                   => 'lib->import' ],
    [ qr/\bunshift\s*\(?\s*\@INC\b/         => 'unshift @INC' ],
    [ qr/\bpush\s*\(?\s*\@INC\b/            => 'push @INC' ],
    [ qr/^\s*\@INC\s*=/                     => '@INC assignment' ],
);

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..', '..' );
die "Unable to resolve the repository root from $FindBin::Bin" unless -d $repo_root;

sub package_of {
    my ($path) = @_;
    my $rel = File::Spec->abs2rel( $path, $repo_root );
    my ($first) = File::Spec->splitdir($rel);
    return $first;
}

my ( %offenders, %scanned );

find(
    {
        no_chdir => 1,
        wanted   => sub {
            return unless /\.pm$/;
            return if $File::Find::name =~ m{/(?:dist|\.git)/};
            my $package = package_of($File::Find::name);
            return if exists $SKIP_PACKAGE{$package};
            ( my $rel = $File::Find::name ) =~ s{^\Q$repo_root\E/}{};
            return if exists $EXEMPT{$rel};
            $scanned{$package}++;

            open( my $fh, '<', $File::Find::name ) or die "Unable to read $File::Find::name: $!";
            my $aix_guard = 0;
            while ( my $line = <$fh> ) {
                next if $line =~ /^\s*#/;

                # The AIX branch prepends the perl 5.8.2 paths that xCAT ships its
                # dependencies against. It cannot run anywhere else, and no lane
                # builds or tests AIX, so removing it is a change nothing here can
                # verify.
                $aix_guard = 4 if $line =~ /\$\^O\s*=~\s*\/\^aix\/i/;
                if ($aix_guard) { $aix_guard--; next }

                foreach my $rule (@PATTERNS) {
                    my ( $re, $name ) = @$rule;
                    next unless $line =~ $re;
                    push @{ $offenders{$package} }, "$rel:$.: [$name] $line";
                }
            }
            close($fh);
        },
    },
    $repo_root
);

my $total = 0;
$total += $_ for values %scanned;

# A floor plus two named packages, so a scan that is misrooted or silently empty
# fails here instead of reporting no offenders.
cmp_ok( $total, '>', 200, 'the scan reached the perl modules' );
ok( $scanned{'perl-xCAT'},   'the scan reached perl-xCAT' );
ok( $scanned{'xCAT-server'}, 'the scan reached xCAT-server' );

foreach my $package ( sort keys %scanned ) {
    my $bad = $offenders{$package} || [];
    is( scalar(@$bad), 0, "no perl module in $package changes \@INC" )
      or diag( "the include path belongs to the entry point:\n" . join( '', @$bad ) );
}

note("skipped $_: $SKIP_PACKAGE{$_}") for sort keys %SKIP_PACKAGE;
note("exempt $_: $EXEMPT{$_}")        for sort keys %EXEMPT;

done_testing();
