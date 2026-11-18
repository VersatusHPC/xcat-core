#!/usr/bin/env perl
# buildrpms.pl builds every package of a target in its own mock buildroot. The
# buildroots must share one cache per target, and each build must remove its
# buildroots at the end. A root per package kept a root_cache and a dnf_cache for
# every package, and a buildroot for every package stayed in /var/lib/mock.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../build-utils/lib";
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use XCAT::BuildUtils qw(mock_config_text);

my $base = <<'CFG';
include('almalinux-10-x86_64.cfg')
config_opts['root'] = "alma+epel-10-{{ target_arch }}"
CFG
my $target = 'alma+epel-10-x86_64';

# mock takes the last assignment.
sub effective {
    my ($text, $opt) = @_;
    my $v;
    for my $line (split /\n/, $text) {
        $v = $1 if $line =~ /\Aconfig_opts\['\Q$opt\E'\]\s*=\s*(.+?)\s*\z/;
    }
    return $v;
}

# mock puts the caches in /var/cache/mock/<root> and the buildroot in
# /var/lib/mock/<root>-<unique-ext>.
my %cfg = map { $_ => mock_config_text($_, $target, $base, 1, 'ci') }
    qw(xCAT xCAT-server perl-xCAT);
is(effective($cfg{$_}, 'root'), qq("$target"), "$_ uses the cache of the target")
    for sort keys %cfg;
is(effective($cfg{xCAT}, 'unique-ext'), "'ci-xCAT'", 'xCAT builds in its own buildroot');
is(effective($cfg{'xCAT-server'}, 'unique-ext'), "'ci-xCAT-server'",
    'and xCAT-server in another one');
unlike($cfg{'perl-xCAT'}, qr/chroot_additional_packages/,
    'perl-xCAT puts nothing into the shared root cache');
is(effective(mock_config_text('xCAT', $target, "include('x.cfg')\n", 1, ''), 'root'),
    qq("$target"), 'a target configuration with no root line still gets the shared root');

my $layout = XCAT::BuildUtils::mock_root_layout('xCAT-server', $target, 'ci');
is_deeply($layout, {
    config    => "xCAT-server-$target-ci",
    root      => $target,
    uniqueext => 'ci-xCAT-server',
    buildroot => "$target-ci-xCAT-server",
    bootstrap => "$target-bootstrap-ci-xCAT-server",
}, 'the mock -r name is unchanged and the buildroot names follow mock');
is(XCAT::BuildUtils::mock_root_layout('xCAT', $target, '')->{buildroot}, "$target-xCAT",
    'without --mock-uniqueext the package alone separates the buildroots');

is_deeply([ XCAT::BuildUtils::mock_additional_packages('perl-xCAT', $target) ],
    ['perl-generators'], 'perl-xCAT installs perl-generators with its build dependencies');
is_deeply([ XCAT::BuildUtils::mock_additional_packages('perl-xCAT', 'opensuse-leap-15.6-x86_64') ],
    [], 'but not on openSUSE, which has no perl-generators');
is_deeply([ XCAT::BuildUtils::mock_additional_packages('xCAT', $target) ], [],
    'and no other package gets it');

# The scrub removes the buildroots and never the caches.
my $lib = tempdir(CLEANUP => 1);
my $plan = XCAT::BuildUtils::mock_scrub_plan($layout, $lib);
is_deeply($plan, { command => undef, remove => [], keep => [] },
    'nothing to do when the package built nothing');

make_path("$lib/$layout->{buildroot}/root", "$lib/$layout->{bootstrap}/root", "$lib/$target");
$plan = XCAT::BuildUtils::mock_scrub_plan($layout, $lib);
is_deeply($plan->{command}, [ 'mock', '-r', "xCAT-server-$target-ci", '--scrub=chroot' ],
    'mock removes the package buildroot');
is_deeply($plan->{remove}, ["$lib/$layout->{bootstrap}"],
    'the bootstrap buildroot is deleted by hand, because --scrub=bootstrap deletes its cache');
ok(!grep({ index($_, "$lib/$target") == 0 && $_ !~ /-xCAT-server\z/ } @{ $plan->{remove} }),
    'no directory of another package or of the target is removed');

$plan = XCAT::BuildUtils::mock_scrub_plan($layout, $lib, "$lib/$layout->{bootstrap}/root/proc");
is_deeply([ $plan->{remove}, $plan->{keep} ], [ [], ["$lib/$layout->{bootstrap}"] ],
    'a bootstrap buildroot with a mount under it is kept');

# The scrub runs at the end of the build, whether it passed or failed.
my @ran;
my $got = XCAT::BuildUtils::run_then_scrub(sub { push @ran, 'build'; 'built' },
    sub { push @ran, 'scrub' });
is_deeply(\@ran, [qw(build scrub)], 'a successful build is scrubbed');
is($got, 'built', 'and its result is returned');

@ran = ();
my $ok = eval {
    XCAT::BuildUtils::run_then_scrub(sub { push @ran, 'build'; die "rpm rebuild failed\n" },
        sub { push @ran, 'scrub' });
    1;
};
is_deeply(\@ran, [qw(build scrub)], 'a failed build is scrubbed too');
is($ok ? '' : $@, "rpm rebuild failed\n", 'and its error still reaches the caller');

done_testing();
