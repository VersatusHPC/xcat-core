# EPL license http://www.eclipse.org/legal/epl-v10.html
#-------------------------------------------------------

=head1
  xCAT plugin package to handle mkopenhpc

   Supported command:
         mkopenhpc

=cut

#-------------------------------------------------------
package xCAT_plugin::mkopenhpc;

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long;
use MIME::Base64 qw(encode_base64);

require xCAT::Table;
require xCAT::Utils;
require xCAT::TableUtils;
require xCAT::MsgUtils;
require xCAT::ServiceNodeUtils;
require xCAT::NetworkUtils;
require xCAT::OpenHPCUtils;
use xCAT::NodeRange;

my $USAGE = "Usage: mkopenhpc -r <repository directory> [-p <partition>] <noderange>\n       mkopenhpc [-h|--help]";

#-------------------------------------------------------

=head3  handled_commands

    Return the list of commands handled by this plugin

=cut

#-------------------------------------------------------
sub handled_commands
{
    return { mkopenhpc => 'mkopenhpc' };
}

sub error
{
    my ($callback, $msg) = @_;
    xCAT::MsgUtils->message('E', { data => [$msg] }, $callback, 1);
    return 1;
}

sub info
{
    my ($callback, $msg) = @_;
    $callback->({ data => [$msg] });
}

# Run a command on the management node. Returns 1 on success.
sub run_local
{
    my ($callback, $cmd) = @_;
    my $out = xCAT::Utils->runcmd($cmd, -1);
    return 1 if $::RUNCMD_RC == 0;
    error($callback, "'$cmd' failed: " . (defined $out ? $out : ''));
    return 0;
}

sub write_file
{
    my ($path, $mode, $text) = @_;
    make_path(dirname($path));
    open(my $fh, '>', "$path.new") or return 0;
    chmod($mode, "$path.new");
    print $fh $text;
    close($fh) or return 0;
    return rename("$path.new", $path);
}

sub run_subcommand
{
    my ($callback, $subreq, $cmd, $nodes, @arg) = @_;
    my $out = xCAT::Utils->runxcmd({ command => [$cmd], node => $nodes, arg => \@arg },
        $subreq, -1, 1);
    if ($::RUNCMD_RC || $::VERBOSE) {
        info($callback, join("\n", "$cmd " . join(' ', @arg) . ':', @{ $out || [] }));
    }
    return $::RUNCMD_RC;
}

#-------------------------------------------------------

=head3  process_request

    Sets up the OpenHPC repository, munge and slurmctld on the management
    node, and adds confignodeslurm to the nodes, which makes them Slurm
    compute nodes at their next install or updatenode -P.

=cut

#-------------------------------------------------------
sub process_request
{
    my ($request, $callback, $subreq) = @_;
    my ($help, $repo, $verbose);
    my $partition = 'compute';
    # The client is xcatclientnnr, so the noderange arrives among the arguments.
    local @ARGV = $request->{arg} ? @{ $request->{arg} } : ();
    Getopt::Long::Configure('bundling', 'no_pass_through');
    if (!GetOptions('h|help' => \$help, 'r|repo=s' => \$repo, 'p|partition=s' => \$partition,
            'V|verbose' => \$verbose) || @ARGV > 1) {
        return error($callback, $USAGE);
    }
    if ($help) {
        info($callback, $USAGE);
        return 0;
    }
    $::VERBOSE = $verbose;
    my @nodes = $request->{node} ? @{ $request->{node} } : ();
    @nodes = xCAT::NodeRange::noderange($ARGV[0]) if @ARGV;
    return error($callback, "The noderange is missing.\n$USAGE") unless @nodes;
    return error($callback, "The repository directory is missing.\n$USAGE") unless $repo;
    return error($callback, "$repo is not a repository directory.") unless -d "$repo/repodata";
    return error($callback, "Bad partition name '$partition'.") unless $partition =~ /^[\w.-]+$/;
    return error($callback, 'mkopenhpc runs on an EL management node.') unless -f '/etc/redhat-release';

    my $typetab = xCAT::Table->new('nodetype');
    my $types = $typetab ? $typetab->getNodesAttribs(\@nodes, [ 'os', 'arch' ]) : {};
    my @bad = grep {
        my $t = $types->{$_} ? $types->{$_}->[0] : {};
        !xCAT::OpenHPCUtils::node_os_supported($t->{os}, $t->{arch})
    } @nodes;
    return error($callback, 'mkopenhpc supports EL 9 x86_64 nodes only: ' . join(',', @bad)) if @bad;

    my $installdir = xCAT::TableUtils->getInstallDir() || '/install';
    my $major      = xCAT::OpenHPCUtils::repo_major($repo);
    my $published  = xCAT::OpenHPCUtils::repo_publish_path($installdir, $major, 'x86_64');
    my $postdir    = "$installdir/postscripts/ohpc";

    # 1. Publish the repository under the install directory.
    make_path($published);
    run_local($callback, "rsync -a --delete '$repo/' '$published/'") or return 1;

    # 2. The management node runs slurmctld.
    write_file('/etc/yum.repos.d/xcat-ohpc.repo', 0644,
        xCAT::OpenHPCUtils::render_repo_file("file://$published")) or return error($callback, "Cannot write the repository file: $!");
    run_local($callback, 'dnf install -y ohpc-slurm-server munge 2>&1') or return 1;

    my $key = $xCAT::OpenHPCUtils::MUNGE_KEY;
    unless (-s $key) {
        open(my $rnd, '<:raw', '/dev/urandom') or return error($callback, "Cannot read /dev/urandom: $!");
        my $bytes = '';
        read($rnd, $bytes, 1024) == 1024 or return error($callback, 'Short read from /dev/urandom.');
        close($rnd);

        # Base64, because xcatd sends a credential as XML text. munge hashes the file.
        write_file($key, 0600, encode_base64($bytes)) or return error($callback, "Cannot write $key: $!");
    }
    run_local($callback, "install -o munge -g munge -m 0400 '$key' /etc/munge/munge.key") or return 1;

    my @master = xCAT::TableUtils->get_site_attribute('master');
    my $ctl_host = (xCAT::NetworkUtils->determinehostname())[-1];
    $ctl_host =~ s/\..*//;
    my $conf = xCAT::OpenHPCUtils::render_slurm_conf(
        cluster   => 'xcat',
        ctl_host  => $ctl_host,
        ctl_addr  => $master[0],
        nodes     => \@nodes,
        partition => $partition,
    );
    write_file('/etc/slurm/slurm.conf', 0644, $conf) or return error($callback, "Cannot write /etc/slurm/slurm.conf: $!");
    write_file("$postdir/slurm.conf", 0644, $conf) or return error($callback, "Cannot write $postdir/slurm.conf: $!");
    run_local($callback, 'install -d -o slurm -g slurm -m 0755 /var/spool/slurmctld') or return 1;

    if (system('systemctl is-active --quiet firewalld') == 0) {
        foreach my $port (xCAT::OpenHPCUtils::firewall_ports('mn')) {
            run_local($callback, "firewall-cmd --permanent --add-port=$port") or return 1;
        }
        run_local($callback, 'firewall-cmd --reload') or return 1;
    }
    run_local($callback, 'systemctl enable munge slurmctld 2>&1') or return 1;
    run_local($callback, 'systemctl restart munge 2>&1') or return 1;
    run_local($callback, 'systemctl restart slurmctld 2>&1') or return 1;

    # 3. A node behind a service node reads the repository, slurm.conf and the
    #    key from that service node.
    my @installloc = xCAT::TableUtils->get_site_attribute('installloc');
    my $sns = xCAT::ServiceNodeUtils->get_ServiceNode(\@nodes, 'xcat', 'MN');
    my %self = map { $_ => 1 } xCAT::NetworkUtils->determinehostname();
    my @sns = grep { !$self{$_} } sort keys %{ ref($sns) eq 'HASH' ? $sns : {} };
    if (@sns) {
        my $keydir = dirname($key);
        run_subcommand($callback, $subreq, 'xdsh', \@sns, "mkdir -p -m 0700 $keydir && mkdir -p " . dirname($published))
          and return error($callback, 'Cannot prepare the service nodes.');
        run_subcommand($callback, $subreq, 'xdcp', \@sns, $key, $keydir)
          and return error($callback, 'Cannot copy the munge key to the service nodes.');
        unless ($installloc[0]) {
            run_subcommand($callback, $subreq, 'xdcp', \@sns, '-R', $published, dirname($published))
              and return error($callback, 'Cannot copy the repository to the service nodes.');
            run_subcommand($callback, $subreq, 'xdcp', \@sns, '-R', $postdir, "$installdir/postscripts")
              and return error($callback, 'Cannot copy slurm.conf to the service nodes.');
        }
    }

    # 4. The nodes run confignodeslurm at their next install or updatenode -P.
    my $pstab = xCAT::Table->new('postscripts', -create => 1);
    return error($callback, 'Cannot open the postscripts table.') unless $pstab;
    my $current = $pstab->getNodesAttribs(\@nodes, ['postbootscripts']);
    my %set;
    foreach my $node (@nodes) {
        my $value = $current->{$node} ? $current->{$node}->[0]->{postbootscripts} : '';
        my @scripts = grep { length && $_ ne 'confignodeslurm' } split(/\s*,\s*/, defined $value ? $value : '');
        $set{$node} = { postbootscripts => join(',', @scripts, 'confignodeslurm') };
    }
    $pstab->setNodesAttribs(\%set);
    $pstab->close();

    info($callback, "slurmctld runs on $ctl_host. The nodes run confignodeslurm at their next install, "
          . "or now with: updatenode <noderange> -P confignodeslurm");
    return 0;
}

1;
