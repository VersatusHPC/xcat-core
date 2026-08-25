#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

my $buildcore = File::Spec->catfile( $FindBin::Bin, '..', '..', 'buildcore.sh' );
plan skip_all => 'buildcore.sh not found' unless -r $buildcore;
plan skip_all => 'bash not found'         unless -x '/bin/bash';

open( my $fh, '<', $buildcore ) or die "Unable to read $buildcore: $!";
my $source = do { local $/; <$fh> };
close($fh);

# buildcore.sh builds the whole product, so lift the routines that deliver the
# packages out of it and drive the real code on its own.
my ($srconly) = $source =~ /(^function srconly \{.*?^\}$)/ms;
BAIL_OUT('could not extract srconly from buildcore.sh') unless $srconly;
my ($maker) = $source =~ /(^function maker \{.*?^\}$)/ms;
BAIL_OUT('could not extract maker from buildcore.sh') unless $maker;

# Build a tree that looks like a finished rpmbuild, plus the delivery
# directories, and run the real maker() against it.
sub deliver {
    my (%env) = @_;
    my $root = tempdir( CLEANUP => 1 );
    make_path( "$root/rpmbuild/RPMS/noarch", "$root/rpmbuild/SRPMS",
        "$root/dest", "$root/src" );

    # what the build just produced
    _touch("$root/rpmbuild/RPMS/noarch/xCAT-server-2.19.0-snap1.noarch.rpm");
    _touch("$root/rpmbuild/SRPMS/xCAT-server-2.19.0-snap1.src.rpm");

    # what an earlier build already delivered
    _touch("$root/dest/xCAT-server-2.19.0-snap0.noarch.rpm");
    _touch("$root/src/xCAT-server-2.19.0-snap0.src.rpm");

    open( my $stub, '>', "$root/makerpm" ) or die $!;
    print $stub "#!/bin/bash\nexit 0\n";
    close($stub);
    chmod 0755, "$root/makerpm";

    my $srconly_env = defined $env{SRCONLY} ? $env{SRCONLY} : '';
    my $script = <<"SH";
cd $root
source=$root/rpmbuild
DESTDIR=$root/dest
SRCDIR=$root/src
NOARCH=noarch
VER=2.19.0
EMBED=
FAILEDRPMS=
SRCONLY=$srconly_env
$srconly
$maker
maker xCAT-server
echo "FAILEDRPMS=[\$FAILEDRPMS]"
SH
    my $path = "$root/drive.sh";
    open( my $out, '>', $path ) or die $!;
    print $out $script;
    close($out);
    my $said = `/bin/bash $path 2>&1`;

    return {
        said      => $said,
        delivered => [ sort map { s{.*/}{}r } glob("$root/dest/*") ],
        sources   => [ sort map { s{.*/}{}r } glob("$root/src/*") ],
        left      => [ sort map { s{.*/}{}r }
              glob("$root/rpmbuild/RPMS/noarch/*") ],
    };
}

sub _touch { open( my $f, '>', $_[0] ) or die "$_[0]: $!"; close($f); }

# A normal build delivers the binary package and replaces the earlier one.
my $normal = deliver();
is_deeply( $normal->{delivered}, ['xCAT-server-2.19.0-snap1.noarch.rpm'],
    'a normal build delivers the binary package' );
is_deeply( $normal->{sources}, ['xCAT-server-2.19.0-snap1.src.rpm'],
    'a normal build delivers the source package' );
is_deeply( $normal->{left}, [],
    'a normal build moves the binary package out of the build tree' );
unlike( $normal->{said}, qr/No such file/,
    'a normal build reports no missing file' );

# A source-only build makes no binary package. It must deliver the source
# package and it must not disturb the binary package of an earlier build.
my $srconly_run = deliver( SRCONLY => '1' );
is_deeply( $srconly_run->{delivered}, ['xCAT-server-2.19.0-snap0.noarch.rpm'],
    'a source-only build keeps the binary package of the earlier build' );
is_deeply( $srconly_run->{sources}, ['xCAT-server-2.19.0-snap1.src.rpm'],
    'a source-only build delivers the source package' );
unlike( $srconly_run->{said}, qr/No such file/,
    'a source-only build reports no missing file' );
like( $srconly_run->{said}, qr/FAILEDRPMS=\[\]/,
    'a source-only build names no failed package' );

# SRCONLY=yes is the other accepted spelling, and SRCONLY=0 is not the mode.
my $yes = deliver( SRCONLY => 'yes' );
is_deeply( $yes->{delivered}, ['xCAT-server-2.19.0-snap0.noarch.rpm'],
    'SRCONLY=yes keeps the binary package of the earlier build' );
my $zero = deliver( SRCONLY => '0' );
is_deeply( $zero->{delivered}, ['xCAT-server-2.19.0-snap1.noarch.rpm'],
    'SRCONLY=0 delivers the binary package' );

# The three places that deliver packages all have to take the mode.
my @guards = $source =~ /^\s*if ! srconly; then$/mg;
is( scalar @guards, 3, 'the three delivery places take the mode' );

done_testing();
