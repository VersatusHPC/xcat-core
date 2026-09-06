#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More tests => 5;

# xcattest matches check:output=~PAT against the command output, error text included. lsdef
# answers a missing object with "Could not find an object named 'testnode1' of type 'node'.",
# so check:output=~testnode1 matches the very failure the case exists to catch.
#
# Both cases are driven through the real xcattest with the xCAT commands shadowed, once with
# the node definitions present and once with the definition step doing nothing.

my $XCATTEST = "$FindBin::Bin/../xcattest";
my $CASEDIR  = "$FindBin::Bin/../autotest/testcase";

ok(-f $XCATTEST, 'xcattest is present') or BAIL_OUT("$XCATTEST not found");

my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/run/bin", "$tmp/stub");
copy($XCATTEST, "$tmp/run/bin/xcattest") or BAIL_OUT("cannot copy xcattest: $!");
chmod 0755, "$tmp/run/bin/xcattest";
write_file("$tmp/cfg", "[System]\nCN=testcn\n");
write_stubs();

for my $c ([ 'noderm/cases0', 'noderm_noderange', 'nodeadd' ],
    [ 'nodepurge/cases0', 'nodepurge_noderange', 'mkdef' ])
{
    my ($file, $case, $definer) = @$c;
    my $casedir = extract_case("$CASEDIR/$file", $case);

    is(run_case($casedir, $case, 0), 'Passed',
        "$case passes when the node definitions are there");
    is(run_case($casedir, $case, 1), 'Failed',
        "$case fails when $definer defines nothing");
}

#---
# extract_case: write one case from a shipped case file into a scratch case directory.
#---
sub extract_case {
    my ($path, $case) = @_;

    open(my $fh, '<', $path) or BAIL_OUT("cannot read $path: $!");
    my @lines = <$fh>;
    close($fh);

    my ($keep, @case) = (0);
    for my $line (@lines) {
        $keep = 1 if $line =~ /^start:\Q$case\E\s*$/;
        next unless $keep;
        push @case, $line;
        last if $line =~ /^end\b/;
    }
    BAIL_OUT("$path holds no case named $case") unless @case;

    my $dir = tempdir(DIR => $tmp, CLEANUP => 1);
    write_file("$dir/cases0", join('', @case));
    return $dir;
}

#---
# run_case: run one case under the real xcattest and return Passed or Failed.
# $blind makes the definition command a no-op, which is the failure under test.
#---
sub run_case {
    my ($casedir, $case, $blind) = @_;

    unlink glob("$tmp/state/*");
    make_path("$tmp/state");
    # The conf names testcn as the compute node. __GETNODEATTR__ asks lsdef for its
    # attributes while the case is loaded, before any command in the case runs.
    write_file("$tmp/state/testcn", "os=alma10\narch=x86_64\n");
    write_file("$tmp/stub/blind", $blind ? "1\n" : "0\n");

    my @out = qx{cd $tmp/run/bin && XCATROOT=/usr XCATTEST_CASEDIR=$casedir XCATTEST_STATE=$tmp/state XCATTEST_BLIND=$tmp/stub/blind PATH=$tmp/stub:\$PATH ./xcattest -f $tmp/cfg -t $case 2>&1};
    my ($result) = grep { /^-+END::\Q$case\E::/ } @out;
    diag(join('', @out)) unless $result;
    return 'no result line' unless $result;
    return $result =~ /::(Passed|Failed)::/ ? $1 : 'unparsed';
}

#---
# write_stubs: the xCAT commands the two cases run. lsdef reports what the definers left in
# XCATTEST_STATE and answers a missing object with the text the real lsdef prints.
#---
sub write_stubs {
    my $define = <<'SH';
#!/bin/sh
[ "$(cat "$XCATTEST_BLIND")" = "1" ] && exit 0
for a in "$@"; do
  case "$a" in
    -*|*=*) ;;
    *) for n in $(echo "$a" | tr ',' ' '); do printf 'groups=all\n' > "$XCATTEST_STATE/$n"; done ;;
  esac
done
exit 0
SH
    my $remove = <<'SH';
#!/bin/sh
for a in "$@"; do
  case "$a" in
    -*|*=*) ;;
    *) for n in $(echo "$a" | tr ',' ' '); do rm -f "$XCATTEST_STATE/$n"; done ;;
  esac
done
exit 0
SH
    my $lsdef = <<'SH';
#!/bin/sh
# lsdef [-t <type>] [-o <name>] [-i <attrs>] [<noderange>]
names=""; attrs=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t) shift ;;
    -o) names="$names $(echo "$2" | tr ',' ' ')"; shift ;;
    -i) attrs="$2"; shift ;;
    -*) ;;
    *)  names="$names $(echo "$1" | tr ',' ' ')" ;;
  esac
  shift
done
rc=0
for n in $names; do
  if [ -f "$XCATTEST_STATE/$n" ]; then
    echo "Object name: $n"
    if [ -n "$attrs" ]; then
      for a in $(echo "$attrs" | tr ',' ' '); do grep "^$a=" "$XCATTEST_STATE/$n" || true; done
    else
      cat "$XCATTEST_STATE/$n"
    fi
  else
    echo "Could not find an object named '$n' of type 'node'."
    rc=1
  fi
done
exit $rc
SH
    write_file("$tmp/stub/$_", $define) for qw(nodeadd mkdef);
    write_file("$tmp/stub/$_", $remove) for qw(noderm nodepurge);
    write_file("$tmp/stub/lsdef", $lsdef);
    write_file("$tmp/stub/$_", "#!/bin/sh\nexit 0\n") for qw(makehosts nodeset);
    # nodepurge_noderange asserts the purged node no longer answers.
    write_file("$tmp/stub/ping", "#!/bin/sh\nexit 1\n");
    chmod 0755, glob("$tmp/stub/*");
    return;
}

sub write_file {
    my ($path, $text) = @_;
    open(my $fh, '>', $path) or BAIL_OUT("cannot write $path: $!");
    print {$fh} $text;
    close($fh);
    return;
}
