#!/usr/bin/env perl

# share/xcat/cons/kvm attaches goconserver to the serial console of a KVM guest. It ran
# `virsh console` inside a tmux session on the hypervisor and attached to that session. tmux
# repaints the whole pane on every attach, so each goconserver reconnect wrote the last screen
# again into /var/log/consoles/<node>.log. A message from an old boot then appeared in the
# console log of every later run. goconserver already shares one console among its clients, so
# the console needs no multiplexer.

use strict;
use warnings;

use FindBin;
use Test::More;

use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use xCAT::KVMConsole;

my @cmd = xCAT::KVMConsole::console_command('kvmhost1', 'cn1');

is_deeply([ @cmd[0 .. 2] ], [ 'ssh', '-t', 'kvmhost1' ],
    'the command runs on the hypervisor, with a terminal for virsh console');
is(join(' ', @cmd[3 .. $#cmd]), 'virsh -c qemu:///system console --force cn1',
    'the hypervisor runs virsh console on the domain and nothing else');
ok(!(grep { /\b(?:tmux|screen)\b/ } @cmd),
    'no terminal multiplexer stands between goconserver and the console');

done_testing();
