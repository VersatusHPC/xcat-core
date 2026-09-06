#!/usr/bin/env perl
use strict;
use warnings;

use Cwd qw(getcwd);
use File::Spec;
use File::Path qw(mkpath);
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

my $script = File::Spec->catfile(
    $FindBin::Bin, '..', '..', 'github_action_xcat_test.pl'
);
open( my $fh, '<', $script ) or die "Unable to read $script: $!";
my $contents = do { local $/; <$fh> };
close($fh);

my $workflow = File::Spec->catfile(
    $FindBin::Bin, '..', '..', '.github', 'workflows', 'xcat_test.yml'
);
open( my $workflow_fh, '<', $workflow )
  or die "Unable to read $workflow: $!";
my $workflow_contents = do { local $/; <$workflow_fh> };
close($workflow_fh);

# The script installs from a GitHub runner, so it cannot be run here. Lift the
# three routines that install packages or choose files, eval them into a
# scratch package and run them with runcmd recording instead of running. A
# match against the text of the script passes on a commented out line, which
# is how an interactive apt-get once reached the workflow unnoticed.
my %block;
foreach my $name (qw(install_xcat run_fast_regression_test check_syntax)) {
    ( $block{$name} ) = $contents =~ /^(sub \Q$name\E\{\n.*?^\}\n)/ms;
    BAIL_OUT("$script no longer defines sub $name") unless $block{$name};
}

# The routines read variables the script declares at file scope. Take those
# declarations too, so a branch that adds one does not have to be listed here.
my ($header) = $contents =~ /^(.*?)^sub /ms;
my @decls;
while ( $header =~ /^(my\b.*?;)$/gms ) { my $d = $1; $d =~ s/^my\b/our/; push @decls, $d }
BAIL_OUT("$script declares nothing at file scope") unless @decls;

# install_xcat looks for the repository the build produced, so give it one.
my $work = tempdir( CLEANUP => 1 );
mkpath( File::Spec->catdir( $work, 'dist', 'debs', 'xcat-core' ) );
foreach my $rel ( 'mklocalrepo.sh', 'dist/debs/xcat-core/mklocalrepo.sh' ) {
    my $path = File::Spec->catfile( $work, split( m{/}, $rel ) );
    open( my $out, '>', $path ) or die "Unable to write $path: $!";
    print $out "#!/bin/sh\nexit 0\n";
    close($out);
    chmod( 0755, $path ) or die "Unable to make $path executable: $!";
}

my $cwd = getcwd();
{
    my $code = join( "\n",
        'package XCATTest::GH;',
        'use strict; use warnings;',
        'use Cwd qw(getcwd);',
        'use Data::Dumper;',
        'use Time::Local;',
        'use Term::ANSIColor qw(:constants);',
        @decls,
        'our @ran;',
        'our $rc = 0;',
        'our %tree;',
        'sub runcmd { my ($c) = @_; push @ran, $c; $::RUNCMD_RC = $rc; return ("ASCII text") }',
        'sub get_files_recursive { my ( $dir, $files ) = @_; push @$files, @{ $tree{$dir} || [] }; return }',
        $block{install_xcat},
        $block{run_fast_regression_test},
        $block{check_syntax},
        '1;' );

    # A declaration can read the working directory, so compile it in the
    # scratch tree rather than in the source tree the suite runs from.
    chdir($work) or die "Unable to enter $work: $!";
    eval $code;    ## no critic
    my $err = $@;
    chdir($cwd) or die "Unable to return to $cwd: $!";
    BAIL_OUT("unable to compile the extracted routines: $err") if $err;
}

# The routines print progress. Keep it out of the TAP stream.
sub run_quietly {
    my ($code) = @_;
    local @XCATTest::GH::ran = ();
    my $noise = '';
    my $result;
    {
        open( my $saved, '>&', \*STDOUT ) or die "Unable to save STDOUT: $!";
        close(STDOUT);
        open( STDOUT, '>', \$noise ) or die "Unable to redirect STDOUT: $!";
        $result = $code->();
        close(STDOUT);
        open( STDOUT, '>&', $saved ) or die "Unable to restore STDOUT: $!";
    }
    return ( $result, [@XCATTest::GH::ran] );
}

my $ran;
{
    # install_xcat changes directory into the runner workspace.
    local $ENV{RUNNER_WORKSPACE} = $work;
    local $XCATTest::GH::rc = 0;
    ( undef, $ran ) = run_quietly( sub { XCATTest::GH::install_xcat() } );
    chdir($cwd) or die "Unable to return to $cwd: $!";
}

# run_fast_regression_test writes files and calls sudo after its install, so
# make the install report a failure and let the routine return on it.
my $fastran;
{
    local $XCATTest::GH::rc = 1;
    ( undef, $fastran ) = run_quietly( sub { XCATTest::GH::run_fast_regression_test() } );
}

my @installs = grep { /apt-get\b.*\binstall\b/ } @$ran, @$fastran;
ok( scalar @installs, 'the script installs packages with apt-get' );

for my $package (qw(xcat xcat-probe xcat-test)) {
    my ($cmd) = grep { /\binstall -y \Q$package\E(?:\s|$)/ } @installs;
    ok( $cmd, "$package is installed" )
      or next;
    like( $cmd, qr/\bsudo timeout \d+ env DEBIAN_FRONTEND=noninteractive apt-get\b/,
        "$package installation is noninteractive and bounded" );
}

# A prompt answered by piping input into the maintainer scripts is not the
# same as not being asked.
unlike( join( "\n", @$ran, @$fastran ), qr{yes\s*\|\s*(?:sudo\s+)?apt-get},
    'package input is not piped into maintainer scripts' );

# Every install has to carry the setting, not only the three named above.
my @interactive = grep { !/env DEBIAN_FRONTEND=noninteractive/ } @installs;
is_deeply( \@interactive, [], 'no apt-get install runs without the noninteractive setting' );

is( scalar @$fastran, 1,
    'the regression run stops on a failed install instead of continuing' );

# The installed copy of the unit tests reaches for the source layout, so the
# syntax check has to leave it alone.
{
    no warnings 'once';    # the variables are declared inside the eval above
    local %XCATTest::GH::tree = (
        '/opt/xcat' => [
            '/opt/xcat/share/xcat/tools/autotest/unit/some_test.t',
            '/opt/xcat/share/xcat/netboot/genesis/whatever',
            '/opt/xcat/probe/xcatprobe',
            '/opt/xcat/lib/perl/xCAT/Utils.pm',
        ],
        '/install' => [],
    );
    local $XCATTest::GH::rc = 0;
    my ( undef, $checked ) = run_quietly( sub { XCATTest::GH::check_syntax() } );
    my $looked = join( "\n", @$checked );
    unlike( $looked, qr{autotest/unit/},
        'installed source-layout tests are excluded from syntax checks' );
    unlike( $looked, qr{netboot/genesis/}, 'the genesis payload is excluded' );
    unlike( $looked, qr{/opt/xcat/probe/}, 'the probe tree is excluded' );
    like( $looked, qr{/opt/xcat/lib/perl/xCAT/Utils\.pm},
        'a Perl file outside those trees is still checked' );
}

# The workflow is a manifest, so its text is the contract.
like(
    $workflow_contents,
    qr{sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y\b},
    'workflow dependency installation is noninteractive'
);

done_testing();
