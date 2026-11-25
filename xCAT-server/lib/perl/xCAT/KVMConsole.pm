package xCAT::KVMConsole;

# The command that share/xcat/cons/kvm runs to attach a console server to the serial console
# of a KVM guest. It is here so a test can read the command without a hypervisor.

use strict;
use warnings;

#-------------------------------------------------------------------------------

=head3 console_command

    Descriptions: The command that attaches to the serial console of a KVM guest.
                  goconserver and conserver share one console among their clients, so
                  no multiplexer runs on the hypervisor. A multiplexer repaints its
                  screen on each attach, and the console log then repeats old output.
                  --force takes the console from an earlier session.
    Arguments:    host - the hypervisor that runs the guest
                  node - the libvirt domain name, which is the xCAT node name
    Returns:      the command as a list, for exec

=cut

#-------------------------------------------------------------------------------
sub console_command {
    my ($host, $node) = @_;
    return ('ssh', '-t', $host, 'virsh', '-c', 'qemu:///system', 'console', '--force', $node);
}

1;
