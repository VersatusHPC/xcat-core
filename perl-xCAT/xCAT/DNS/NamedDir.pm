package xCAT::DNS::NamedDir;

use strict;
use warnings;

#-------------------------------------------------------------------------------

=head3 prepare

    Descriptions:
        Give the named working directory to root and the named group, and
        add group write and the sticky bit. Other permission bits stay.
    Arguments:
        $dir: the working directory, for example /var/lib/named
        $uid: the owner uid
        $gid: the group gid
    Returns:
        1 on success, 0 when chown or chmod fails

=cut

#-------------------------------------------------------------------------------
sub prepare {
    my ($dir, $uid, $gid) = @_;

    return 0 unless chown($uid, $gid, $dir);

    # named runs as the named user and writes zone dumps here. Leap 15 and 16
    # ship the directory 1775 root:named. Leap 42.3 ships it 0755 named:named.
    my @st = stat($dir) or return 0;
    return 0 unless chmod(($st[2] & 07777) | 01070, $dir);
    return 1;
}

1;
