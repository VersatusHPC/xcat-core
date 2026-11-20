#!/usr/bin/perl
# EPL license http://www.eclipse.org/legal/epl-v10.html

package xCAT::OpenHPCUtils;

use strict;
use warnings;

# The decisions behind mkopenhpc: which nodes it supports, where the
# repository and the munge key go, and the text of slurm.conf and of the
# repository file. The subs take their inputs as arguments, so a unit test
# can load this module from the source tree without an xCAT installation.

# The key is a secret. It stays out of the install directory, which the
# HTTP server publishes.
our $MUNGE_KEY = '/etc/xcat/ohpc/munge.key';

our $SLURMCTLD_PORT  = 6817;
our $SLURMD_PORT     = 6818;
our $SRUN_PORT_RANGE = '60001-60100';

#-------------------------------------------------------------------------------

=head3 node_os_supported

    Descriptions:
        mkopenhpc supports OpenHPC 3 on EL 9 x86_64 nodes.
    Arguments:
        $os   - the node os attribute, such as alma9.8 or rhels9.4
        $arch - the node arch attribute
    Returns:
        1 when supported, else 0

=cut

#-------------------------------------------------------------------------------
sub node_os_supported
{
    my ($os, $arch) = @_;
    return 0 unless defined $os && defined $arch && $arch eq 'x86_64';
    return ($os =~ /^(?:rhels|rhel|alma|rocky|ol|centos-stream|centos)9(?:\.\d+)?$/) ? 1 : 0;
}

#-------------------------------------------------------------------------------

=head3 repo_major

    Descriptions:
        Reads the OpenHPC major release from a repository path such as
        .../OpenHPC/3/EL_9 or .../openhpc/3/EL_9.
    Arguments:
        $path - the repository directory
    Returns:
        the major release, or 3 when the path does not name one

=cut

#-------------------------------------------------------------------------------
sub repo_major
{
    my ($path) = @_;
    return $1 if defined $path && $path =~ m{/(\d+)/EL_\d+/*\z};
    return 3;
}

#-------------------------------------------------------------------------------

=head3 repo_publish_path

    Arguments:
        $installdir, $major, $arch
    Returns:
        the directory under the install directory that serves the repository

=cut

#-------------------------------------------------------------------------------
sub repo_publish_path
{
    my ($installdir, $major, $arch) = @_;
    return "$installdir/ohpc/$major/$arch";
}

#-------------------------------------------------------------------------------

=head3 render_repo_file

    Descriptions:
        Renders the yum repository file for the OpenHPC repository.
    Arguments:
        $baseurl - the URL of the repository
    Returns:
        the file text

=cut

#-------------------------------------------------------------------------------
sub render_repo_file
{
    my ($baseurl) = @_;

    # mkopenhpc copies the mirror and does not sign it. The packages carry
    # the OpenHPC signature, but the key is not on the node.
    return join("\n",
        '[xcat-ohpc]',
        'name=OpenHPC (xCAT mkopenhpc)',
        "baseurl=$baseurl",
        'enabled=1',
        'gpgcheck=0',
        '') . "\n";
}

#-------------------------------------------------------------------------------

=head3 render_slurm_conf

    Descriptions:
        Renders a minimal slurm.conf: slurmctld on the management node, one
        partition, munge authentication.
    Arguments:
        a hash with
          cluster   - the Slurm cluster name
          ctl_host  - the short host name of the management node
          ctl_addr  - the address the nodes use to reach slurmctld
          nodes     - array ref of node names
          partition - the partition name
    Returns:
        the file text

=cut

#-------------------------------------------------------------------------------
sub render_slurm_conf
{
    my (%a) = @_;
    my @nodes = sort @{ $a{nodes} };
    my $nodelist = join(',', @nodes);
    my @lines = (
        '# Written by xCAT mkopenhpc.',
        "ClusterName=$a{cluster}",
        "SlurmctldHost=$a{ctl_host}($a{ctl_addr})",
        "SlurmctldPort=$SLURMCTLD_PORT",
        "SlurmdPort=$SLURMD_PORT",
        "SrunPortRange=$SRUN_PORT_RANGE",
        'AuthType=auth/munge',
        'SlurmUser=slurm',
        'StateSaveLocation=/var/spool/slurmctld',
        'SlurmdSpoolDir=/var/spool/slurmd',
        'ProctrackType=proctrack/linuxproc',
        'TaskPlugin=task/none',
        'MpiDefault=none',
        'SchedulerType=sched/backfill',
        'SelectType=select/cons_tres',
        'ReturnToService=2',
        'SlurmctldLogFile=/var/log/slurmctld.log',
        'SlurmdLogFile=/var/log/slurmd.log',
        (map { "NodeName=$_ State=UNKNOWN" } @nodes),
        "PartitionName=$a{partition} Nodes=$nodelist Default=YES MaxTime=INFINITE State=UP",
    );
    return join("\n", @lines) . "\n";
}

#-------------------------------------------------------------------------------

=head3 firewall_ports

    Arguments:
        $role - 'mn' for the management node, 'node' for a compute node
    Returns:
        the firewalld ports to open, in the form port/tcp or low-high/tcp

=cut

#-------------------------------------------------------------------------------
sub firewall_ports
{
    my ($role) = @_;
    return ("$SLURMCTLD_PORT/tcp", "$SRUN_PORT_RANGE/tcp") if $role eq 'mn';
    return ("$SLURMD_PORT/tcp");
}

1;
