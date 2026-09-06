#!/usr/bin/env perl
use strict;
use warnings;

use Cwd ();
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Slurper qw(write_text);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../build-utils/lib";
use Test::More;

use XCAT::BuildUtils qw(XCAT_PROBE_HELPERS);
use XCAT::Test::File qw(repo_path slurp_repo_file);

my @helpers = qw(
    CommandUtils.pm
    GlobalDef.pm
    NetworkUtils.pm
    ServiceNodeUtils.pm
);
my @affected_subcommands = qw(
    code_template
    discovery
    osdeploy
    xcatmn
);

my $builder = slurp_repo_file('buildrpms.pl');
my $debian_builder = slurp_repo_file('build-ubunturepo');
my $installed_probe_test =
  slurp_repo_file('xCAT-test/autotest/testcase/probe/xcatproble_list');
my $rpm_spec = slurp_repo_file('xCAT-probe/xCAT-probe.spec');
my $debian_control = slurp_repo_file('xCAT-probe/debian/control');
like($builder, qr/sub prepare_xcat_probe_source_tar\b/, 'RPM builder has dedicated xCAT-probe source preparation');
like(
    $builder,
    qr/for my \$helper \(\@XCAT_PROBE_HELPERS\).*?cp "perl-xCAT\/xCAT\/\$helper", \$destination;/s,
    'RPM builder copies every declared helper into the staged package tree'
);
like($builder, qr/tempfile\(.*?DIR\s*=>\s*\$SOURCES/s, 'RPM builder writes a unique archive in the source directory');
like($builder, qr/--use-compress-program="gzip -n"/, 'RPM builder normalizes gzip metadata');
like($builder, qr/rename\s+\$archive_path,\s*\$source_tarball/, 'RPM builder publishes the source archive atomically');
like(
    $builder,
    qr/elsif \(\$pkg eq "xCAT-probe"\)\s*\{.*?\breturn;/s,
    'target workers reuse the source archive prepared before the fork'
);

my $prepare_call = rindex($builder, 'prepare_xcat_probe_source_tar()');
my $worker_fanout = index($builder, 'Parallel::ForkManager->new');
ok(
    $prepare_call >= 0 && $worker_fanout >= 0 && $prepare_call < $worker_fanout,
    'xCAT-probe source preparation runs before worker processes fork'
);

like(
    $rpm_spec,
    qr/%if 0%\{\?suse_version\}\s+Requires: iproute2\s+%else\s+Requires: iproute\s+%endif/s,
    'RPM package requires the distro-specific provider of ss'
);
like(
    $debian_control,
    qr/^Depends:.*\biproute2\s*\|\s*net-tools\b/m,
    'Debian package requires ss or the legacy netstat provider'
);

for my $helper (@helpers) {
    my $source = repo_path(File::Spec->catfile('perl-xCAT', 'xCAT', $helper));
    ok(-f $source, "$helper source exists");
    like($builder, qr/^\s*\Q$helper\E\s*$/m, "RPM builder stages $helper");
    ok(
        scalar(grep { $_ eq $helper } XCAT_PROBE_HELPERS),
        "the shared builder helper list carries $helper"
    );
    like(
        $debian_builder,
        qr{cp -f [^\n]*/perl-xCAT/xCAT/\Q$helper\E\s+[^\n]*/lib/perl/xCAT/},
        "Debian builder stages $helper"
    );
    like(
        $installed_probe_test,
        qr/cmd:for module in [^;]*\b\Q$helper\E\b[^;]*; do test -r/,
        "installed probe payload checks $helper"
    );
}

my $tmpdir = tempdir(CLEANUP => 1);
my $xcatroot = File::Spec->catdir($tmpdir, 'opt', 'xcat');
my $probe_root = File::Spec->catdir($xcatroot, 'probe');
my $bin_dir = File::Spec->catdir($xcatroot, 'bin');
my $subcmd_dir = File::Spec->catdir($probe_root, 'subcmds');
my $helper_dir = File::Spec->catdir($probe_root, 'lib', 'perl', 'xCAT');

# The checks above match the text of buildrpms.pl, so a staging routine that
# stops running leaves them green. Run the routine and build the package
# fixture out of the archive it writes, so every check below depends on it.
my $staged = stage_xcat_probe_source($tmpdir);

make_path($probe_root, $bin_dir);
copy_tree(File::Spec->catdir($staged, 'lib'), File::Spec->catdir($probe_root, 'lib'));
copy_tree(File::Spec->catdir($staged, 'subcmds'), $subcmd_dir);

my $xcatprobe_source = File::Spec->catfile($staged, 'xcatprobe');
my $xcatprobe = File::Spec->catfile($bin_dir, 'xcatprobe');
copy($xcatprobe_source, $xcatprobe) or die "copy $xcatprobe_source: $!";
chmod 0755, $xcatprobe or die "chmod $xcatprobe: $!";

make_path(File::Spec->catdir($subcmd_dir, 'bin'));
for my $helper (@helpers) {
    ok(-f File::Spec->catfile($helper_dir, $helper),
        "the staged source archive carries $helper");
}

my $xcatclient = File::Spec->catfile($bin_dir, 'xcatclient');
write_text($xcatclient, "#!/bin/sh\nprintf '[ok]:dummy xcatclient\\n'\n");
chmod 0755, $xcatclient or die "chmod $xcatclient: $!";

local $ENV{XCATROOT} = $xcatroot;
local $ENV{PATH} = "$bin_dir:$ENV{PATH}";
local $ENV{PERL5LIB};
local $ENV{PERL5OPT};
local $ENV{PERLLIB};
delete $ENV{PERL5LIB};
delete $ENV{PERL5OPT};
delete $ENV{PERLLIB};

for my $subcommand (@affected_subcommands) {
    my $command = File::Spec->catfile($subcmd_dir, $subcommand);
    my ($rc, $output) = run_command($command, '-T');
    is($rc, 0, "$subcommand self-test exits successfully") or diag($output);
    like($output, qr/^\[ok\]\s*:/m, "$subcommand self-test reports ready");
}

my ($list_rc, $list_output) = run_command($xcatprobe, '-l');
is($list_rc, 0, 'xcatprobe list exits successfully') or diag($list_output);
my %listed = map { /^([^\s].*?)\s/ ? ($1 => 1) : () } split /\n/, $list_output;
for my $subcommand (@affected_subcommands) {
    ok($listed{$subcommand}, "xcatprobe lists $subcommand") or diag($list_output);
}

done_testing();

sub stage_xcat_probe_source {
    my ($workdir) = @_;

    my ($helpers_decl) = $builder =~ /^(my \@XCAT_PROBE_HELPERS = qw\(.*?\);)/ms;
    my ($prepare_sub) = $builder =~ /^(sub prepare_xcat_probe_source_tar \{\n.*?^\}\n)/ms;
    BAIL_OUT('buildrpms.pl no longer declares @XCAT_PROBE_HELPERS') unless $helpers_decl;
    BAIL_OUT('buildrpms.pl no longer defines prepare_xcat_probe_source_tar') unless $prepare_sub;

    my $sources = File::Spec->catdir($workdir, 'SOURCES');
    my $unpacked = File::Spec->catdir($workdir, 'unpacked');
    make_path($sources, $unpacked);

    my $code = join("\n",
        'package XCATTest::BuildRpms;',
        'use strict; use warnings;',
        'use File::Copy qw(cp);',
        'use File::Path qw(make_path remove_tree);',
        'use File::Temp qw(tempdir tempfile);',
        "our \$SOURCES = '$sources';",
        "our \$VERSION = 'test';",
        'our $SOURCE_DATE_EPOCH = 0;',
        # The routine runs shell commands through a helper. Take the one the
        # repository provides when it has one, and fall back to a minimal
        # runner when the helper lives in buildrpms.pl itself.
        'use lib "' . repo_path('build-utils/lib') . '";',
        'BEGIN { eval { require XCAT::BuildUtils; XCAT::BuildUtils->import(qw(sh sh_or_die)); 1 } }',
        'BEGIN { no strict "refs"; *sh = sub { return system("/bin/sh", "-c", $_[0]) >> 8 } unless defined &sh }',
        'BEGIN { no strict "refs"; *sh_or_die = sub { my ($c, $m) = @_; system("/bin/sh", "-c", $c) == 0 or die($m || "failed: $c"); return 0 } unless defined &sh_or_die }',
        $helpers_decl,
        $prepare_sub,
        '1;');
    eval $code;    ## no critic
    BAIL_OUT("unable to compile the extracted buildrpms.pl routine: $@") if $@;

    my $cwd = Cwd::getcwd();
    chdir(repo_path('.')) or BAIL_OUT("chdir to the repository root: $!");
    eval { XCATTest::BuildRpms::prepare_xcat_probe_source_tar(); 1 }
        or do { my $err = $@; chdir($cwd); BAIL_OUT("prepare_xcat_probe_source_tar died: $err") };
    chdir($cwd) or BAIL_OUT("chdir back to $cwd: $!");

    my $tarball = File::Spec->catfile($sources, 'xCAT-probe-test.tar.gz');
    ok(-f $tarball, 'prepare_xcat_probe_source_tar writes the xCAT-probe source archive')
        or BAIL_OUT('no source archive to build the package fixture from');
    is(system('tar', '-xzf', $tarball, '-C', $unpacked), 0, 'the source archive unpacks')
        or BAIL_OUT("unable to unpack $tarball");

    return File::Spec->catdir($unpacked, 'xCAT-probe');
}

sub copy_tree {
    my ($source, $destination) = @_;
    my $rc = system('cp', '-R', $source, $destination);
    is($rc, 0, "copied $source into the package fixture")
        or BAIL_OUT("unable to create package fixture from $source");
}

sub run_command {
    my (@command) = @_;
    open(my $fh, '-|', @command) or die "run @command: $!";
    my $output = do { local $/; <$fh> };
    close($fh);
    return ($? >> 8, $output // '');
}
