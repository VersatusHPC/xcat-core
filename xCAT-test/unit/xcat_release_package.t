#!/usr/bin/env perl
use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

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

my $builder = read_file('buildrpms.pl');
like($builder, qr/^\s+xCAT-release\s*$/m, 'default RPM build includes xCAT-release');
like(
    $builder,
    qr{\$repodir/xCAT-release-latest\.noarch\.rpm},
    'stable bootstrap alias follows the package name'
);
like(
    $builder,
    qr{\$repodir/xCAT-release-\$VERSION-\$RELEASE\.noarch\.rpm},
    'stable bootstrap alias selects the xCAT-release RPM'
);
like(
    $builder,
    qr/unlink \$alias.*?createrepo_dir\(\$repodir/s,
    'stable bootstrap alias is excluded from repository metadata'
);
like(
    $builder,
    qr/cp \$release_rpms\[0\], \$alias/,
    'repository export creates the stable bootstrap filename'
);
my $sign_call = rindex($builder, 'sign_rpms($target)');
my $alias_call = rindex($builder, 'write_release_alias("dist/$target/rpms")');
ok(
    $sign_call >= 0 && $alias_call > $sign_call,
    'stable bootstrap alias is created after signed metadata is finalized'
);
like(
    $builder,
    qr/sub merge_core_repos \{.*?write_repo_metadata_dir\(\$out\);.*?write_release_alias\(\$out\);/s,
    'assembled core repository creates the stable alias after final metadata'
);

# The buildrpms.pl checks above match its text, so a guard that stops creating
# the alias leaves them green. Run write_release_alias and check the file.
{
    my ($alias_sub) = $builder =~ /^(sub write_release_alias \{\n.*?^\}\n)/ms;
    BAIL_OUT('buildrpms.pl no longer defines write_release_alias') unless $alias_sub;

    my $code = join("\n",
        'package XCATTest::ReleaseAlias;',
        'use strict; use warnings;',
        'use File::Copy qw(cp);',
        "our \$VERSION = '9.9.9';",
        "our \$RELEASE = 'snap000000000000';",
        $alias_sub,
        '1;');
    eval $code;    ## no critic
    BAIL_OUT("unable to compile the extracted write_release_alias: $@") if $@;

    my $repodir = tempdir(CLEANUP => 1);
    my $alias = File::Spec->catfile($repodir, 'xCAT-release-latest.noarch.rpm');

    # A build that produces no xCAT-release rpm must not create the alias and
    # must not die. glob() returns its pattern verbatim when nothing matches.
    XCATTest::ReleaseAlias::write_release_alias($repodir);
    ok(!-e $alias, 'no stable alias is written when the build produced no xCAT-release rpm');

    my $rpm = File::Spec->catfile($repodir, 'xCAT-release-9.9.9-snap000000000000.noarch.rpm');
    open(my $rfh, '>', $rpm) or die "open $rpm: $!";
    print {$rfh} "not really an rpm\n";
    close($rfh) or die "close $rpm: $!";

    XCATTest::ReleaseAlias::write_release_alias($repodir);
    ok(-f $alias, 'the stable bootstrap alias is created from the xCAT-release rpm');
  SKIP: {
        skip('no alias file to inspect', 2) unless -f $alias;
        is(read_path($alias), "not really an rpm\n", 'the alias is a copy of the xCAT-release rpm');
        is(sprintf('%04o', (stat($alias))[2] & 07777), '0644', 'the alias is world readable');
    }
}

done_testing();

sub read_path {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "open $path: $!";
    my $contents = do { local $/; <$fh> };
    close($fh) or die "close $path: $!";
    return $contents;
}

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
