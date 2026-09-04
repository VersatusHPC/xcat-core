#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $postscript = File::Spec->catfile($FindBin::Bin, '..', '..',
    'xCAT', 'postscripts', 'servicenode');
plan skip_all => 'servicenode postscript not found' unless -r $postscript;

open(my $fh, '<', $postscript) or die "Unable to read $postscript: $!";
my $source = do { local $/; <$fh> };
close($fh);

# A service node is a customer machine. The postscript may configure it, but it may not add a
# repository the administrator did not choose, and it may not need the internet to finish.
# The Linux half shells out through runcmd(), so lift it out and run it with runcmd()
# recording instead of running. A changed shape must fail here, not silently test nothing.
my ($linux) = $source =~ /^else\n\{\n[ ]+\#\s+Linux setup\n(.*?)^\}\n\nexit \$rc;/ms;
BAIL_OUT('could not extract the Linux branch from the servicenode postscript')
    unless defined $linux;

# The commands the branch would run, in order: runcmd() arguments, and anything it starts
# through a backtick (the stubs below record those).
our @CMDS;

my $stubdir = tempdir(CLEANUP => 1);
my $cmdlog  = File::Spec->catfile($stubdir, 'commands');

# grep answers as an EL service node would, so the branch takes its EL path. Everything else
# records and exits 0. bash and sh resolve these ahead of PATH.
for my $name (qw(logger rpm dnf yum apt-get zypper curl wget)) {
    my $stub = File::Spec->catfile($stubdir, $name);
    open(my $out, '>', $stub) or die "Unable to write $stub: $!";
    print $out "#!/bin/sh\nprintf '%s' \"\$(basename \"\$0\")\" >> $cmdlog\n"
        . "for a in \"\$\@\"; do printf ' %s' \"\$a\" >> $cmdlog; done\n"
        . "printf '\\n' >> $cmdlog\nexit 0\n";
    close($out);
    chmod 0755, $stub;
}
my $grep = File::Spec->catfile($stubdir, 'grep');
open(my $out, '>', $grep) or die "Unable to write $grep: $!";
print $out "#!/bin/sh\nprintf 'grep' >> $cmdlog\n"
    . "for a in \"\$\@\"; do printf ' %s' \"\$a\" >> $cmdlog; done\n"
    . "printf '\\n' >> $cmdlog\n"
    . "echo 'PLATFORM_ID=\"platform:el9\"'\nexit 0\n";
close($out);
chmod 0755, $grep;

local $ENV{PATH} = "$stubdir:$ENV{PATH}";
delete local $ENV{NODESETSTATE};
{ no warnings 'once'; $::XCATROOT = '/opt/xcat'; }

# The environment the removed workaround tested for. Without this the branch could take its
# non-EL path and the test would measure nothing.
my $platform = `grep -Ei 'platform:el' /etc/os-release 2>/dev/null`;
ok($platform =~ /platform:el/, 'the branch runs as if on an EL service node');
unlink $cmdlog;

my $code = 'package ServiceNodeLinux;'
    . ' our ($rc, $msg, $log_label); $rc = 0; $msg = ""; $log_label = "xcat";'
    . ' sub runcmd { push @main::CMDS, $_[0]; return 0; }'
    . ' sub copycerts { push @main::CMDS, "copycerts"; return 0; }'
    . $linux
    . ' 1;';
eval $code or BAIL_OUT("could not evaluate the Linux branch: $@");    ## no critic (ProhibitStringyEval)

if (open(my $log, '<', $cmdlog)) {
    while (my $line = <$log>) { chomp $line; push @CMDS, $line; }
    close($log);
}

# The branch really ran. Without these the assertion below passes on an empty list.
ok(scalar(grep { $_ eq 'rpm -e OpenIPMI-tools' } @CMDS), 'the branch removed OpenIPMI-tools');
ok(scalar(grep { $_ eq 'copycerts' } @CMDS),             'the branch copied the certificates');
ok(scalar(grep { $_ eq 'xcatserver -d' } @CMDS),         'the branch ran xcatserver');
ok(scalar(grep { $_ eq 'xcatclient -d' } @CMDS),         'the branch ran xcatclient');

my @repo_change = grep {
       /\b(?:dnf|yum|apt-get|apt|zypper)\b[^|;]*\binstall\b[^|;]*[\w.+-]+-release\b/
    || /\b(?:dnf|yum)\b[^|;]*\bconfig-manager\b[^|;]*--add-repo\b/
    || /\bzypper\b[^|;]*\b(?:ar|addrepo)\b/
    || /\brpm\b[^|;]*--import\b/
    || /\b(?:curl|wget)\b[^|;]*\.repo\b/
} @CMDS;
is_deeply(\@repo_change, [],
    'the postscript adds no third-party repository to the service node');

done_testing();
