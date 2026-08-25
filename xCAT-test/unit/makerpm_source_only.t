#!/usr/bin/env perl
use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

my $makerpm = File::Spec->catfile( $FindBin::Bin, '..', '..', 'makerpm' );
plan skip_all => 'makerpm not found' unless -r $makerpm;
plan skip_all => 'bash not found'    unless -x '/bin/bash';

open( my $fh, '<', $makerpm ) or die "Unable to read $makerpm: $!";
my $source = do { local $/; <$fh> };
close($fh);

# makerpm builds packages, so lift the parts that decide the mode out of it and
# drive the real code on its own.
my ($mode) = $source =~ /(^if \[ "\$SRCONLY".*?^fi$)/ms;
BAIL_OUT('could not extract the SRCONLY block from makerpm') unless $mode;
my ($announce) = $source =~ /(^function announcebuild \{.*?^\}$)/ms;
BAIL_OUT('could not extract announcebuild from makerpm') unless $announce;

my $dir = tempdir( CLEANUP => 1 );

# Run the extracted shell with the given environment and return its output.
sub run_shell {
    my ( $script, %env ) = @_;
    my $path = File::Spec->catfile( $dir, 'snippet.sh' );
    open( my $out, '>', $path ) or die "Unable to write $path: $!";
    print $out "$script\n";
    close($out);
    my $prefix = join ' ', map { "$_=" . ( defined $env{$_} ? $env{$_} : '' ) }
      sort keys %env;
    my $result = `env $prefix /bin/bash $path 2>&1`;
    return ( $result, $? >> 8 );
}

# The mode the operator asks for decides which rpmbuild flags are used.
my @modes = (
    [ 'unset',       undef, '-ba -ta' ],
    [ 'empty',       '',    '-ba -ta' ],
    [ 'SRCONLY=0',   '0',   '-ba -ta' ],
    [ 'SRCONLY=no',  'no',  '-ba -ta' ],
    [ 'SRCONLY=1',   '1',   '-bs -ts' ],
    [ 'SRCONLY=yes', 'yes', '-bs -ts' ],
);
foreach my $case (@modes) {
    my ( $name, $value, $expected ) = @$case;
    my ( $got, $rc ) =
      run_shell( "$mode\necho \$SPECBUILD \$TARBUILD",
        SRCONLY => $value, OSNAME => 'Linux' );
    chomp $got;
    is( $got, $expected, "$name selects '$expected'" );
    is( $rc, 0, "$name exits cleanly" );
}

# AIX builds with rpm rather than rpmbuild and no AIX machine is available to
# test a change there, so the mode has to be refused rather than ignored.
my ( $aix, $aixrc ) =
  run_shell( "$mode\necho \$SPECBUILD", SRCONLY => '1', OSNAME => 'AIX' );
isnt( $aixrc, 0, 'a source-only build on AIX stops with an error' );
like( $aix, qr/not supported on AIX/, 'the error names AIX' );

my ( $aixdefault, $aixdefaultrc ) =
  run_shell( "$mode\necho \$SPECBUILD", SRCONLY => undef, OSNAME => 'AIX' );
is( $aixdefaultrc, 0, 'a normal build on AIX is not disturbed' );
like( $aixdefault, qr/-ba/, 'a normal build on AIX keeps its flags' );

# The message before a build has to name the package that the build makes.
my ( $binmsg, undef ) = run_shell(
    "$announce\nSPECBUILD=-ba\nRPMROOT=/root\nEMBEDTXT=\nannouncebuild "
      . "\"xCAT-server-2.19.0\" \"/root/RPMS/noarch/xCAT-server-2.19.0-snap*.noarch.rpm\"" );
like( $binmsg, qr{/root/RPMS/noarch/xCAT-server-2\.19\.0-snap\*\.noarch\.rpm},
    'a normal build names the binary package' );
unlike( $binmsg, qr/src\.rpm/, 'a normal build does not name a source package' );

my ( $srcmsg, undef ) = run_shell(
    "$announce\nSPECBUILD=-bs\nRPMROOT=/root\nEMBEDTXT=\nannouncebuild "
      . "\"xCAT-server-2.19.0\" \"/root/RPMS/noarch/xCAT-server-2.19.0-snap*.noarch.rpm\"" );
like( $srcmsg, qr{/root/SRPMS/xCAT-server-2\.19\.0-snap\*\.src\.rpm},
    'a source-only build names the source package' );
unlike( $srcmsg, qr{RPMS/noarch},
    'a source-only build names no binary package' );

# The four builds have to take the mode, or the mode reaches none of them.
my @built = $source =~ /^\s*rpmbuild \$QUIET (\S+) /mg;
is( scalar @built, 4, 'makerpm holds four rpmbuild commands' );
is( scalar( grep { $_ eq '$SPECBUILD' or $_ eq '$TARBUILD' } @built ),
    4, 'every rpmbuild command takes the mode' );

# The AIX commands use rpm and are deliberately left alone.
my @aixbuilt = $source =~ /^\s*rpm \$QUIET (\S+) /mg;
is_deeply( \@aixbuilt, [ '-ba', '-ba' ], 'the AIX builds are unchanged' );

done_testing();
