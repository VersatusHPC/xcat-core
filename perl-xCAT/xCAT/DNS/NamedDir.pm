package xCAT::DNS::NamedDir;

use strict;
use warnings;

#-------------------------------------------------------------------------------

=head3 prepare

    Descriptions:
        Give the named working directory to root and the named group.
    Arguments:
        $dir: the working directory, for example /var/lib/named
        $uid: the owner uid
        $gid: the group gid
    Returns:
        1 on success, 0 when chown fails

=cut

#-------------------------------------------------------------------------------
sub prepare {
    my ($dir, $uid, $gid) = @_;

    return 0 unless chown($uid, $gid, $dir);
    return 1;
}

1;
