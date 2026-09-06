#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use File::Spec;
use Test::More;

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..', '..' );

sub slurp {
    my ($rel) = @_;
    my $path = File::Spec->catfile( $repo_root, $rel );
    return unless -r $path;
    open( my $fh, '<', $path ) or die "Unable to read $path: $!";
    my $c = do { local $/; <$fh> };
    close($fh);
    return $c;
}

my $syncfiles  = slurp('xCAT-server/lib/xcat/plugins/syncfiles.pm');
my $updatenode = slurp('xCAT-server/lib/xcat/plugins/updatenode.pm');
my $xdsh       = slurp('xCAT-server/lib/xcat/plugins/xdsh.pm');

plan skip_all => 'plugins not found'
  unless defined($syncfiles) && defined($updatenode) && defined($xdsh);

# The plugins need a management node to load, so lift the three pieces that
# have to agree on the shape of the identity and run them. Matching the text
# of the subrequest leaves the test green when the username is removed from
# the hash after it is built.
my ($syncsub) = $syncfiles =~ /^(sub syncfiles \{\n.*?^\}\n)/ms;
BAIL_OUT('syncfiles.pm no longer defines sub syncfiles') unless $syncsub;

my ($identity) = $xdsh =~
  /^(    if \(!\(\$ENV\{'DSH_FROM_USERID'\}\)\) \{\n.*?^    \}\n    if \(!\(\$ENV\{'DSH_TO_USERID'\}\)\) \{\n.*?^    \}\n)/ms;
BAIL_OUT('xdsh.pm no longer derives the DSH userids from the request') unless $identity;

my ($updatecall) = $updatenode =~
  /xCAT::Utils->runxcmd\(\n(\s*\{\n\s*command => \["xdcp"\],.*?\n\s*\}),\n/s;
BAIL_OUT('updatenode.pm no longer builds its xdcp request as a hash literal')
  unless $updatecall;

# syncfiles asks these two for the list and for the log. Neither is under test.
{
    package xCAT::SvrUtils;
    our $synclist;
    sub getsynclistfile { my ( $class, $nodes ) = @_; return $synclist }
    package xCAT::MsgUtils;
    our @messages;
    sub message { my ( $class, @rest ) = @_; push @messages, \@rest; return }
}

{
    my $code = join( "\n",
        'package XCATTest::Sync;',
        'use strict; use warnings;',
        $syncsub,
        'sub dsh_identity {',
        '    my ($request) = @_;',
        $identity,
        '    return;',
        '}',
        'sub updatenode_xdcp_request {',
        '    my ( $request, $args, $env, $synclist, %syncfile_node ) = @_;',
        '    return ' . $updatecall . ';',
        '}',
        '1;' );
    eval $code;    ## no critic
    BAIL_OUT("unable to compile the extracted plugin blocks: $@") if $@;
}

# Run syncfiles for one node and keep the requests it makes.
sub sync_requests {
    my ( $node, $list ) = @_;
    local $xCAT::SvrUtils::synclist = { $node => $list };
    my @sent;
    XCATTest::Sync::syncfiles( $node, sub { }, sub { push @sent, [@_]; return } );
    return \@sent;
}

my $sent = sync_requests( 'node1', '/install/custom/node1.synclist' );
is( scalar @$sent, 1, 'one synclist makes one xdcp subrequest' );
my $req = $sent->[0]->[0];
is_deeply( $req->{command}, ['xdcp'], 'the subrequest runs xdcp' );
is_deeply( $req->{node},    ['node1'], 'the subrequest names the node' );

# The identity has to be in the request the plugin actually sends, not only in
# the text that builds it.
ok( exists $req->{username}, 'the xdcp subrequest names a username' );
is( ref $req->{username}, 'ARRAY',
    'the username is the arrayref form the consumers index into' );
is( $req->{username}->[0], 'root', 'the sync runs as root' );

# A synclist attribute can name several files, and each one is its own sync.
$sent = sync_requests( 'node1', '/install/a.synclist,/install/b.synclist' );
is( scalar @$sent, 2, 'a comma separated synclist makes one subrequest per file' );
is( $sent->[1]->[0]->{username}->[0], 'root', 'every subrequest carries the identity' );

# The consumer. Feeding it the request syncfiles built is what proves the two
# shapes fit, which is the whole point of the arrayref.
{
    local %ENV = ();
    XCATTest::Sync::dsh_identity($req);
    is( $ENV{DSH_FROM_USERID}, 'root', 'xdsh derives DSH_FROM_USERID from the request' );
    is( $ENV{DSH_TO_USERID},   'root', 'xdsh derives DSH_TO_USERID from the request' );
}

# A bare string was the original form of this change and broke the non
# hierarchical path, because the consumer indexes into the value.
{
    local %ENV = ();
    my $ok = eval { XCATTest::Sync::dsh_identity( { username => 'root' } ); 1 };
    ok( !$ok, 'a bare string username cannot be indexed by the consumer' );
    is( $ENV{DSH_FROM_USERID}, undef, 'a bare string username sets no identity' );
}

# A request with no username must leave the environment alone rather than set
# an empty identity.
{
    local %ENV = ();
    XCATTest::Sync::dsh_identity( {} );
    is( $ENV{DSH_FROM_USERID}, undef, 'a request with no username sets no identity' );
}

# updatenode makes the same xdcp call and passes the identity it was called
# with. The two must not diverge again.
my $upd = XCATTest::Sync::updatenode_xdcp_request(
    { username => ['root'] }, [ '-F', '/install/a.synclist' ],
    ['DSH_RSYNC_FILE=/install/a.synclist'],
    '/install/a.synclist', '/install/a.synclist' => ['node1'] );
is_deeply( $upd->{command}, ['xdcp'], 'updatenode runs xdcp' );
is_deeply( $upd->{username}, ['root'],
    'updatenode passes the identity it was called with' );
{
    local %ENV = ();
    XCATTest::Sync::dsh_identity($upd);
    is( $ENV{DSH_FROM_USERID}, 'root',
        'the updatenode request satisfies the same consumer' );
}

done_testing();
