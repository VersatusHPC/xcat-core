#!/usr/bin/env perl
# The Genesis awk programs run under the image's own awk. On Ubuntu the default awk is mawk,
# which cannot parse them, so the Ubuntu Genesis image has to carry gawk.
use strict;
use warnings;

use File::Path qw(make_path);
use File::Slurper qw(read_text write_text);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use XCAT::Test::File qw(repo_path);

my $module   = repo_path('xCAT-genesis-builder/dracut_105/ubuntu/module-setup.sh');
my $builddeb = repo_path('xCAT-genesis-builder/builddeb-genesis-base');
my $verifier = repo_path('xCAT-genesis-builder/verify-genesis-payload');
plan skip_all => 'Ubuntu Genesis builder not found'
  unless -f $module && -f $builddeb && -f $verifier;
plan tests => 10;

my $tmpdir = tempdir(CLEANUP => 1);

# The four programs the Genesis image runs under awk. Each opens a TCP stream with the gawk
# /inet/ coprocess, which mawk rejects at parse time.
my @gawk_only = map { "xCAT-genesis-scripts/usr/bin/$_" }
  qw(updateflag.awk minixcatd.awk udpcat.awk allowcred.awk);

SKIP: {
    my $mawk = which('mawk');
    skip 'mawk is not installed', 1 unless $mawk;
    my @parsed;
    foreach my $program (@gawk_only) {
        my $path = repo_path($program);
        next unless -f $path;
        system("$mawk -f '$path' </dev/null >/dev/null 2>&1");
        push @parsed, $program if ($? >> 8) == 0;
    }
    is_deeply(\@parsed, [], 'mawk cannot run any Genesis awk program');
}

#---
# The dracut module names the commands the image carries. "awk" on the build host is the
# alternative, so the module has to name gawk.
#---
my ($calls, $initdir) = drive_install($module);
ok(grep({ $_ eq 'gawk' } @$calls), 'the Ubuntu dracut module stages gawk');
ok(!grep({ m{^/usr/bin/awk$} || $_ eq 'awk' } @$calls),
    'the Ubuntu dracut module does not stage the build host awk alternative');
my $awk = "$initdir/usr/bin/awk";
ok(-l $awk, 'install() leaves usr/bin/awk in the payload');
is(readlink($awk) || '', 'gawk', 'usr/bin/awk points at gawk');

#---
# builddeb-genesis-base builds on the running host with --no-install-recommends, so gawk has
# to be one of the packages it installs, and the payload gate has to run.
#---
my $builddeb_text = read_text($builddeb);
like($builddeb_text, qr/^\s*gawk\b/m, 'builddeb-genesis-base installs gawk on the build host');
like($builddeb_text, qr/verify-genesis-payload/, 'builddeb-genesis-base runs the payload gate');

#---
# The gate reads the payload, so it catches an image built where awk resolved to mawk.
#---
my ($rc, $err) = run_verifier(payload(awk => 'mawk'));
isnt($rc, 0, 'a payload whose awk is mawk fails the gate');
like($err, qr{usr/bin/awk}, 'the wrong awk is named');

($rc, $err) = run_verifier(payload(awk => 'gawk'));
is($rc, 0, 'a payload whose awk is gawk passes the gate') or diag($err);

#---
# which: the first NAME on PATH, or undef.
#---
sub which {
    my ($name) = @_;
    foreach my $dir (split /:/, $ENV{PATH} || '') {
        return "$dir/$name" if -x "$dir/$name";
    }
    return;
}

#---
# drive_install: run install() from a dracut module with the dracut helpers replaced by shell
# functions that record their arguments. bash resolves a function before PATH, so the module
# runs without dracut and without root. Returns the recorded names and the payload directory.
#---
sub drive_install {
    my ($path) = @_;
    my $root  = tempdir(DIR => $tmpdir, CLEANUP => 1);
    my $log   = "$root.calls";
    my $shim  = "$root.sh";
    write_text($shim, <<'SHIM');
set +u
mod=$1; export initdir=$2; out=$3
: > "$out"
mkdir -p "$initdir/usr/bin" "$initdir/usr/sbin" "$initdir/bin" "$initdir/sbin"
dracut_install() { for a in "$@"; do echo "$a" >> "$out"; done; }
inst() { :; }
inst_script() { :; }
inst_hook() { :; }
inst_dir() { :; }
inst_multiple() { for a in "$@"; do echo "$a" >> "$out"; done; }
inst_symlink() { :; }
instmods() { :; }
derror() { echo "derror: $*" >&2; }
dwarn() { :; }
dinfo() { :; }
. "$mod"
install
SHIM
    system("/bin/bash '$shim' '$path' '$root' '$log' >/dev/null 2>&1");
    BAIL_OUT("install() from $path recorded nothing") unless -s $log;
    my @calls = split /\n/, read_text($log);
    return (\@calls, $root);
}

#---
# payload: a payload tree complete except for which awk it carries. gawk carries its own name
# in the binary; mawk does not.
#---
sub payload {
    my (%opt) = @_;
    my $root = tempdir(DIR => $tmpdir, CLEANUP => 1);
    make_path("$root/usr/sbin", "$root/usr/bin");
    write_text("$root/usr/sbin/sshd",  "OpenSSH_8.0p1\n");
    write_text("$root/usr/bin/mktemp", "mktemp\n");
    if ($opt{awk} eq 'gawk') {
        write_text("$root/usr/bin/gawk", "GNU Awk 5.2.1\n");
    }
    else {
        write_text("$root/usr/bin/gawk", "mawk 1.3.4\n");
    }
    symlink('gawk', "$root/usr/bin/awk") or die "symlink: $!";
    return $root;
}

#---
# run_verifier: run verify-genesis-payload over a payload and return its status and stderr.
#---
sub run_verifier {
    my ($root) = @_;
    my $errfile = "$tmpdir/err.$$";
    system("/bin/bash '$verifier' '$root' >/dev/null 2>'$errfile'");
    my $status = $? >> 8;
    my $err = -f $errfile ? read_text($errfile) : '';
    unlink $errfile;
    return ($status, $err);
}
