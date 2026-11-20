# EPL license http://www.eclipse.org/legal/epl-v10.html
#-------------------------------------------------------

=head1
  xCAT plugin package to handle mkhostbased-auth

   Supported command:
         mkhostbased-auth

=cut

#-------------------------------------------------------
package xCAT_plugin::mkhostbased_auth;

use strict;
use warnings;
use File::Path qw(make_path remove_tree);
use Getopt::Long;

require xCAT::Table;
require xCAT::Utils;
require xCAT::TableUtils;
require xCAT::NetworkUtils;
require xCAT::MsgUtils;
require xCAT::ServiceNodeUtils;
require xCAT::HostbasedAuthUtils;

my $HOSTKEYDIR = '/etc/xcat/hostkeys';

#-------------------------------------------------------

=head3  handled_commands

    Return the list of commands handled by this plugin

=cut

#-------------------------------------------------------
sub handled_commands
{
    return { 'mkhostbased-auth' => 'mkhostbased_auth' };
}

my $USAGE = "Usage: mkhostbased-auth <noderange> [-r] [-V]\n       mkhostbased-auth [-h|--help]";

#-------------------------------------------------------

=head3  process_request

    Renders ssh_known_hosts and shosts.equiv for each trust scope of the
    noderange, publishes them under <installdir>/postscripts/hostbased/,
    and runs confighostbasedauth on the nodes.
    Arguments:
        $request, $callback, $subreq
    Returns:
        0 on success, 1 on a failure

=cut

#-------------------------------------------------------
sub process_request
{
    my ($request, $callback, $subreq) = @_;
    my @args = $request->{arg} ? @{ $request->{arg} } : ();
    my ($help, $remove, $verbose);
    Getopt::Long::Configure('bundling', 'no_pass_through');
    local @ARGV = @args;
    if (!GetOptions('h|help' => \$help, 'r|remove' => \$remove, 'V|verbose' => \$verbose) || @ARGV) {
        return error($callback, $USAGE);
    }
    if ($help) {
        $callback->({ data => [$USAGE] });
        return 0;
    }
    my @nodes = $request->{node} ? @{ $request->{node} } : ();
    return error($callback, "The noderange is missing.\n$USAGE") unless @nodes;
    $::VERBOSE = $verbose;

    return remove_auth($callback, $subreq, \@nodes) if $remove;
    return make_auth($callback, $subreq, \@nodes);
}

sub error
{
    my ($callback, $msg) = @_;
    xCAT::MsgUtils->message('E', { data => [$msg] }, $callback, 1);
    return 1;
}

sub publish_dir
{
    my $installdir = xCAT::TableUtils->getInstallDir() || '/install';
    return "$installdir/postscripts/hostbased";
}

#-------------------------------------------------------

=head3  read_host_keys

    Reads the public host keys of a node: /etc/xcat/hostkeys/<node>/ when it
    exists, else /etc/xcat/hostkeys/, as remoteshell installs them.
    Arguments:
        $node, the array ref of key types to read
    Returns:
        a hash ref, key type => contents of the .pub file

=cut

#-------------------------------------------------------
sub read_host_keys
{
    my ($node, $types) = @_;
    my $dir = -d "$HOSTKEYDIR/$node" ? "$HOSTKEYDIR/$node" : $HOSTKEYDIR;
    my %keys;
    foreach my $type (@$types) {
        my $file = "$dir/ssh_host_${type}_key.pub";
        next unless -r $file;
        open(my $fh, '<', $file) or next;
        local $/;
        $keys{$type} = <$fh>;
        close($fh);
    }
    return \%keys;
}

sub write_file
{
    my ($path, @lines) = @_;
    open(my $fh, '>', "$path.new") or return 0;
    print $fh map { "$_\n" } @lines;
    close($fh) or return 0;
    chmod(0644, "$path.new");
    return rename("$path.new", $path);
}

#-------------------------------------------------------

=head3  service_nodes_to_sync

    Lists the service nodes that serve the nodes, unless site.installloc
    says the service nodes mount the install directory from the management
    node.

=cut

#-------------------------------------------------------
sub service_nodes_to_sync
{
    my ($nodes) = @_;
    my @installloc = xCAT::TableUtils->get_site_attribute('installloc');
    return () if ($installloc[0]);
    my $sns = xCAT::ServiceNodeUtils->get_ServiceNode($nodes, 'xcat', 'MN');
    return () unless ref($sns) eq 'HASH';
    my @mn = xCAT::NetworkUtils->determinehostname();
    my %self = map { $_ => 1 } @mn;
    return grep { !$self{$_} } sort keys %$sns;
}

sub run_subcommand
{
    my ($callback, $subreq, $cmd, $nodes, @arg) = @_;
    my $out = xCAT::Utils->runxcmd({ command => [$cmd], node => $nodes, arg => \@arg },
        $subreq, -1, 1);
    my $rc = $::RUNCMD_RC;
    if ($rc || $::VERBOSE) {
        $callback->({ data => [ "$cmd " . join(' ', @arg) . ':', @{ $out || [] } ] });
    }
    return $rc;
}

sub set_postbootscripts
{
    my ($nodes, $scope_of) = @_;
    my $tab = xCAT::Table->new('postscripts', -create => 1);
    return 0 unless $tab;
    my $current = $tab->getNodesAttribs($nodes, ['postbootscripts']);
    my %set;
    foreach my $node (@$nodes) {
        my $value = $current->{$node} ? $current->{$node}->[0]->{postbootscripts} : undef;
        $set{$node} = { postbootscripts =>
              xCAT::HostbasedAuthUtils::postbootscripts_with($value, $scope_of->{$node}) };
    }
    $tab->setNodesAttribs(\%set);
    $tab->close();
    return 1;
}

sub make_auth
{
    my ($callback, $subreq, $nodes) = @_;

    my $fips  = xCAT::Utils->isFIPS();
    my @types = xCAT::HostbasedAuthUtils::allowed_key_types($fips);

    my $nltab = xCAT::Table->new('nodelist');
    my $zones = $nltab ? $nltab->getNodesAttribs($nodes, ['zonename']) : {};
    my %zone_of = map { $_ => ($zones->{$_} ? $zones->{$_}->[0]->{zonename} : undef) } @$nodes;
    my %sbn;
    my $zonetab = xCAT::Table->new('zone');
    if ($zonetab) {
        foreach my $row ($zonetab->getAllAttribs('zonename', 'sshbetweennodes')) {
            $sbn{ $row->{zonename} } = $row->{sshbetweennodes};
        }
        $zonetab->close();
    }
    my ($scopes, $left_out) = xCAT::HostbasedAuthUtils::scope_sets($nodes, \%zone_of, \%sbn);
    if (@$left_out) {
        $callback->({ data => [ "Skipped, the zone has sshbetweennodes=no: " . join(',', @$left_out) ] });
    }
    return error($callback, 'No node is left to configure.') unless %$scopes;

    my @domain = xCAT::TableUtils->get_site_attribute('domain');
    my $publish = publish_dir();
    my %scope_of;
    foreach my $scope (sort keys %$scopes) {
        my @hosts;
        foreach my $node (@{ $scopes->{$scope} }) {
            my @ips = xCAT::NetworkUtils->getipaddr($node, GetAllAddresses => 1);
            my $keys = read_host_keys($node, \@types);
            return error($callback, "No host public key for $node in $HOSTKEYDIR.") unless %$keys;
            push @hosts, { names => [ xCAT::HostbasedAuthUtils::host_entries($node, $domain[0], @ips) ],
                keys => $keys };
            $scope_of{$node} = $scope;
        }
        my $dir = "$publish/$scope";
        make_path($dir);
        write_file("$dir/ssh_known_hosts", xCAT::HostbasedAuthUtils::known_hosts_lines(\@hosts, \@types))
          or return error($callback, "Cannot write $dir/ssh_known_hosts: $!");
        write_file("$dir/shosts.equiv", xCAT::HostbasedAuthUtils::shosts_equiv_lines(\@hosts))
          or return error($callback, "Cannot write $dir/shosts.equiv: $!");
    }
    my @configured = sort keys %scope_of;

    # A reinstalled node runs confighostbasedauth again from postbootscripts.
    set_postbootscripts(\@configured, \%scope_of)
      or return error($callback, 'Cannot update the postscripts table.');

    my @sns = service_nodes_to_sync(\@configured);
    if (@sns) {
        my $dest = $publish =~ s{/hostbased$}{}r;
        run_subcommand($callback, $subreq, 'xdcp', \@sns, '-R', $publish, $dest)
          and return error($callback, 'Cannot copy the files to the service nodes.');
    }

    my $rc = 0;
    foreach my $scope (sort keys %$scopes) {
        $rc |= run_subcommand($callback, $subreq, 'updatenode', $scopes->{$scope},
            '-P', "confighostbasedauth $scope");
    }
    return error($callback, 'confighostbasedauth failed on one or more nodes.') if $rc;
    $callback->({ data => [ 'Host-based authentication is configured for: ' . join(',', @configured) ] });
    return 0;
}

sub remove_auth
{
    my ($callback, $subreq, $nodes) = @_;
    set_postbootscripts($nodes, {})
      or return error($callback, 'Cannot update the postscripts table.');
    run_subcommand($callback, $subreq, 'updatenode', $nodes, '-P', 'confighostbasedauth -r')
      and return error($callback, 'confighostbasedauth -r failed on one or more nodes.');
    $callback->({ data => [ 'Host-based authentication is removed from: ' . join(',', @$nodes) ] });
    return 0;
}

1;
