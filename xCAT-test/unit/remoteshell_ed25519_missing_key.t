#!/usr/bin/env perl
use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

my $script = File::Spec->catfile( $FindBin::Bin, '..', '..',
    'xCAT', 'postscripts', 'remoteshell' );
plan skip_all => 'remoteshell not found' unless -r $script;
plan skip_all => 'no bash'               unless -x '/bin/bash';

# The section writes its response to the scratch path of the postscript. Do not
# run it next to a real remoteshell.
my $response_file = '/tmp/ssh_ed25519_hostkey';
plan skip_all => "$response_file is in use" if -e $response_file;

open( my $fh, '<', $script ) or die "Unable to read $script: $!";
my $source = do { local $/; <$fh> };
close($fh);

my ($block) = $source =~
  m{(\# if node supports ed25519 host key.*?\n  rm /tmp/ssh_ed25519_hostkey\nfi\n)}s;
BAIL_OUT('the ed25519 section of remoteshell was not found') unless defined $block;

# logger writes to syslog, and to stderr as well when it gets -s. updatenode
# collects the stderr of a postscript, so a message sent with -s is part of the
# output of the command.
my $prelude = <<'BASH';
log_label=xcat
useflowcontrol=0
SYSLOG=__SYSLOG__
CALLS=__CALLS__

ssh-keygen() { return __KEYGEN_RC__; }

# The section removes scratch files of the postscript. Keep it off the paths of
# the host that runs the test.
rm() { echo "rm $*" >> "$CALLS"; }

getcredentials.awk() {
    echo "getcredentials.awk $*" >> "$CALLS"
    cat "__RESPONSE__"
}

logger() {
    local to_stderr=0 tag=xcat
    local -a msg=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -s) to_stderr=1 ;;
            -t) tag="$2"; shift ;;
            -p) shift ;;
            *)  msg+=("$1") ;;
        esac
        shift
    done
    echo "$tag: ${msg[*]}" >> "$SYSLOG"
    if [ $to_stderr -eq 1 ]; then
        echo "$tag: ${msg[*]}" >&2
    fi
}
BASH

# The response credentials.pm sends when /etc/xcat/hostkeys holds no ed25519 key.
my $error_response = <<'XML';
<xcatresponse>
<error>Unable to read private ed25519 key from /etc/xcat/hostkeys</error>
<errorcode>1</errorcode>
</xcatresponse>
<xcatresponse>
<serverdone>
</serverdone>
</xcatresponse>
XML

sub slurp {
    my ($path) = @_;
    return '' unless -e $path;
    open( my $in, '<', $path ) or die "Unable to read $path: $!";
    my $text = do { local $/; <$in> };
    close($in);
    return $text;
}

sub write_file {
    my ( $path, $text ) = @_;
    open( my $out, '>', $path ) or die "Unable to write $path: $!";
    print {$out} $text;
    close($out);
    return $path;
}

# Run the ed25519 section of the postscript. node_supports says whether the node
# can make an ed25519 key; response is what the server answers.
sub run_section {
    my (%opt) = @_;
    my $dir  = tempdir( CLEANUP => 1 );
    my $body = $prelude;
    $body =~ s/__SYSLOG__/"$dir\/syslog"/;
    $body =~ s/__CALLS__/"$dir\/calls"/;
    $body =~ s/__KEYGEN_RC__/$opt{node_supports} ? 0 : 1/e;
    $body =~ s/__RESPONSE__/write_file("$dir\/response", $opt{response})/e;

    my $prog = write_file( "$dir/section.sh", $body . $block );
    system("/bin/bash $prog >$dir/out 2>$dir/err");
    my $rc = $? >> 8;
    unlink($response_file);

    return {
        rc     => $rc,
        stdout => slurp("$dir/out"),
        stderr => slurp("$dir/err"),
        syslog => slurp("$dir/syslog"),
        calls  => slurp("$dir/calls"),
    };
}

# A management node in FIPS mode cannot make an ed25519 key, so xcatconfig
# generates none and credentials.pm answers with an error. The node keeps the
# ed25519 key it made itself, so the node is not broken.
my $missing = run_section(
    node_supports => 1,
    response      => $error_response,
);

like( $missing->{calls}, qr/ssh_ed25519_hostkey/,
    'the node asks the server for the cluster ed25519 key' );
unlike( $missing->{stderr}, qr/[Ee]rror/,
    'no error reaches the output when the cluster has no ed25519 key' );
unlike( $missing->{stdout}, qr/[Ee]rror/,
    'no error reaches the standard output either' );
like( $missing->{syslog}, qr/ed25519.*(?:unavailable|skipping)/i,
    'the missing cluster ed25519 key is recorded in syslog as skipped' );
is( $missing->{rc}, 0, 'the section ends with a status of zero' );

# A node without ed25519 support asks for nothing and says nothing.
my $unsupported = run_section(
    node_supports => 0,
    response      => $error_response,
);

unlike( $unsupported->{calls}, qr/getcredentials/,
    'a node without ed25519 support does not ask for the key' );
is( $unsupported->{stderr}, '',
    'a node without ed25519 support prints nothing' );

done_testing();
