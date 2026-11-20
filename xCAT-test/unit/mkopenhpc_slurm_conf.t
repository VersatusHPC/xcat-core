#!/usr/bin/env perl
# mkopenhpc renders slurm.conf and the OpenHPC repository file, and decides
# where the repository and the munge key go. xCAT::OpenHPCUtils holds those
# decisions.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More;

require xCAT::OpenHPCUtils;

my $conf = xCAT::OpenHPCUtils::render_slurm_conf(
    cluster   => 'xcat',
    ctl_host  => 'mn1',
    ctl_addr  => '10.0.0.1',
    nodes     => [qw(cn2 cn1)],
    partition => 'compute',
);
my %line = map { /^(\w+)=(.*)$/ ? ($1 => $2) : () } split(/\n/, $conf);

is($line{SlurmctldHost}, 'mn1(10.0.0.1)', 'SlurmctldHost carries the address the nodes use');
is($line{AuthType},      'auth/munge',    'munge authentication');
is($line{SrunPortRange}, '60001-60100',   'a fixed srun port range the firewall can open');
is($line{ProctrackType}, 'proctrack/linuxproc', 'no cgroup plugin');
like($conf, qr/^NodeName=cn1 State=UNKNOWN$/m, 'one NodeName line for cn1');
like($conf, qr/^NodeName=cn2 State=UNKNOWN$/m, 'one NodeName line for cn2');
like($conf, qr/^PartitionName=compute Nodes=cn1,cn2 Default=YES MaxTime=INFINITE State=UP$/m,
    'one default partition with every node');

my $repo = xCAT::OpenHPCUtils::render_repo_file('http://10.0.0.21/install/ohpc/3/x86_64');
like($repo, qr/^baseurl=http:\/\/10\.0\.0\.21\/install\/ohpc\/3\/x86_64$/m, 'repo baseurl');
like($repo, qr/^enabled=1$/m, 'repo enabled');

is(xCAT::OpenHPCUtils::repo_major('/opt/xcat-ci-shared/isos/openhpc/3/EL_9'), 3, 'major from a mirror path');
is(xCAT::OpenHPCUtils::repo_major('/srv/OpenHPC/4/EL_10/'), 4, 'major from an OpenHPC tree');
is(xCAT::OpenHPCUtils::repo_publish_path('/install', 3, 'x86_64'), '/install/ohpc/3/x86_64',
    'the repository is published under the install directory');

unlike($xCAT::OpenHPCUtils::MUNGE_KEY, qr{^/install/}, 'the munge key is not under /install');
unlike($xCAT::OpenHPCUtils::MUNGE_KEY, qr{^/tftpboot/}, 'the munge key is not under /tftpboot');

ok(xCAT::OpenHPCUtils::node_os_supported('alma9.8', 'x86_64'),  'alma9.8 x86_64 is supported');
ok(xCAT::OpenHPCUtils::node_os_supported('rhels9.4', 'x86_64'), 'rhels9.4 x86_64 is supported');
ok(!xCAT::OpenHPCUtils::node_os_supported('alma10.0', 'x86_64'), 'EL 10 is not supported');
ok(!xCAT::OpenHPCUtils::node_os_supported('rhels8.10', 'x86_64'), 'EL 8 is not supported');
ok(!xCAT::OpenHPCUtils::node_os_supported('ubuntu24.04', 'x86_64'), 'Ubuntu is not supported');
ok(!xCAT::OpenHPCUtils::node_os_supported('alma9.8', 'ppc64le'), 'ppc64le is not supported');

is_deeply([ xCAT::OpenHPCUtils::firewall_ports('mn') ], [ '6817/tcp', '60001-60100/tcp' ],
    'the MN opens slurmctld and the srun range');
is_deeply([ xCAT::OpenHPCUtils::firewall_ports('node') ], ['6818/tcp'], 'a node opens slurmd');

done_testing();
