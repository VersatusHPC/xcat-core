#!/usr/bin/perl
# mock accepts --additional-package only with --rebuild. On --init or
# --buildsrpm it stops with "The --additional-package option requires the
# --rebuild mode", rc=5, and the core build fails.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../build-utils/lib";
use Test::More;
use XCAT::BuildUtils;

my $t = 'alma+epel-10-x86_64';
is_deeply([ XCAT::BuildUtils::mock_package_opts('init', 'perl-xCAT', $t) ], [],
    'init carries no --additional-package');
is_deeply([ XCAT::BuildUtils::mock_package_opts('buildsrpm', 'perl-xCAT', $t) ], [],
    'buildsrpm carries no --additional-package');
is_deeply([ XCAT::BuildUtils::mock_package_opts('rebuild', 'perl-xCAT', $t) ],
    ['--additional-package=perl-generators'],
    'rebuild installs perl-generators for perl-xCAT');
is_deeply([ XCAT::BuildUtils::mock_package_opts('rebuild', 'xCAT', $t) ], [],
    'rebuild of another package installs nothing extra');
done_testing;
