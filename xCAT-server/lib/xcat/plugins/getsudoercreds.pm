# IBM(c) 2025 EPL license http://www.eclipse.org/legal/epl-v10.html
#-------------------------------------------------------

=head1
  xCAT plugin to handle getsudoercreds command - returns sudoer credentials
  for the requesting node. Used by modern sudoerpolicy mode to fetch
  credentials at runtime instead of embedding them in mypostscripts.

  Security: Uses callback verification like credentials.pm - server connects
  back to the node on a privileged port to verify the request originated
  from a root process during provisioning.

=cut

#-------------------------------------------------------
package xCAT_plugin::getsudoercreds;
use strict;
use warnings;
use xCAT::Utils;
use xCAT::MsgUtils;
use xCAT::NodeRange;
use xCAT::Table;
use IO::Socket::INET;
use IO::Select;

1;

#-------------------------------------------------------

=head3  handled_commands

Return list of commands handled by this plugin

=cut

#-------------------------------------------------------

sub handled_commands
{
    return {
        'getsudoercreds' => "getsudoercreds",
    };
}


#-------------------------------------------------------

=head3  ok_with_node

  Callback verification - connect to node on privileged port to verify
  the request originated from a root process.

=cut

#-------------------------------------------------------
sub ok_with_node {
    my $node = shift;
    my $port = shift;

    my $select = IO::Select->new;
    my $sock = IO::Socket::INET->new(
        PeerAddr => $node,
        Proto    => "tcp",
        PeerPort => $port,
        Timeout  => 5
    );
    unless ($sock) {
        xCAT::MsgUtils->trace(0, 'E', "getsudoercreds: cannot connect to $node:$port for verification");
        return 0;
    }
    $select->add($sock);
    print $sock "CREDOKBYYOU?\n";
    unless ($select->can_read(5)) {
        xCAT::MsgUtils->trace(0, 'E', "getsudoercreds: timeout waiting for verification from $node:$port");
        close($sock);
        return 0;
    }
    my $response = <$sock>;
    close($sock);
    chomp($response) if $response;
    if ($response && $response eq "CREDOKBYME") {
        return 1;
    }
    xCAT::MsgUtils->trace(0, 'E', "getsudoercreds: invalid verification response from $node:$port");
    return 0;
}


#-------------------------------------------------------

=head3  process_request

  Process the getsudoercreds request from a node.
  Returns the sudoer password hash for the requesting node.

=cut

#-------------------------------------------------------
sub process_request
{
    my $request  = shift;
    my $callback = shift;
    my $rsp;

    my $client;
    if ($request->{'_xcat_clienthost'}) {
        $client = $request->{'_xcat_clienthost'}->[0];
    }
    unless ($client) {
        xCAT::MsgUtils->trace(0, 'E', "getsudoercreds: malformed request, no client host");
        return;
    }

    my $origclient = $client;
    if ($client) { ($client) = noderange($client) }
    unless ($client) {
        xCAT::MsgUtils->trace(0, "E", "getsudoercreds: request from $origclient could not be correlated to a node");
        return;
    }

    my $callback_port = $request->{'callback_port'}->[0] if $request->{'callback_port'};
    unless ($callback_port && $callback_port < 1024) {
        xCAT::MsgUtils->trace(0, 'E', "getsudoercreds: request from $client missing privileged callback_port");
        $rsp->{error}->[0] = "callback_port required (must be < 1024)";
        $callback->($rsp);
        return;
    }

    unless (ok_with_node($client, $callback_port)) {
        xCAT::MsgUtils->trace(0, 'E', "getsudoercreds: callback verification failed for $client:$callback_port");
        $rsp->{error}->[0] = "callback verification failed";
        $callback->($rsp);
        return;
    }

    my @nodestatus_ent = xCAT::TableUtils->get_site_attribute("nodestatus");
    my $nodestatus_enabled = (!defined($nodestatus_ent[0]) || $nodestatus_ent[0] !~ /^(n|no|0|disable)$/i);

    if ($nodestatus_enabled) {
        my $nodelisttab = xCAT::Table->new('nodelist');
        unless ($nodelisttab) {
            xCAT::MsgUtils->trace(0, 'E', "getsudoercreds: cannot open nodelist table");
            $rsp->{error}->[0] = "cannot verify node provisioning state";
            $callback->($rsp);
            return;
        }
        my $nlent = $nodelisttab->getNodeAttribs($client, ['status']);
        my $status = $nlent->{'status'} || '';
        my @allowed_states = qw(installing postbooting booting netbooting powering-on);
        unless (grep { $status eq $_ } @allowed_states) {
            xCAT::MsgUtils->trace(0, 'E', "getsudoercreds: node $client status '$status' not in provisioning state");
            $rsp->{error}->[0] = "node not in provisioning state";
            $callback->($rsp);
            return;
        }
        xCAT::MsgUtils->trace(0, "I", "getsudoercreds: node $client in valid state '$status'");
    } else {
        xCAT::MsgUtils->trace(0, "W", "getsudoercreds: site.nodestatus disabled, skipping status check for $client");
    }

    xCAT::MsgUtils->trace(0, "I", "getsudoercreds: verified request from node $client");

    require xCAT::SudoerPolicy;

    my %sitevals;
    my @entries = xCAT::TableUtils->get_site_attribute("sudoerpolicy");
    if ($entries[0]) {
        $sitevals{sudoerpolicy} = $entries[0];
    }

    my $resolved = xCAT::SudoerPolicy::resolve_sudoer_policy(\%sitevals);
    my $policy = $resolved->{policy};

    if ($policy ne 'modern') {
        xCAT::MsgUtils->trace(0, "W", "getsudoercreds: request from $client but policy is '$policy', not 'modern'");
        $rsp->{error}->[0] = "sudoerpolicy is not 'modern'";
        $callback->($rsp);
        return;
    }

    my $passwdtab = xCAT::Table->new('passwd');
    unless ($passwdtab) {
        $rsp->{error}->[0] = "cannot open passwd table";
        $callback->($rsp);
        return;
    }

    my @allents = $passwdtab->getAllAttribs(qw(key username password cryptmethod disable));
    my @sudoer_ents = grep {
        defined($_->{key}) && $_->{key} eq 'sudoer' &&
        (!defined($_->{disable}) || $_->{disable} !~ /^(yes|1)$/i)
    } @allents;

    if (scalar(@sudoer_ents) == 0) {
        $rsp->{error}->[0] = "no passwd entry with key=sudoer";
        $callback->($rsp);
        return;
    }

    if (scalar(@sudoer_ents) > 1) {
        $rsp->{error}->[0] = "multiple passwd entries with key=sudoer";
        $callback->($rsp);
        return;
    }

    my $ent = $sudoer_ents[0];

    unless (defined($ent->{'username'}) && $ent->{'username'} ne '') {
        $rsp->{error}->[0] = "passwd entry missing username";
        $callback->($rsp);
        return;
    }

    unless (defined($ent->{'password'}) && $ent->{'password'} ne '') {
        $rsp->{error}->[0] = "passwd entry missing password";
        $callback->($rsp);
        return;
    }

    my $user = $ent->{'username'};
    my $pw = $ent->{'password'};
    my $cryptmethod = $ent->{'cryptmethod'} || 'sha256';

    unless (xCAT::SudoerPolicy::is_valid_sudoer_username($user)) {
        xCAT::MsgUtils->trace(0, 'E', "getsudoercreds: invalid username '$user' in passwd table");
        $rsp->{error}->[0] = "invalid username in passwd table";
        $callback->($rsp);
        return;
    }

    if ($user =~ /[\x00-\x1f\x7f]/) {
        xCAT::MsgUtils->trace(0, 'E', "getsudoercreds: username contains control characters");
        $rsp->{error}->[0] = "invalid username format";
        $callback->($rsp);
        return;
    }

    if ($pw !~ /^\$[156]\$/) {
        my %methods = ('md5' => '$1$', 'sha256' => '$5$', 'sha512' => '$6$');
        my $prefix = $methods{$cryptmethod} || '$5$';
        my $salt = substr(join('', map { ('a'..'z','A'..'Z','0'..'9')[rand 62] } 1..8), 0, 8);
        $pw = crypt($pw, $prefix . $salt);
    }

    if ($pw =~ /[\x00-\x1f\x7f\n\r]/) {
        xCAT::MsgUtils->trace(0, 'E', "getsudoercreds: password hash contains invalid characters");
        $rsp->{error}->[0] = "invalid password hash format";
        $callback->($rsp);
        return;
    }

    unless ($pw =~ /^\$[156]\$(rounds=\d+\$)?[a-zA-Z0-9.\/]+\$[a-zA-Z0-9.\/]+$/) {
        xCAT::MsgUtils->trace(0, 'E', "getsudoercreds: password hash format validation failed");
        $rsp->{error}->[0] = "invalid password hash format";
        $callback->($rsp);
        return;
    }

    xCAT::MsgUtils->trace(0, "I", "getsudoercreds: returning credentials for user '$user' to node $client");

    $rsp->{data}->[0] = "SUDOER_USER=$user";
    $rsp->{data}->[1] = "SUDOER_PWHASH=$pw";
    $callback->($rsp);

    return 0;
}

1;
