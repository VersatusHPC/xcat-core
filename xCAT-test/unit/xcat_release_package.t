#!/usr/bin/env perl
use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../build-utils/lib";
use Test::More;
use xCAT::Build::Repository qw(
  default_packages finalize_repository remove_release_alias write_release_alias
);

my $repo_root = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..', '..'));

my $spec = read_file('xCAT-release/xCAT-release.spec');
like($spec, qr/^Name:\s+xCAT-release$/m, 'package has the expected name');
like($spec, qr/^Source0:\s+xCAT-release-%\{version\}\.tar\.gz$/m, 'source archive follows the package name');
like($spec, qr/^BuildArch:\s+noarch$/m, 'package is architecture independent');
like($spec, qr/^Requires:\s+dnf$/m, 'package is limited to DNF-based systems');
like($spec, qr/^%config\(noreplace\) .*xcat-core\.repo$/m, 'core repo preserves local changes');
like($spec, qr/^%config\(noreplace\) .*xcat-dep\.repo$/m, 'dependency repo preserves local changes');
like($spec, qr/^%config\(noreplace\) .*xcat-dep-common\.repo$/m, 'common dependency repo preserves local changes');
like($spec, qr{RPM-GPG-KEY-xCAT}, 'package installs the signing key');

my $core = read_file('xCAT-release/xcat-core.repo');
assert_repo_security($core, 'core');
like(
    $core,
    qr{^baseurl=https://xcat\.org/files/xcat/repos/yum/latest/xcat-core$}m,
    'core repo uses the stable HTTPS endpoint'
);

my $dep = read_file('xCAT-release/xcat-dep.repo');
assert_repo_security($dep, 'dependency');
like(
    $dep,
    qr{^baseurl=https://xcat\.org/files/xcat/repos/yum/latest/xcat-dep/rh\$releasever/\$basearch$}m,
    'dependency repo follows the DNF release and architecture variables'
);

my $common_dep = read_file('xCAT-release/xcat-dep-common.repo');
assert_repo_security($common_dep, 'common dependency');
like(
    $common_dep,
    qr/^skip_if_unavailable=1$/m,
    'an unavailable common repository does not block package operations',
);
like(
    $common_dep,
    qr{^baseurl=https://xcat\.org/files/xcat/repos/yum/latest/xcat-dep/common$}m,
    'common dependency repo is independent of the management-node distribution'
);

my $key = read_file('xCAT-release/RPM-GPG-KEY-xCAT');
like($key, qr/^-----BEGIN PGP PUBLIC KEY BLOCK-----$/m, 'signing key is ASCII armored');
is(
    sha256_hex($key),
    '72076f25ce4929d34a67e305327a37f89c964d3cbf1821e3afad4907c9d91249',
    'packaged key matches the published xCAT signing key'
);

my %default_package = map { $_ => 1 } default_packages();
ok($default_package{'xCAT-release'}, 'default RPM build includes xCAT-release');

my $repo = tempdir(CLEANUP => 1);
my $release_rpm = File::Spec->catfile($repo, 'xCAT-release-2.19.0-1.noarch.rpm');
open(my $release_fh, '>', $release_rpm) or die "open $release_rpm: $!";
print {$release_fh} "signed release package\n";
close($release_fh);
ok(write_release_alias($repo, '2.19.0', '1'),
    'repository export creates the stable bootstrap alias');
is(read_file_path(File::Spec->catfile($repo, 'xCAT-release-latest.noarch.rpm')),
    "signed release package\n",
    'stable bootstrap alias contains the selected release package');
ok(remove_release_alias($repo),
    'repository indexing removes the direct-download alias');
ok(!-e File::Spec->catfile($repo, 'xCAT-release-latest.noarch.rpm'),
    'the direct-download alias is absent while metadata is generated');
ok(!remove_release_alias($repo),
    'removing an already absent alias is harmless');
ok(write_release_alias($repo, '2.19.0', '1'),
    'the direct-download alias can be restored after metadata generation');

my @steps;
finalize_repository(
    index    => sub { push @steps, 'index'; },
    sign     => sub { push @steps, 'sign'; },
    metadata => sub { push @steps, 'metadata'; },
    alias    => sub { push @steps, 'alias'; },
);
is_deeply(\@steps, [qw(index sign metadata alias)],
    'repository finalization creates the alias after signed metadata');

@steps = ();
finalize_repository(
    index    => sub { push @steps, 'index'; },
    metadata => sub { push @steps, 'metadata'; },
    alias    => sub { push @steps, 'alias'; },
);
is_deeply(\@steps, [qw(index metadata alias)],
    'unsigned repository finalization still creates the alias last');

my @targets = qw(el9-x86_64 el9-ppc64le);
@steps = ();
finalize_repository(
    index => sub { push @steps, map { "index:$_" } @targets; },
    sign => sub { push @steps, map { "sign:$_" } @targets; },
    metadata => sub { push @steps, map { "metadata:$_" } @targets; },
    alias => sub { push @steps, map { "alias:$_" } @targets; },
);
is_deeply(
    \@steps,
    [
        qw(
          index:el9-x86_64 index:el9-ppc64le
          sign:el9-x86_64 sign:el9-ppc64le
          metadata:el9-x86_64 metadata:el9-ppc64le
          alias:el9-x86_64 alias:el9-ppc64le
        )
    ],
    'multi-target repository phases finish before the next phase starts',
);

done_testing();

sub assert_repo_security {
    my ($content, $label) = @_;
    like($content, qr/^enabled=1$/m, "$label repo is enabled");
    like($content, qr/^gpgcheck=1$/m, "$label repo verifies packages");
    like($content, qr/^repo_gpgcheck=1$/m, "$label repo verifies repository metadata");
    like(
        $content,
        qr{^gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-xCAT$}m,
        "$label repo uses the packaged signing key"
    );
}

sub read_file {
    my ($file) = @_;
    my $path = File::Spec->catfile($repo_root, split m{/}, $file);
    open(my $fh, '<', $path) or die "open $path: $!";
    my $contents = do { local $/; <$fh> };
    close($fh) or die "close $path: $!";
    return $contents;
}

sub read_file_path {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "open $path: $!";
    my $contents = do { local $/; <$fh> };
    close($fh) or die "close $path: $!";
    return $contents;
}
