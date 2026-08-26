#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use IPC::Open3;
use Symbol qw(gensym);
use Test::More;

my $go_xcat = "$FindBin::Bin/../../xCAT-server/share/xcat/tools/go-xcat";
my $tmpdir = tempdir(CLEANUP => 1);
my $driver = "$tmpdir/driver.sh";

open(my $driver_fh, '>', $driver) or die "open $driver: $!";
print {$driver_fh} <<'DRIVER';
#!/bin/bash
set -euo pipefail

source "$GO_XCAT_SOURCE"

TMP_DIR=$TEST_TMP
GO_XCAT_DEFAULT_BASE_URL=https://repo.example.invalid
GO_XCAT_DEP_REPOSITORY_IDS=(xcat-dep)

yum() { :; }

download_file() {
    printf '%s\n' "$1" >>"$DOWNLOAD_LOG"
    [[ ${COMMON_PRESENT:-0} == 1 ]] || return 1
    : >"$2"
}

add_repo_by_url_yum_or_zypper() {
    printf '%s %s\n' "$1" "$2" >>"$ADD_LOG"
}

xcat_dep_common_repo_configured() { [[ -s "$ADD_LOG" ]]; }
( add_xcat_dep_common_repo_yum_or_zypper "$@" )
refresh_xcat_dep_repository_ids
printf '%s\n' "${GO_XCAT_DEP_REPOSITORY_IDS[*]}" >"$ID_LOG"
DRIVER
close($driver_fh) or die "close $driver: $!";
chmod(0755, $driver) or die "chmod $driver: $!";

sub run_case {
    my ($name, $present, @arguments) = @_;
    my $case_dir = "$tmpdir/$name";
    make_path($case_dir);
    local %ENV = (
        %ENV,
        ADD_LOG        => "$case_dir/add.log",
        COMMON_PRESENT => $present,
        DOWNLOAD_LOG   => "$case_dir/download.log",
        GO_XCAT_SOURCE => $go_xcat,
        ID_LOG         => "$case_dir/id.log",
        TEST_TMP       => $case_dir,
    );
    my $status = system('bash', $driver, @arguments);
    return ($status >> 8, $case_dir);
}

sub read_file {
    my ($path) = @_;
    return '' unless -f $path;
    open(my $fh, '<', $path) or die "open $path: $!";
    my $content = do { local $/; <$fh> };
    close($fh) or die "close $path: $!";
    return $content;
}

my ($status, $case_dir) = run_case('remote-present', 1, '', 'latest');
is($status, 0, 'an available common repository is accepted');
is(
    read_file("$case_dir/download.log"),
    "https://repo.example.invalid/yum/latest/xcat-dep/common/repodata/repomd.xml\n",
    'the default repository is probed before it is enabled',
);
is(
    read_file("$case_dir/add.log"),
    "https://repo.example.invalid/yum/latest/xcat-dep/common xcat-dep-common\n",
    'the common repository uses its own repository ID',
);
is(read_file("$case_dir/id.log"), "xcat-dep xcat-dep-common\n",
    'common packages are included in repository listings');

($status, $case_dir) = run_case('remote-missing', 0, '', '2.18');
is($status, 0, 'a release without the common repository remains usable');
is(read_file("$case_dir/add.log"), '', 'a missing common repository is not enabled');
is(read_file("$case_dir/id.log"), "xcat-dep\n",
    'legacy package listings remain unchanged when common is absent');

($status, $case_dir) = run_case(
    'repo-file', 1, 'https://repo.example.invalid/custom/xcat-dep.repo', 'latest'
);
is($status, 0, 'a custom repository file remains supported');
is(read_file("$case_dir/download.log"), '',
    'the common URL is not guessed from a custom repository file');
is(read_file("$case_dir/add.log"), '',
    'a custom repository file does not enable an unrelated repository');

my $local_root = "$tmpdir/local-repository";
make_path("$local_root/common/repodata");
open(my $repomd_fh, '>', "$local_root/common/repodata/repomd.xml") or die $!;
close($repomd_fh) or die $!;
($status, $case_dir) = run_case('local-present', 0, $local_root, 'latest');
is($status, 0, 'a local common repository is accepted');
is(
    read_file("$case_dir/add.log"),
    "$local_root/common xcat-dep-common\n",
    'the local common repository is enabled beside the distribution repository',
);

my $template_driver = "$tmpdir/template-driver.sh";
open(my $template_fh, '>', $template_driver) or die "open $template_driver: $!";
print {$template_fh} <<'DRIVER';
#!/bin/bash
set -euo pipefail

source "$GO_XCAT_SOURCE"

TMP_DIR=$TEST_TMP
GO_XCAT_DEFAULT_INSTALL_PATH=/install/xcat
yum() { :; }
add_repo_by_file() { cp "$1" "$REPO_LOG"; }
add_repo_by_url_yum_or_zypper \
    https://repo.example.invalid/xcat-dep/common xcat-dep-common optional
DRIVER
close($template_fh) or die "close $template_driver: $!";
chmod(0755, $template_driver) or die "chmod $template_driver: $!";

my $template_log = "$tmpdir/generated-common.repo";
local %ENV = (
    %ENV,
    GO_XCAT_SOURCE => $go_xcat,
    REPO_LOG       => $template_log,
    TEST_TMP       => $tmpdir,
);
$status = system('bash', $template_driver);
is($status >> 8, 0, 'go-xcat can generate the optional common repository');
like(read_file($template_log), qr/^skip_if_unavailable=1$/m,
    'the generated common repository stays optional during outages');
like(read_file($template_log), qr/^repo_gpgcheck=1$/m,
    'the generated common repository verifies signed metadata');

my $fake_bin = "$tmpdir/fake-bin";
make_path($fake_bin);
open(my $fake_mktemp_fh, '>', "$fake_bin/mktemp")
  or die "open fake mktemp: $!";
print {$fake_mktemp_fh} "#!/bin/sh\nexit 99\n";
close($fake_mktemp_fh) or die "close fake mktemp: $!";
chmod(0755, "$fake_bin/mktemp") or die "chmod fake mktemp: $!";

SKIP: {
    skip 'root execution would use go-xcat global diagnostic paths', 4
      if $> == 0;
    local $ENV{PATH} = "$fake_bin:$ENV{PATH}";
    my $stderr = gensym;
    my $pid = open3(my $stdin, my $stdout, $stderr, 'bash', '-s', '--', '-h');
    open(my $source_fh, '<', $go_xcat) or die "open $go_xcat: $!";
    while (my $line = <$source_fh>) {
        print {$stdin} $line;
    }
    close($source_fh) or die "close $go_xcat: $!";
    close($stdin) or die "close go-xcat stdin: $!";
    my $output = do { local $/; <$stdout> };
    my $errors = do { local $/; <$stderr> };
    waitpid($pid, 0);
    my $status = $? >> 8;
    is($status, 1, 'an unprivileged standard-input execution is rejected');
    like($errors, qr/Must be run by UID=0/,
        'the standard-input execution reports the root requirement');
    unlike($errors, qr/return:/,
        'standard-input execution does not mistake the script for a sourced file');
    unlike($errors, qr/mktemp/,
        'standard-input execution keeps the hardened command path');
}

done_testing();
