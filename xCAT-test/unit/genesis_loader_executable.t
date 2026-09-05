#!/usr/bin/env perl
# Drive verify-genesis-payload against payloads whose ELF interpreter is not executable.
#
# The kernel execs the interpreter to start /init. A loader without the execute bit gives
# EACCES, and the node panics with "Failed to execute /init (error -13)".
use strict;
use warnings;

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use XCAT::Test::File qw(repo_path);

my $verifier = repo_path('xCAT-genesis-builder/verify-genesis-payload');
plan skip_all => 'verify-genesis-payload not found' unless -f $verifier;
plan tests => 8;

my $tmpdir = tempdir(CLEANUP => 1);
my $seq    = 0;

# A payload that passes every other rule, plus one ELF interpreter at $loader.
sub build_payload {
    my ($loader, $mode) = @_;
    my $root = "$tmpdir/payload" . $seq++;
    for my $path ('usr/sbin/sshd', 'usr/bin/mktemp', $loader) {
        my $full = "$root/$path";
        (my $dir = $full) =~ s{/[^/]+$}{};
        make_path($dir);
        open my $fh, '>', $full or die "$full: $!";
        print {$fh} "x";
        close $fh;
        chmod 0755, $full;
    }
    chmod $mode, "$root/$loader" or die "chmod $root/$loader: $!";
    return $root;
}

sub run {
    my ($root) = @_;
    my $err = "$tmpdir/err" . $seq;
    my $rc  = system("bash '$verifier' '$root' 2>'$err' >/dev/null");
    open my $fh, '<', $err or return ($rc >> 8, '');
    local $/;
    my $text = <$fh>;
    close $fh;
    return ($rc >> 8, $text);
}

my ($rc, $err) = run(build_payload('lib64/ld-linux-x86-64.so.2', 0755));
is($rc, 0, 'a payload whose loader is executable passes') or diag($err);

($rc, $err) = run(build_payload('lib64/ld-linux-x86-64.so.2', 0644));
isnt($rc, 0, 'a payload whose x86_64 loader is not executable fails');
like($err, qr{ld-linux-x86-64\.so\.2}, 'the loader is named');
like($err, qr/execut/i, 'the message says the loader must be executable');

# The alien-converted deb keeps the rpm layout, so the loader arrives under usr/lib64.
($rc, $err) = run(build_payload('usr/lib64/ld-linux-x86-64.so.2', 0644));
isnt($rc, 0, 'the rule reads the usr-merged path too');

# The native Ubuntu build puts the loader under the multiarch triplet.
($rc, $err) = run(build_payload('usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2', 0644));
isnt($rc, 0, 'the rule reads the Debian multiarch path too');

# ppc64le names its interpreter ld64.so.2.
($rc, $err) = run(build_payload('lib64/ld64.so.2', 0644));
isnt($rc, 0, 'a payload whose ppc64le loader is not executable fails');
like($err, qr{ld64\.so\.2}, 'the ppc64le loader is named');
