#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../xCAT-server/lib";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More;

$ENV{XCATCFG}  ||= 'SQLite:/tmp';
$ENV{XCATROOT} ||= "$FindBin::Bin/../../xCAT-server";

my $ddns_plugin_path =
  "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/ddns.pm";
if (-f $ddns_plugin_path) {
    require $ddns_plugin_path;
}
else {
    require xCAT_plugin::ddns;
}

my $zone   = '100.100.100.IN-ADDR.ARPA.';
my $record = '1.100.100.100.IN-ADDR.ARPA. 86400 IN PTR dnstestnode.xcat52.lab.';

my @messages;
my $rc = drive_send_ddns_update($zone, $record, \@messages);

is($rc, 1, 'send_ddns_update reports the rejected update as a failure');
is(scalar(@messages), 1, 'send_ddns_update sends one failure message');
like($messages[0], qr/\Q$record\E/,
    'the failure message names the record named refused');
unlike($messages[0], qr/entry ''/,
    'the failure message does not report an empty entry');

done_testing();

# Call send_ddns_update the way add_or_delete_records calls it for the last
# batch of a zone, with a resolver that refuses the update.
sub drive_send_ddns_update {
    my ($zone_name, $record_text, $messages) = @_;

    my $update = Local::DDNS::Update->new($record_text);

    no warnings qw(redefine once);
    local *xCAT_plugin::ddns::ddns_sign_update = sub { return; };
    local *xCAT::SvrUtils::sendmsg = sub {
        my ($msg) = @_;
        push @{$messages}, ref($msg) eq 'ARRAY' ? $msg->[1] : $msg;
        return;
    };

    return xCAT_plugin::ddns::send_ddns_update(
        {}, Local::DDNS::Resolver->new('FORMERR'), $update, $zone_name);
}

{

    package Local::DDNS::Update;

    sub new {
        my ($class, @records) = @_;
        return bless
          { records => [ map { Local::DDNS::RR->new($_) } @records ] }, $class;
    }

    sub update { return @{ $_[0]->{records} }; }
}

{

    package Local::DDNS::RR;

    sub new { return bless { text => $_[1] }, $_[0]; }

    sub string { return $_[0]->{text}; }
}

{

    package Local::DDNS::Resolver;

    sub new { return bless { rcode => $_[1] }, $_[0]; }

    sub send { return Local::DDNS::Reply->new($_[0]->{rcode}); }
}

{

    package Local::DDNS::Reply;

    sub new { return bless { rcode => $_[1] }, $_[0]; }

    sub header { return $_[0]; }

    sub rcode { return $_[0]->{rcode}; }
}
