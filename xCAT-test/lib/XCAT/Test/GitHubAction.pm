package XCAT::Test::GitHubAction;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(package_install_command should_check_syntax);

sub package_install_command {
    my ($package) = @_;
    return join ' ',
      'sudo timeout 1200 env DEBIAN_FRONTEND=noninteractive',
      'apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30',
      'install -y', $package,
      '--allow-remove-essential --allow-unauthenticated';
}

sub should_check_syntax {
    my ($file) = @_;
    return 0 if $file =~ m{/opt/xcat/share/xcat/netboot/genesis/};
    return 0 if $file =~ m{/opt/xcat/probe/};
    return 0 if $file =~ m{/opt/xcat/share/xcat/tools/autotest/unit/};
    return 1;
}

1;
