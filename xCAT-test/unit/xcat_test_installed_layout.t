#!/usr/bin/env perl
# The xCAT-test package installs the unit tests at /opt/xcat/share/xcat/tools/autotest/unit, and
# xcattest cases run prove against them there. A test loads its support modules from
# "$FindBin::Bin/../lib", so the package must carry xCAT-test/lib beside the tests, and those
# modules must load where there is no checkout above them.
use strict;
use warnings;

use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Find ();
use File::Path qw(make_path);
use File::Spec;
use File::Temp ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use XCAT::Test::File qw(repo_path slurp_repo_file);

# ------------------------------------------------ the package carries the support modules ----
my $spec     = slurp_repo_file('xCAT-test/xCAT-test.spec');
my $autotest = '$RPM_BUILD_ROOT/%{prefix}/share/xcat/tools/autotest';
foreach my $tree (qw(unit lib)) {
    like(
        $spec,
        qr/^\s*cp\s+-r\s+\Q$tree\E\s+\Q$autotest\E\s*$/m,
        "xCAT-test.spec installs $tree under autotest"
    );
}

my %destination_of;
foreach my $line ( split( /\n/, slurp_repo_file('xCAT-test/debian/install') ) ) {
    next unless $line =~ /\S/;
    my ( $source, $destination ) = split( ' ', $line );
    $destination_of{$source} = $destination;
}
is(
    $destination_of{'lib'},
    $destination_of{'unit'},
    'debian/install puts lib where it puts unit'
);

# ------------------------------------------------ they load where the package puts them ------
# The copy is deliberate: a symlink to the checkout resolves back to it, and the module under
# test asks abs_path where it is.
my $scratch = File::Temp->newdir( 'xcat-installed-layout-XXXXXXXX', TMPDIR => 1 );
my $source  = repo_path('xCAT-test/lib');
my $lib     = File::Spec->catdir( "$scratch", 'opt', 'xcat', 'share', 'xcat', 'tools', 'autotest', 'lib' );
File::Find::find(
    {
        no_chdir => 1,
        wanted   => sub {
            return unless -f $File::Find::name;
            my $relative = $File::Find::name;
            $relative =~ s{^\Q$source\E/}{};
            my $path = File::Spec->catfile( $lib, $relative );
            make_path( dirname($path) );
            copy( $File::Find::name, $path ) or die "Unable to copy $relative: $!";
        },
    },
    $source,
);

{
    local $ENV{XCATROOT} = '/opt/xcat';
    my ( $status, $output ) = _run( $lib,
        'use XCAT::Test::XcatRoot; print $ENV{XCATROOT};' );
    is( $status, 0,          'XCAT::Test::XcatRoot loads from the installed layout' );
    is( $output, '/opt/xcat', 'XCAT::Test::XcatRoot leaves XCATROOT alone with no checkout' );

    ( $status, $output ) = _run( $lib,
        'use XCAT::Test::File qw(repo_path); repo_path(q(perl-xCAT));' );
    isnt( $status, 0, 'repo_path dies with no checkout instead of returning a wrong path' );
}

done_testing();

#-------------------------------------------------------------------------------

=head3 _run

    Descriptions: Runs one perl program with the installed library directory in @INC.
    Arguments:
        $lib     - the library directory to add to @INC
        $program - the program text
    Returns: the exit status and the standard output

=cut

#-------------------------------------------------------------------------------
sub _run {
    my ( $lib, $program ) = @_;

    open( my $fh, '-|', $^X, "-I$lib", '-e', $program )
        or die "Unable to run perl: $!";
    my $output = do { local $/; <$fh> };
    close($fh);

    return ( $?, defined $output ? $output : '' );
}
