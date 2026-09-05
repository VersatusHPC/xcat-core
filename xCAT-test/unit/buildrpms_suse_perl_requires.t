#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use Test::More;

my $buildrpms = "$FindBin::Bin/../../buildrpms.pl";
plan skip_all => 'buildrpms.pl not found' unless -r $buildrpms;

open(my $fh, '<', $buildrpms) or die "Cannot read buildrpms.pl: $!";
my $source = do { local $/; <$fh> };
close($fh);

my ($sub) = $source =~ /^(sub \s+ createmockconfig \s* \{ .*? ^\})/msx;
BAIL_OUT('createmockconfig no longer matches the extraction pattern') unless $sub;

# createmockconfig copies a mock target config and appends to it. The stubs below
# keep every path in memory, so the test never reads or writes /etc/mock.
{
    package MockCfg;
    use strict;
    use warnings;
    our %opts              = (force => 1);
    our $SOURCE_DATE_EPOCH = '0';
    our %FS;

    sub cp         { my ($src, $dst) = @_; $FS{$dst} = $FS{$src}; return 1; }
    sub read_text  { my ($path) = @_; return $FS{$path}; }
    sub write_text { my ($path, $text) = @_; $FS{$path} = $text; return 1; }
}

{
    my $ok = eval "package MockCfg; our %opts; our \$SOURCE_DATE_EPOCH; $sub; 1";
    BAIL_OUT("createmockconfig does not compile in the scratch package: $@") unless $ok;
}

#-----------------------------------------------------------------------------

=head3 mock_config_for

    Descriptions: Run createmockconfig for one package and target.
    Arguments:
        $pkg     - the package name
        $target  - the mock target name
    Returns: the text of the mock config createmockconfig wrote

=cut

#-----------------------------------------------------------------------------
sub mock_config_for {
    my ($pkg, $target) = @_;
    %MockCfg::FS = ("/etc/mock/$target.cfg" => "config_opts['root'] = '$target'\n");
    MockCfg::createmockconfig($pkg, $target);
    return $MockCfg::FS{"/etc/mock/$pkg-$target.cfg"};
}

my $leap = mock_config_for('perl-xCAT', 'opensuse-leap-15.6-x86_64');
my $el   = mock_config_for('perl-xCAT', 'alma+epel-10-x86_64');

# openSUSE ships perllib.attr with %__perllib_requires commented out, so rpmbuild
# records no perl(JSON) requirement for perl-xCAT and xCAT installs without it.
like($leap, qr/__perllib_requires/,
    'perl-xCAT on a Leap target turns on the rpm perl requires generator');
like($leap, qr{/usr/lib/rpm/perl\.req},
    'perl-xCAT on a Leap target points the generator at perl.req');
unlike($leap, qr/perl-generators/,
    'perl-xCAT on a Leap target does not ask for the RHEL-only perl-generators');

like($el, qr/perl-generators/,
    'perl-xCAT on an EL target keeps perl-generators');
unlike($el, qr{/usr/lib/rpm/perl\.req},
    'perl-xCAT on an EL target does not override the rpm perl requires generator');

done_testing();
