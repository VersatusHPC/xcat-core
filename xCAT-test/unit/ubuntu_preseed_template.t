#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use XCAT::Test::XcatRoot;    # before the first xCAT module

use Test::More;

my $tmpl_path = defined $ENV{XCATROOT} ? "$ENV{XCATROOT}/share/xcat/install/ubuntu/compute.tmpl" : '';
$tmpl_path = "xCAT-server/share/xcat/install/ubuntu/compute.tmpl"
    unless -f $tmpl_path;

plan skip_all => "compute.tmpl not found" unless -f $tmpl_path;

my $tmpl = do { local $/; open my $fh, '<', $tmpl_path or die $!; <$fh> };
my $template_pm_path = defined $ENV{XCATROOT} ? "$ENV{XCATROOT}/lib/perl/xCAT/Template.pm" : '';
$template_pm_path = "xCAT-server/lib/perl/xCAT/Template.pm"
    unless -f $template_pm_path;

like($tmpl, qr/^d-i apt-setup\/multiverse boolean false$/m, 'legacy Ubuntu preseed disables multiverse');
like($tmpl, qr/^d-i apt-setup\/universe boolean false$/m, 'legacy Ubuntu preseed disables universe');
like($tmpl, qr/^d-i apt-setup\/backports boolean false$/m, 'legacy Ubuntu preseed disables backports');
like($tmpl, qr/^d-i apt-setup\/updates boolean false$/m, 'legacy Ubuntu preseed disables release updates');
like($tmpl, qr/^d-i apt-setup\/services-select multiselect\s*$/m, 'legacy Ubuntu preseed disables security/update services for offline installs');
unlike($tmpl, qr/^d-i apt-setup\/services-select multiselect .*\S/m, 'legacy Ubuntu preseed does not select any external apt services');
like($tmpl, qr/sed -i .*security.*updates.*backports.*\/target\/etc\/apt\/sources\.list/s,
    'legacy Ubuntu late command comments disabled apt service suites in the installed target');

SKIP: {
    skip "Template.pm not found", 3 unless -f $template_pm_path;
    my $template_pm = do { local $/; open my $fh, '<', $template_pm_path or die $!; <$fh> };

    like($template_pm, qr/\$ENV\{HTTPPORT\} \|\| \$ENV\{httpport\} \|\| '80'/,
        'legacy Ubuntu mirror spec uses the rendered HTTP port for local mirrors');
    like($template_pm, qr/d-i apt-setup\/security_host string \$security_host/,
        'legacy Ubuntu mirror spec redirects installer security host to rendered xCAT master');
    like($template_pm, qr/d-i apt-setup\/security_path string \$pkgdir/,
        'legacy Ubuntu mirror spec redirects installer security path to the local pkgdir');
}

done_testing();
