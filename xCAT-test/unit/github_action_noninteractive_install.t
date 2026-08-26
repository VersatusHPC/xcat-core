#!/usr/bin/env perl
use strict;
use warnings;

use File::Slurper qw(read_text);
use File::Spec;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use XCAT::Test::GitHubAction qw(package_install_command should_check_syntax);

my $driver = File::Spec->catfile(
    $FindBin::Bin, '..', '..', 'github_action_xcat_test.pl',
);
my $loaded = do $driver;
ok($loaded, 'the GitHub action driver loads without starting the workflow')
  or BAIL_OUT($@ || $! || 'the driver returned false');

for my $package (qw(xcat xcat-probe xcat-test)) {
    my $command = package_install_command($package);
    like(
        $command,
        qr{^sudo timeout \d+ env DEBIAN_FRONTEND=noninteractive apt-get },
        "$package installation is noninteractive and bounded",
    );
    like($command, qr{ install -y \Q$package\E },
        "$package installation accepts the package transaction");
    unlike($command, qr{\byes\s*\|},
        "$package installation does not pipe input into maintainer scripts");
}

ok(!should_check_syntax('/opt/xcat/share/xcat/tools/autotest/unit/example.t'),
    'installed source-layout tests are excluded from syntax checks');
ok(!should_check_syntax('/opt/xcat/share/xcat/netboot/genesis/bin/init'),
    'Genesis binaries remain excluded from Perl syntax checks');
ok(!should_check_syntax('/opt/xcat/probe/lib/example.pm'),
    'probe payloads remain excluded from the core syntax scan');
ok(should_check_syntax('/opt/xcat/lib/perl/xCAT/Utils.pm'),
    'ordinary installed Perl modules remain in the syntax scan');

{
    no warnings qw(redefine once);
    my @commands;
    my @packages;
    local *main::package_install_command = sub {
        my ($package) = @_;
        push @packages, $package;
        return "install-package-$package";
    };
    local *main::runcmd = sub {
        my ($command) = @_;
        push @commands, $command;
        $::RUNCMD_RC = 0;
        return ();
    };
    local $ENV{RUNNER_WORKSPACE} = $FindBin::Bin;
    open(my $output, '>', \my $printed) or die "Unable to capture driver output: $!";
    {
        local *STDOUT = $output;
        is(main::install_xcat(), 0, 'the loaded driver installation path succeeds with stubbed commands');
    }
    is_deeply(\@packages, [qw(xcat xcat-probe)],
        'the driver obtains both installation commands from the shared policy');
    ok(grep($_ eq 'install-package-xcat', @commands),
        'the driver executes the generated xcat installation command');
    ok(grep($_ eq 'install-package-xcat-probe', @commands),
        'the driver executes the generated xcat-probe installation command');
}

{
    no warnings qw(redefine once);
    my @checked;
    local *main::get_files_recursive = sub {
        my ($directory, $files) = @_;
        push @$files, '/opt/xcat/lib/perl/xCAT/Utils.pm';
        return 0;
    };
    local *main::should_check_syntax = sub {
        push @checked, $_[0];
        return 0;
    };
    local *main::runcmd = sub { die 'excluded files must not reach the syntax command'; };
    open(my $output, '>', \my $printed) or die "Unable to capture driver output: $!";
    {
        local *STDOUT = $output;
        is(main::check_syntax(), 0, 'the loaded driver syntax path accepts excluded files');
    }
    is_deeply(
        \@checked,
        [('/opt/xcat/lib/perl/xCAT/Utils.pm') x 2],
        'the driver asks the shared policy about files from both scan roots',
    );
}

my $workflow = File::Spec->catfile(
    $FindBin::Bin, '..', '..', '.github', 'workflows', 'xcat_test.yml',
);
my $workflow_contents = read_text($workflow);
like(
    $workflow_contents,
    qr{sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y\b},
    'workflow dependency installation is noninteractive',
);

done_testing();
