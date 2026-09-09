#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

# SN_setup_case prepares the service node's otherpkgs repositories and names its
# otherpkgs pkglist. Both are family-specific: an EL service node reads an rpm-md
# repository built by createrepo, a Debian one reads an apt repository that is
# already indexed, and the two families ship different pkglist names. Run the
# case's own command text against a scratch tree with the tools shadowed, rather
# than reading the file and believing it.

my $case = "$FindBin::Bin/../autotest/testcase/installation/SN_setup_case";
plan skip_all => "SN_setup_case not found" unless -r $case;

my $text = do { local (@ARGV, $/) = ($case); <> };

# Pull the three commands out by what makes each one unique. BAIL_OUT rather than
# skip: an extraction that stops matching must fail loudly, not cover nothing.
sub command_matching {
    my ($what, $re) = @_;
    my @hit = grep { $_ =~ $re } ($text =~ /^cmd:(.*)$/mg);
    BAIL_OUT("SN_setup_case no longer carries the $what command") unless @hit == 1;
    return $hit[0];
}
my $core_repo = command_matching('xcat-core otherpkgs repository', qr{xcat/xcat-core});
my $dep_repo  = command_matching('xcat-dep otherpkgs repository',  qr{xcat/xcat-dep});
my $pkglist   = command_matching('otherpkgs pkglist',              qr{otherpkglist=});

my $INSTALL = '/install/post/otherpkgs';
my $SHARE   = '/opt/xcat/share/xcat/install';

# One scratch world per case: the otherpkgs trees the command expects, plus stubs
# for the tools it calls. bash resolves a function or a PATH entry before the real
# binary, so nothing here can reach the host.
sub world {
    my ($os, $arch, @repo_dirs) = @_;
    my $root = tempdir(CLEANUP => 1);
    make_path("$root$INSTALL/$os/$arch/$_") for @repo_dirs;
    make_path("$root$SHARE");
    make_path("$root/bin");
    for my $tool (qw(createrepo)) {
        open(my $fh, '>', "$root/bin/$tool") or die "cannot write $tool stub: $!";
        print $fh "#!/bin/sh\ntouch '$root/$tool.called'\nexit 0\n";
        close($fh);
        chmod(0755, "$root/bin/$tool");
    }
    open(my $fh, '>', "$root/bin/chdef") or die "cannot write chdef stub: $!";
    print $fh "#!/bin/sh\nprintf '%s\\n' \"\$*\" >> '$root/chdef.log'\nexit 0\n";
    close($fh);
    chmod(0755, "$root/bin/chdef");
    return $root;
}

# Substitute the case's node macros, then move its absolute paths into the scratch
# world. A substitution that changes nothing means the path moved: fail loudly.
sub localise {
    my ($cmd, $root, $os, $arch) = @_;
    $cmd =~ s/__GETNODEATTR\(\$\$SN,os\)__/$os/g;
    $cmd =~ s/__GETNODEATTR\(\$\$SN,arch\)__/$arch/g;
    my $moved = ($cmd =~ s{\Q$INSTALL\E}{$root$INSTALL}g)
              + ($cmd =~ s{\Q$SHARE\E}{$root$SHARE}g);
    BAIL_OUT("no absolute xCAT path left to sandbox in: $cmd") unless $moved;
    return $cmd;
}

sub run_in {
    my ($root, $cmd) = @_;
    local $ENV{PATH} = "$root/bin:$ENV{PATH}";
    my $rc = system('bash', '-c', $cmd);
    return $rc >> 8;
}

# --- the xcat-core otherpkgs repository ------------------------------------
{
    my $root = world('ubuntu24.04.4', 'ppc64el', 'xcat/xcat-core/dists', 'xcat/xcat-core/pool');
    my $rc = run_in($root, localise($core_repo, $root, 'ubuntu24.04.4', 'ppc64el'));
    is($rc, 0, 'the xcat-core otherpkgs repository succeeds on a Debian service node');
    ok(!-e "$root/createrepo.called",
        'an apt repository is not rebuilt with createrepo');
}
{
    my $root = world('alma9', 'ppc64le', 'xcat/xcat-core');
    my $rc = run_in($root, localise($core_repo, $root, 'alma9', 'ppc64le'));
    is($rc, 0, 'the xcat-core otherpkgs repository still succeeds on EL');
    ok(-e "$root/createrepo.called", 'EL still indexes its repository with createrepo');
}

# --- the xcat-dep otherpkgs repository -------------------------------------
{
    my $root = world('ubuntu24.04.4', 'ppc64el', 'xcat/xcat-dep/dists', 'xcat/xcat-dep/pool');
    my $rc = run_in($root, localise($dep_repo, $root, 'ubuntu24.04.4', 'ppc64el'));
    is($rc, 0, 'the xcat-dep otherpkgs repository succeeds on a Debian service node');
    ok(!-e "$root/createrepo.called",
        'the Debian xcat-dep repository is not rebuilt with createrepo');
}

# --- the otherpkgs pkglist -------------------------------------------------
{
    my $root = world('ubuntu24.04.4', 'ppc64el');
    my $rc = run_in($root, localise($pkglist, $root, 'ubuntu24.04.4', 'ppc64el'));
    is($rc, 0, 'the pkglist command succeeds on a Debian service node');
    my $log = -e "$root/chdef.log"
        ? do { local (@ARGV, $/) = ("$root/chdef.log"); <> } : '';
    like($log, qr{ubuntu/service\.ubuntu\.otherpkgs\.pkglist},
        'a Debian service node is given the pkglist Ubuntu ships');
    unlike($log, qr{install//service}, 'the family directory is not empty');
}
{
    my $root = world('alma9', 'ppc64le');
    my $rc = run_in($root, localise($pkglist, $root, 'alma9', 'ppc64le'));
    is($rc, 0, 'the pkglist command still succeeds on EL');
    my $log = -e "$root/chdef.log"
        ? do { local (@ARGV, $/) = ("$root/chdef.log"); <> } : '';
    like($log, qr{alma/service\.alma9\.ppc64le\.otherpkgs\.pkglist},
        'EL still gets its version and architecture qualified pkglist');
}

done_testing();
