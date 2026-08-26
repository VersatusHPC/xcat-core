#!/usr/bin/env perl
use strict;
use warnings;

use File::Slurper qw(read_text write_text);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

my $repo_root = File::Spec->catdir($FindBin::Bin, '..', '..');
my $otherpkgs = File::Spec->catfile($repo_root, 'xCAT', 'postscripts', 'otherpkgs');

is(system('bash', '-n', $otherpkgs), 0, 'the otherpkgs caller parses as Bash');

sub helper_output {
    my (@command) = @_;
    open(
        my $fh,
        '-|',
        'bash', '-c',
        '. "$1"; shift; "$@"',
        'bash', $otherpkgs, @command,
    ) or die "Unable to run $otherpkgs: $!";
    my $output = do { local $/; <$fh> };
    close($fh);
    return ($? >> 8, $output);
}

my ($status, $output) = helper_output('xcat_otherpkgs_repo_id', 0);
is($status, 0, 'repository id construction succeeds');
is($output, "xcat-otherpkgs0\n", 'the first repository uses the upgrade scope prefix');

($status, $output) = helper_output('xcat_otherpkgs_repo_id', 7);
is($output, "xcat-otherpkgs7\n", 'local and remote repository indexes share one naming rule');

($status, $output) = helper_output('xcat_yum_upgrade_otherpkgs', 'dnf', 'print');
is($status, 0, 'rendering the scoped yum upgrade command succeeds');
is(
    $output,
    "dnf -y --disablerepo=* --enablerepo=xcat-otherpkgs* upgrade\n",
    'verbose output comes from the same helper as execution',
);

my $tools = tempdir(CLEANUP => 1);
my $yum_log = File::Spec->catfile($tools, 'yum.log');
my $fake_yum = File::Spec->catfile($tools, 'dnf');
write_text($fake_yum, <<'SH');
#!/bin/sh
printf '%s\n' "$@" > "$XCAT_TEST_YUM_LOG"
SH
chmod 0755, $fake_yum or die "Unable to make $fake_yum executable: $!";

{
    local %ENV = (%ENV, XCAT_TEST_YUM_LOG => $yum_log);
    ($status, $output) = helper_output('xcat_yum_upgrade_otherpkgs', $fake_yum);
}
is($status, 0, 'the scoped yum upgrade command succeeds');
is_deeply(
    [split /\n/, read_text($yum_log)],
    ['-y', '--disablerepo=*', '--enablerepo=xcat-otherpkgs*', 'upgrade'],
    'yum receives only the xcat-otherpkgs upgrade scope',
);

done_testing();
