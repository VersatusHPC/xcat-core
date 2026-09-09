use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

# SN_setup_case builds the service-node otherpkglist path from the node's os and arch, then
# chdefs it onto the osimage. When the named file is absent the otherpkgs postbootscript
# installs nothing and still exits 0, so xCATsn never lands and xcatd never starts on the
# service node. Run the case's own shell with chdef shadowed, and check that the path it
# produces is a file this repository actually ships.

my $repo_root = File::Spec->catdir($FindBin::Bin, '..', '..');
my $case = File::Spec->catfile(
    $repo_root, 'xCAT-test/autotest/testcase/installation/SN_setup_case'
);

open(my $fh, '<', $case) or BAIL_OUT("cannot read $case: $!");
my @cmds = grep { /^cmd:.*chdef -t osimage .*otherpkglist=/ } <$fh>;
close($fh);
BAIL_OUT("SN_setup_case no longer carries a chdef of otherpkglist; this test covers nothing")
  unless @cmds == 1;

my $snippet = $cmds[0];
$snippet =~ s/^cmd://;
chomp $snippet;

#-----------------------------------------------------------------------------------------------
# otherpkglist_for: run the case's own command with chdef replaced by a printer, and return the
#     otherpkglist path it would set for one os and arch.
#-----------------------------------------------------------------------------------------------
sub otherpkglist_for {
    my ($os, $arch) = @_;
    my $cmd = $snippet;
    $cmd =~ s/__GETNODEATTR\([^)]*,os\)__/$os/g;
    $cmd =~ s/__GETNODEATTR\([^)]*,arch\)__/$arch/g;
    my $dir = tempdir(CLEANUP => 1);
    my $script = File::Spec->catfile($dir, 'run.sh');
    open(my $out, '>', $script) or die "cannot write $script: $!";
    # bash resolves a function before PATH, so the case's chdef reaches this printer, not xCAT.
    print $out "chdef() { printf '%s\\n' \"\$@\"; }\n", $cmd, "\n";
    close($out);
    my @printed = `bash $script 2>&1`;
    is($? >> 8, 0, "the SN_setup_case osimage command runs for $os $arch");
    my ($value) = map { /^otherpkglist=(.+)$/ ? $1 : () } @printed;
    return $value;
}

my $shipped = File::Spec->catdir($repo_root, 'xCAT-server/share/xcat/install');

for my $target ([ 'alma9.8', 'x86_64' ], [ 'alma9.8', 'ppc64le' ]) {
    my ($os, $arch) = @$target;
    my $path = otherpkglist_for($os, $arch);
    ok(defined $path && length $path, "$os $arch: the case names an otherpkglist");
    next unless defined $path;

    my $rel = $path;
    $rel =~ s{^/opt/xcat/share/xcat/install/}{}
      or die "unexpected otherpkglist location: $path";
    my $file = File::Spec->catfile($shipped, $rel);

    ok(-r $file, "$os $arch: xCAT-server ships $rel");
    next unless -r $file;

    open(my $list, '<', $file) or die "cannot read $file: $!";
    my $body = do { local $/; <$list> };
    close($list);
    like($body, qr{^xcat/xcat-core/xCATsn$}m,
        "$os $arch: the list installs xCATsn on the service node");
    like($body, qr{^xcat/xcat-dep/rh9/\Q$arch\E/goconserver$}m,
        "$os $arch: the list installs the $arch goconserver");
}

done_testing();
