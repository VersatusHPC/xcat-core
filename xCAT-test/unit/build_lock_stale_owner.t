#!/usr/bin/perl
# A build killed with SIGKILL leaves its lock directory behind. Every later build of the
# same target then fails at mkdir, for as long as the directory exists -- seven days, on
# xcat-master, for openeuler-20.03sp4-x86_64.
#
# Breaking a stale lock is where this class of fix goes wrong, so three properties are
# held down here beside the basic one: a lock whose owner is alive is still refused, a
# recycled pid does not count as its recorded owner, and two acquirers racing one stale
# lock cannot both win.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Slurper qw(read_text write_text);
use POSIX ();
use FindBin qw($Bin);
use lib "$Bin/../../build-utils/lib";
use XCAT::BuildUtils qw(take_build_lock);

my $CKOUT = '/opt/builds/devel/xcat-core';
my $TMP   = tempdir(CLEANUP => 1);
my $DIR   = XCAT::BuildUtils::lock_path_for($CKOUT, $TMP) . '.d';

# A pid that cannot name a process: Linux rejects kill(0, $pid) above pid_max. Asserted
# rather than assumed -- a negative needs a positive control, and every staleness check
# below depends on this pid really being dead.
my $IMPOSSIBLE_PID = do {
    my $max = eval { read_text('/proc/sys/kernel/pid_max') };
    defined($max) && $max =~ /\A\s*(\d+)/ ? $1 + 1 : 0x7FFFFFFF;
};
ok( !kill(0, $IMPOSSIBLE_PID),
    "pid $IMPOSSIBLE_PID names no process, so it is a dead lock owner" );
ok( kill(0, $$), 'kill(0) does find this process, so the check above can say no' );

my $MY_START = XCAT::BuildUtils::proc_starttime($$);
ok( defined $MY_START && $MY_START =~ /\A\d+\z/,
    'proc_starttime reads field 22 of /proc/<pid>/stat for this process' );

# ---- 1. an owner that is gone -------------------------------------------------------
stage("pid=$IMPOSSIBLE_PID start=$MY_START");
my $broken = eval { take_build_lock($CKOUT, $TMP) };
ok( defined $broken, 'a lock whose owner pid is gone is broken and retaken' )
    or diag "take_build_lock died: $@";
like( read_text("$DIR/owner"), qr/\Apid=$$ start=$MY_START\n\z/,
      'the retaken lock records this process and its start time' );
undef $broken;

# ---- 2. no owner recorded at all ----------------------------------------------------
# The production case: buildrpms.pl's own lock wrote no owner file, so the directory left
# on xcat-master is empty and nothing can tell whether a build still holds it.
stage(undef);
ok( !-e "$DIR/owner", 'staged an empty lock directory, as a killed buildrpms leaves' );
my $ownerless = eval { take_build_lock($CKOUT, $TMP) };
ok( defined $ownerless, 'a lock directory with no owner file is broken and retaken' )
    or diag "take_build_lock died: $@";

# ---- 3. an owner that is alive is refused -------------------------------------------
# $ownerless is held by this process. Asserting WHICH guard answered, not merely that
# something died: a refusal for any other reason would satisfy a bare ok(!defined).
my $refused = eval { take_build_lock($CKOUT, $TMP) };
ok( !defined $refused, 'a lock held by a live owner is refused' );
like( $@, qr/already holds/, 'the refusal is the live-holder guard' );
like( $@, qr/\Qpid=$$\E/,    'the refusal names the live pid from the owner file' );
undef $ownerless;
ok( !-d $DIR, 'releasing the lock removes its directory' );

# ---- 4. a recycled pid is not its recorded owner ------------------------------------
# A pid cannot be recycled on demand, but the state a recycle produces can be staged
# exactly: a pid that IS alive, recorded with a start time that is not its own.
stage("pid=$$ start=" . ($MY_START + 1));
ok( kill(0, $$), 'the staged owner pid is alive, so only the identity differs' );
my $recycled = eval { take_build_lock($CKOUT, $TMP) };
ok( defined $recycled, 'a live pid whose start time does not match is treated as gone' )
    or diag "take_build_lock died: $@";
undef $recycled;

# A matching identity is still refused, so check 4 is not passing because the start time
# is ignored altogether.
stage("pid=$$ start=$MY_START");
my $same = eval { take_build_lock($CKOUT, $TMP) };
ok( !defined $same, 'a live pid whose start time matches still holds the lock' );
like( $@, qr/already holds/, 'and it is the live-holder guard that refused' );
rmdir_lock();

# ---- 5. a holder killed with SIGKILL strands nothing --------------------------------
# The defect, stated as the property that fixes it. The lock is an flock on a file under
# local /var/lock (tmpfs on the build hosts), and the kernel releases an flock when the
# holder dies however it dies. So no break is needed in the case that caused the incident,
# and the directory logic above is only for a peer running the previous revision.
#
# This check cannot pass on a lock that is a directory alone: a SIGKILLed holder leaves
# the directory and the next acquirer fails at mkdir, which is what failed
# openeuler-20.03sp4-x86_64 for seven days.
rmdir_lock();
pipe(my $ready, my $tell) or die "pipe: $!";
my $holder = fork();
die "fork: $!" unless defined $holder;
if (!$holder) {
    close $ready;
    my $got = eval { take_build_lock($CKOUT, $TMP) };
    syswrite($tell, defined($got) ? "held\n" : "failed\n");
    # Hold until killed. _exit is never reached; it is here so a stray wake cannot run the
    # END blocks or flush the parent's inherited buffers.
    sleep 300;
    POSIX::_exit(0);
}
close $tell;
my $said = <$ready> // '';
close $ready;
is( $said, "held\n", 'a child process takes the lock' );

my $blocked = eval { take_build_lock($CKOUT, $TMP) };
ok( !defined $blocked, 'while that child lives, this process cannot take the lock' );
like( $@, qr/already holds/, 'and it is the live-holder guard that refused' );

kill 'KILL', $holder;
waitpid($holder, 0);
ok( !kill(0, $holder), 'the holder is gone, killed with a signal it cannot handle' );

my $after = eval { take_build_lock($CKOUT, $TMP) };
ok( defined $after, 'the lock is free immediately after the holder is SIGKILLed' )
    or diag "take_build_lock died: $@";
undef $after;

# No aside directory may survive, on any path above.
my @leaked = glob("$TMP/*.stale.*");
is_deeply( \@leaked, [], 'no .stale. directory is left behind' );

sub stage {
    my ($owner) = @_;
    rmdir_lock();
    mkdir $DIR or die "cannot stage $DIR: $!";
    write_text("$DIR/owner", "$owner\n") if defined $owner;
    return;
}

sub rmdir_lock {
    unlink "$DIR/owner";
    rmdir $DIR;
    return;
}

done_testing();
