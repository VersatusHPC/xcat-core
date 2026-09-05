#!/usr/bin/env perl
## no critic (TestingAndDebugging::ProhibitNoStrict)
use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

BEGIN {
    package xCAT::Table;
    sub import { }
    sub new { return bless {}, shift; }
    sub getNodeAttribs { return {}; }
    $INC{'xCAT/Table.pm'} = 1;

    package xCAT::NodeRange;
    sub import {
        no strict 'refs';
        *{ caller() . '::noderange' } = sub { return (); };
    }
    $INC{'xCAT/NodeRange.pm'} = 1;

    package xCAT::Zone;
    sub import { }
    $INC{'xCAT/Zone.pm'} = 1;

    package xCAT::Utils;
    sub import { }
    sub isAIX { return 0; }
    sub isServiceNode { return 0; }
    $INC{'xCAT/Utils.pm'} = 1;

    package xCAT::NetworkUtils;
    sub import { }
    sub getipaddr { return (); }
    $INC{'xCAT/NetworkUtils.pm'} = 1;

    package xCAT::PasswordUtils;
    sub import { }
    $INC{'xCAT/PasswordUtils.pm'} = 1;

    package xCAT::TableUtils;
    sub import { }
    sub get_site_attribute { return ('192.0.2.10'); }
    $INC{'xCAT/TableUtils.pm'} = 1;

    package xCAT::MsgUtils;
    sub import { }
    sub trace { }
    sub message { }
    $INC{'xCAT/MsgUtils.pm'} = 1;

    package xCAT::Client;
    sub import { }
    sub submit_request { }
    $INC{'xCAT/Client.pm'} = 1;

    package LWP;
    sub import { }
    $INC{'LWP.pm'} = 1;

    package LWP::UserAgent;
    sub new { return bless {}, shift; }

    package HTTP::Request::Common;
    sub import {
        no strict 'refs';
        *{ caller() . '::GET' } = sub { return $_[0]; };
    }
    $INC{'HTTP/Request/Common.pm'} = 1;
}

my $repo_root = File::Spec->catdir($FindBin::Bin, '..', '..');
my $plugin    = File::Spec->catfile(
    $repo_root, qw(xCAT-server lib xcat plugins credentials.pm)
);
require $plugin;

my $getcert = File::Spec->catfile(
    $repo_root, qw(xCAT-genesis-scripts usr bin getcert)
);
open(my $source_file, '<', $getcert)
  or BAIL_OUT("cannot read $getcert: $!");
my $source = do { local $/; <$source_file> };
close($source_file);

# Run the expression the Genesis image runs. A match against the text would
# report nothing when the subject moves to a helper.
my ($subject_expression) = $source =~ /openssl \s+ req \b [^\n]*? -subj \s+ ("[^"]*")/x;
BAIL_OUT('getcert no longer builds the CSR subject with openssl req -subj')
  unless defined($subject_expression);

my $scratch = tempdir(CLEANUP => 1);

# Genesis has no xCAT database. It reads the name from the kernel, and DHCP
# gives that name a domain.
sub subject_for_hostname {
    my ($reported) = @_;
    my $script = File::Spec->catfile($scratch, 'subject.sh');
    open(my $out, '>', $script) or die "cannot write $script: $!";
    print {$out} <<'SHELL';
hostname() {
    case "$1" in
        -s) printf '%s\n' "${FAKE_HOSTNAME%%.*}" ;;
        *)  printf '%s\n' "$FAKE_HOSTNAME" ;;
    esac
}
SHELL
    print {$out} "printf '%s' $subject_expression\n";
    close($out) or die "cannot close $script: $!";
    local $ENV{FAKE_HOSTNAME} = $reported;
    my $subject = `bash $script`;
    die "cannot run $script" if $?;
    return $subject;
}

my $key = File::Spec->catfile($scratch, 'certkey.pem');
system('openssl', 'genrsa', '-out', $key, '2048') == 0
  or BAIL_OUT('openssl cannot create a key for the request');

my $requests = 0;

sub csr_with_subject {
    my ($subject) = @_;
    my $csr = File::Spec->catfile($scratch, 'request-' . $requests++ . '.csr');
    system('openssl', 'req', '-new', '-key', $key, '-out', $csr,
        '-subj', $subject) == 0
      or BAIL_OUT("openssl cannot create a request for $subject");
    return $csr;
}

my $matches = \&xCAT_plugin::credentials::_csr_subject_matches_node;

my $qualified = subject_for_hostname('n1.cluster.example');
is(
    $matches->(csr_with_subject($qualified), 'n1'),
    1,
    'the management node signs the request of a node whose hostname has a domain'
);

my $plain = subject_for_hostname('n1');
is(
    $matches->(csr_with_subject($plain), 'n1'),
    1,
    'a node without a domain keeps its name'
);

is(
    $matches->(csr_with_subject($qualified), 'n2'),
    0,
    'the management node refuses a request that names another node'
);

done_testing();
