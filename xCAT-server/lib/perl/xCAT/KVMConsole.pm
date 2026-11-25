package xCAT::KVMConsole;

# The command that share/xcat/cons/kvm runs to attach a console server to the serial console
# of a KVM guest. It is here so a test can read the command without a hypervisor.

use strict;
use warnings;

#-------------------------------------------------------------------------------

=head3 console_command

    Descriptions: The command that attaches to the serial console of a KVM guest.
    Arguments:    host - the hypervisor that runs the guest
                  node - the libvirt domain name, which is the xCAT node name
    Returns:      the command as a list, for exec

=cut

#-------------------------------------------------------------------------------
sub console_command {
    my ($host, $node) = @_;
    my $session   = "serial-$node-cons";
    my $virshcons = "virsh -c qemu:///system console --force $node";
    return ('ssh', '-t', $host,
        "tmux -u new-session -d -A -x 200 -y 50 -s $session '$virshcons'; "
          . "tmux set-option -t $session status off; exec tmux -u attach -t $session");
}

1;
