#!/usr/bin/perl
# openSUSE Leap installs the Apache 2.4 server as /usr/sbin/httpd, reads its configuration from
# /etc/apache2/conf.d, and ships neither apachectl nor apache2ctl. xCAT-server's %post pairs each
# probe binary with one configuration directory: the httpd probe writes only /etc/httpd/conf.d,
# and the two probes that write /etc/apache2/conf.d never run there. The 2.2 file stays in place,
# apache2 refuses to start on "Invalid command 'Order'", and the compute node cannot fetch its
# xNBA boot script over HTTP -- it falls through to "No bootable device".
#
# This drives the real %post block: the scriptlet is extracted from the spec, its absolute paths
# are moved under a scratch root, and it runs with a PATH that holds a SUSE-shaped httpd and
# nothing else.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);

my $spec = dirname(__FILE__) . '/../../xCAT-server/xCAT-server.spec';
open my $fh, '<', $spec or die "cannot read $spec: $!\n";
my $text = do { local $/; <$fh> };
close $fh;

my ($block) = $text =~ /^(#Apply the correct httpd\/apache configuration file.*?)^exit 0$/ms
    or die "the %post apache-configuration block is no longer in $spec\n";

my $root = tempdir(CLEANUP => 1);

# The scriptlet writes to absolute paths and takes no prefix. Move them under the scratch root,
# and resolve the one rpm macro it uses. Both substitutions must match, or the test measures the
# host filesystem instead.
my $n = ($block =~ s{/etc/}{$root/etc/}g);
die "no /etc/ paths in the extracted block\n" unless $n >= 4;
$block =~ s/\%httpconfigdir/xcat/g;
die "\%httpconfigdir survived the substitution\n" if $block =~ /\%httpconfigdir/;

# The packaged inputs: both variants under conf.orig, and the 2.2 file already in each conf.d
# (that is what the package %files installs before %post runs).
make_path("$root/etc/xcat/conf.orig", "$root/etc/httpd/conf.d", "$root/etc/apache2/conf.d");
my %want = (
    "$root/etc/xcat/conf.orig/xcat-ws.conf.apache22" => "<FilesMatch x>\n    Order allow,deny\n    Allow from all\n</FilesMatch>\n",
    "$root/etc/xcat/conf.orig/xcat-ws.conf.apache24" => "<FilesMatch x>\nRequire all granted\n</FilesMatch>\n",
);
for my $f (sort keys %want) { open my $o, '>', $f or die "$f: $!"; print $o $want{$f}; close $o }
for my $d ("$root/etc/httpd/conf.d", "$root/etc/apache2/conf.d") {
    open my $o, '>', "$d/xcat-ws.conf" or die "$!";
    print $o $want{"$root/etc/xcat/conf.orig/xcat-ws.conf.apache22"};
    close $o;
}

# A PATH with only what the scriptlet needs, so apachectl and apache2ctl are absent whatever this
# host has installed, and httpd answers the way openSUSE Leap 15.6 does.
my $bin = "$root/bin";
make_path($bin);
open my $h, '>', "$bin/httpd" or die "$!";
print $h "#!/bin/sh\necho 'Server version: Apache/2.4.66 (Linux/SUSE)'\necho 'Server built:   2026-03-22 12:40:42.000000000 +0000'\n";
close $h;
chmod 0755, "$bin/httpd";
for my $t (qw(sh grep sed cp rm cat head ls)) {
    for my $d (qw(/usr/bin /bin /usr/sbin)) { next unless -x "$d/$t"; symlink "$d/$t", "$bin/$t"; last }
}

open my $s, '>', "$root/post.sh" or die "$!";
print $s "#!/bin/sh\n$block\nexit 0\n";
close $s;
chmod 0755, "$root/post.sh";

my $rc = system("PATH=$bin $bin/sh $root/post.sh >$root/post.out 2>&1");
is($rc, 0, 'the %post apache block runs clean with a SUSE-shaped httpd');

sub slurp { my ($p) = @_; open my $i, '<', $p or return ''; local $/; return <$i> }

my $a24 = $want{"$root/etc/xcat/conf.orig/xcat-ws.conf.apache24"};
is(slurp("$root/etc/apache2/conf.d/xcat-ws.conf"), $a24,
   'the SUSE configuration directory gets the Apache 2.4 file')
    or diag("it still holds:\n" . slurp("$root/etc/apache2/conf.d/xcat-ws.conf"));
is(slurp("$root/etc/httpd/conf.d/xcat-ws.conf"), $a24,
   'the EL configuration directory gets the Apache 2.4 file');

unlike(slurp("$root/etc/apache2/conf.d/xcat-ws.conf"), qr/^\s*Order\s+allow,deny/m,
   'no Apache 2.2 access directive is left where apache2 reads it');

done_testing();
