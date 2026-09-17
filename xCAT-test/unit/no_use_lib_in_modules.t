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
# entry point may set the include path, and it spells the root
# ($ENV{XCATROOT} || '/opt/xcat') rather than naming a directory.

# The check is scoped per package so a package that is out of scope can be named
# here, with the reason, instead of weakening the rule for the whole tree.
my %SKIP = (
    'xCAT-rmc' => 'RMC is not built for Debian, not deployed and not tested here',
);

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..', '..' );
die "Unable to resolve the repository root from $FindBin::Bin" unless -d $repo_root;

# Package = the top level directory of the checkout, e.g. perl-xCAT or xCAT-server.
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
            return if exists $SKIP{$package};
            $scanned{$package}++;
            open( my $fh, '<', $File::Find::name ) or die "Unable to read $File::Find::name: $!";
            while ( my $line = <$fh> ) {
                next if $line =~ /^\s*#/;
                next unless $line =~ /^\s*use\s+lib\b/;
                ( my $rel = $File::Find::name ) =~ s{^\Q$repo_root\E/}{};
                push @{ $offenders{$package} }, "$rel:$.: $line";
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
    is( scalar(@$bad), 0, "no perl module in $package calls use lib" )
      or diag( "use lib belongs in an entry point, not a module:\n" . join( '', @$bad ) );
}

foreach my $package ( sort keys %SKIP ) {
    my $dir = File::Spec->catdir( $repo_root, $package );
    next unless -d $dir;
    note("skipped $package: $SKIP{$package}");
}

done_testing();
