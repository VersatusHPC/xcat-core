#!/usr/bin/env perl
# A unit test must measure the checkout it lives in.
#
# Every xCAT module runs "use lib $::XCATROOT/lib/perl" while it compiles, and $::XCATROOT is
# $ENV{XCATROOT} or /opt/xcat. On a host with xCAT installed the first xCAT module a test loads
# therefore puts the installed product in front of the checkout in @INC, and every module after
# it comes from /opt/xcat. A test that reads $ENV{XCATROOT}/share/... reads the installed file
# for the same reason. The same commit then passes on a host without xCAT and fails on a build
# agent, and a change to the tree is invisible to the test that is supposed to gate it.
#
# Each test below runs again with XCATROOT pointing at a decoy tree. Every module in the decoy
# dies while it compiles and every shared file holds one marker line, so a test that reads the
# decoy reports it. A test that fails without the decoy as well has an environment gap, not this
# defect, and is skipped.
use strict;
use warnings;

use File::Basename qw(dirname);
use File::Find ();
use File::Path qw(make_path);
use File::Spec;
use File::Temp ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use POSIX ();
use Test::More;
use XCAT::Test::File qw(repo_path);

my $JOBS    = 8;
my $TIMEOUT = 300;

my @tests = sort grep { $_ ne File::Spec->rel2abs(__FILE__) }
    glob( File::Spec->catfile( $FindBin::Bin, '*.t' ) );
plan skip_all => 'no unit tests found' unless @tests;

# ---------------------------------------------------------------- the decoy XCATROOT --------
my $decoy_dir = File::Temp->newdir( 'xcat-decoy-root-XXXXXXXX', TMPDIR => 1 );
my $decoy     = "$decoy_dir";

# The decoy carries the installed layout, so a lookup that reaches it finds a file and reports
# where it came from instead of falling back to the checkout and hiding the defect.
my %MODULES = (
    'lib/perl/xCAT'            => [ 'perl-xCAT/xCAT', 'xCAT-server/lib/perl/xCAT' ],
    'lib/perl/xCAT_plugin'     => ['xCAT-server/lib/xcat/plugins'],
    'lib/perl/xCAT_schema'     => ['xCAT-server/lib/xcat/schema'],
    'lib/perl/xCAT_monitoring' => ['xCAT-server/lib/xcat/monitoring'],
);

foreach my $installed ( sort keys %MODULES ) {
    foreach my $source ( @{ $MODULES{$installed} } ) {
        _mirror(
            repo_path($source),
            File::Spec->catdir( $decoy, $installed ),
            sub {
                my ($relative) = @_;
                return "die \"DECOY: $installed/$relative came from \\\$XCATROOT\\n\";\n1;\n";
            },
        );
    }
}

foreach my $source ( 'xCAT-server/share/xcat', 'xCAT-client/share/xcat' ) {
    _mirror(
        repo_path($source),
        File::Spec->catdir( $decoy, 'share/xcat' ),
        sub { return "DECOY-SHARE-FILE\n" },
    );
}

# ---------------------------------------------------------------- run every test -------------
my %poisoned = _run_all( \@tests, $decoy );
my @broken = sort grep { $poisoned{$_}{status} != 0 } keys %poisoned;
my %clean = _run_all( \@broken, undef );

foreach my $test (@tests) {
    my $name = ( File::Spec->splitpath($test) )[2];
    my $result = $poisoned{$test};

  SKIP: {
        skip "$name does not pass in this environment even without the decoy", 1
            if $result->{status} != 0 && $clean{$test}{status} != 0;

        my $why = $result->{status} == 0 ? '' : "\n" . $result->{output};
        is( $result->{status}, 0, "$name reads the checkout, not \$XCATROOT$why" );
    }
}

done_testing();

#-------------------------------------------------------------------------------

=head3 _mirror

    Descriptions: Copies the shape of a directory, giving every file new contents.
    Arguments:
        $source      - the directory to walk
        $destination - the directory to create
        $contents    - a sub that returns the contents for a source-relative path
    Returns: nothing

=cut

#-------------------------------------------------------------------------------
sub _mirror {
    my ( $source, $destination, $contents ) = @_;

    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $File::Find::name;
                my $relative = $File::Find::name;
                $relative =~ s{^\Q$source\E/}{};
                my $path = File::Spec->catfile( $destination, $relative );

                # The first source wins, which is how the installed tree is assembled.
                return if -e $path;

                make_path( dirname($path) );
                open( my $fh, '>', $path ) or die "Unable to write $path: $!";
                print {$fh} $contents->($relative);
                close($fh) or die "Unable to close $path: $!";
                chmod( 0755, $path );
            },
        },
        $source,
    );

    return;
}

#-------------------------------------------------------------------------------

=head3 _run_all

    Descriptions: Runs tests in parallel and collects the exit status and output of each.
    Arguments:
        $tests    - a reference to the list of test paths
        $xcatroot - the XCATROOT to run with, or undef to remove it
    Returns: a hash of test path to { status, output }

=cut

#-------------------------------------------------------------------------------
sub _run_all {
    my ( $tests, $xcatroot ) = @_;

    my $output_dir = File::Temp->newdir( 'xcat-decoy-out-XXXXXXXX', TMPDIR => 1 );
    my ( %running, %result );
    my @queue = @$tests;

    while ( @queue || %running ) {
        while ( @queue && keys(%running) < $JOBS ) {
            my $test = shift @queue;
            my $log = File::Spec->catfile( "$output_dir", scalar( keys %result ) . '-' . $$ . '.log' );
            $result{$test} = { output => '', log => $log };
            my $pid = _spawn( $test, $log, $xcatroot );
            $running{$pid} = $test;
        }

        my $pid = waitpid( -1, 0 );
        last if $pid <= 0;
        my $test = delete $running{$pid} or next;
        $result{$test}{status} = $?;
        if ( open( my $fh, '<', $result{$test}{log} ) ) {
            $result{$test}{output} = do { local $/; <$fh> };
            close($fh);
        }
    }

    return %result;
}

#-------------------------------------------------------------------------------

=head3 _spawn

    Descriptions: Starts one test with its output in a file and a timeout of its own.
    Arguments:
        $test     - the test to run
        $log      - the file that takes stdout and stderr
        $xcatroot - the XCATROOT to run with, or undef to remove it
    Returns: the child pid

=cut

#-------------------------------------------------------------------------------
sub _spawn {
    my ( $test, $log, $xcatroot ) = @_;

    my $pid = fork();
    die "Unable to fork: $!" unless defined $pid;
    return $pid if $pid;

    # The child keeps no share of the parent's stdout, so a test that never exits cannot hold
    # the harness open: it is killed by its own alarm and reported as a failure.
    if ( defined $xcatroot ) { $ENV{XCATROOT} = $xcatroot }
    else                     { delete $ENV{XCATROOT} }
    delete $ENV{ $_ } for grep { /^(HARNESS|TAP)_/ } keys %ENV;

    open( STDIN,  '<', File::Spec->devnull() );
    open( STDOUT, '>', $log );
    open( STDERR, '>&', \*STDOUT );

    alarm($TIMEOUT);
    exec( $^X, $test ) or POSIX::_exit(127);
}
