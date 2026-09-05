#!/usr/bin/env perl
# Drive getdestiny and nextdestiny with the command set the legacy Genesis image carries.
# That image has no mktemp, so a client that needs one asks xcatd for nothing and the node
# status never leaves the value rpower wrote.
use strict;
use warnings;

use File::Slurper qw(read_text write_text);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use XCAT::Test::File qw(repo_path);

my %script = (
    getdestiny  => repo_path('xCAT-genesis-scripts/usr/bin/getdestiny'),
    nextdestiny => repo_path('xCAT-genesis-scripts/usr/bin/nextdestiny'),
);
for my $name (sort keys %script) {
    plan skip_all => "$name not found" unless -f $script{$name};
}
plan tests => 12;

my $tmpdir = tempdir(CLEANUP => 1);

# The commands the legacy image ships. mktemp is deliberately absent from both lists.
my @image_tools = qw(cat chmod grep head mkdir mv rm sed sleep tr);

for my $name (sort keys %script) {
    for my $with_mktemp (0, 1) {
        my $label = $with_mktemp ? "$name with mktemp" : "$name without mktemp";
        my $marker = "$tmpdir/$name-$with_mktemp.request";
        my $bin = stub_dir($marker, $with_mktemp);
        my ($status, $out) = run_client($script{$name}, $bin);
        is($status, 0, "$label exits 0") or diag($out);
        like($out, qr/^shell$/m, "$label prints the destiny xcatd returned");
        ok(-f $marker, "$label sends the request to xcatd");
    }
}

#---
# stub_dir: a PATH directory holding only what the Genesis image carries. openssl records
# that it was called and answers with the response xcatd sends for a node set to shell.
#---
sub stub_dir {
    my ($marker, $with_mktemp) = @_;
    my $dir = tempdir(DIR => $tmpdir, CLEANUP => 1);
    for my $tool (@image_tools, $with_mktemp ? ('mktemp') : ()) {
        my $path = real_path($tool) or BAIL_OUT("no $tool on this host");
        write_stub($dir, $tool, "exec $path \"\$@\"\n");
    }
    write_stub($dir, 'openssl', <<"SH");
cat > /dev/null
echo request >> '$marker'
cat <<'XML'
<xcatresponse>
  <node>
    <data>shell</data>
    <destiny>shell</destiny>
    <name>node1</name>
  </node>
</xcatresponse>
<xcatresponse>
  <serverdone></serverdone>
</xcatresponse>
XML
SH
    return $dir;
}

sub real_path {
    my ($tool) = @_;
    for my $dir (qw(/bin /usr/bin /sbin /usr/sbin)) {
        return "$dir/$tool" if -x "$dir/$tool";
    }
    return;
}

sub write_stub {
    my ($dir, $name, $body) = @_;
    write_text("$dir/$name", "#!/bin/sh\n$body");
    chmod 0755, "$dir/$name";
    return;
}

#---
# run_client: run the client with only the stub directory on PATH. 192.0.2.1 is TEST-NET-1,
# so a stub that fails to shadow openssl cannot reach a real management node.
#---
sub run_client {
    my ($script, $bin) = @_;
    my $outfile = "$tmpdir/out.$$";
    my $cmd = sprintf("timeout -k 2 20 env -i PATH=%s /bin/bash %s 192.0.2.1:3001 >%s 2>&1 </dev/null",
        $bin, $script, $outfile);
    system($cmd);
    my $status = $? >> 8;
    my $out = -f $outfile ? read_text($outfile) : '';
    unlink $outfile;
    return ($status, $out);
}
