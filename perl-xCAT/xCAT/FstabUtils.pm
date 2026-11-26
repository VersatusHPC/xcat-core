# IBM(c) 2026 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT::FstabUtils;

use strict;
use warnings;

#-------------------------------------------------------------------------------

=head3 fsck_pass

    Descriptions:
        Return the fsck pass number (the sixth fstab field) for a file system.
    Arguments:
        $vfstype: the file system type (third fstab field)
        $file:    the mount point (second fstab field)
    Returns:
        The pass number that xCAT has always written for this entry

=cut

#-------------------------------------------------------------------------------
sub fsck_pass {
    my ($vfstype, $file) = @_;
    return 1 if $file eq '/';
    return 2 if $vfstype eq 'nfs' || $file eq '/tmp' || $file eq '/var/tmp';
    return 0;
}

#-------------------------------------------------------------------------------

=head3 entry

    Descriptions:
        Return one fstab line, with the pass from fsck_pass.
    Arguments:
        $spec, $file, $vfstype, $mntops: the first four fstab fields
    Returns:
        The line, with a trailing newline

=cut

#-------------------------------------------------------------------------------
sub entry {
    my ($spec, $file, $vfstype, $mntops) = @_;
    my $dump = ($vfstype eq 'nfs') ? 1 : 0;
    return join(' ', $spec, $file, $vfstype, $mntops, $dump, fsck_pass($vfstype, $file)) . "\n";
}

#-------------------------------------------------------------------------------

=head3 diskless_fstab

    Descriptions:
        Return the fstab text that genimage writes into a diskless image.
    Arguments:
        $rootfs_name: the spec of the / entry, <profile>_<arch>
        $tmpopts:     the mount options of /tmp and /var/tmp, or undef for no such entries
    Returns:
        The fstab text

=cut

#-------------------------------------------------------------------------------
sub diskless_fstab {
    my ($rootfs_name, $tmpopts) = @_;
    my @lines = (
        entry('devpts', '/dev/pts', 'devpts', 'gid=5,mode=620'),
        entry('tmpfs',  '/dev/shm', 'tmpfs',  'defaults'),
        entry('proc',   '/proc',    'proc',   'defaults'),
        entry('sysfs',  '/sys',     'sysfs',  'defaults'),
    );
    if (defined($tmpopts)) {
        push @lines, entry('tmpfs', '/tmp',     'tmpfs', $tmpopts);
        push @lines, entry('tmpfs', '/var/tmp', 'tmpfs', $tmpopts);
    }

    # statelite.pm finds the / entry by this spec and changes rw to ro.
    push @lines, entry($rootfs_name, '/', 'tmpfs', 'rw');
    return join('', @lines);
}

#-------------------------------------------------------------------------------

=head3 set_entry

    Descriptions:
        Put one entry into a list of fstab lines. Each line with the same spec and
        mount point is replaced. When there is no such line, the entry is appended.
    Arguments:
        $lines:   reference to the list of lines, each with its newline
        $spec, $file, $vfstype, $mntops: the first four fstab fields
    Returns:
        (reference to the new list of lines, 1 if the list changed or 0)

=cut

#-------------------------------------------------------------------------------
sub set_entry {
    my ($lines, $spec, $file, $vfstype, $mntops) = @_;
    my $new = entry($spec, $file, $vfstype, $mntops);
    my @out;
    my $found = 0;
    foreach my $line (@$lines) {
        my @f = split(' ', $line);
        if (@f >= 2 && $f[0] eq $spec && $f[1] eq $file) {
            next if $found;
            push @out, $new;
            $found = 1;
            next;
        }
        push @out, $line;
    }
    if (!$found) {
        if (@out && $out[-1] !~ /\n\z/) {
            $out[-1] .= "\n";
        }
        push @out, $new;
    }
    my $changed = (join('', @out) ne join('', @$lines)) ? 1 : 0;
    return (\@out, $changed);
}

#-------------------------------------------------------------------------------

=head3 update_file

    Descriptions:
        Apply set_entry to an fstab file. The file is written only when it changes.
    Arguments:
        $path: the fstab file
        $spec, $file, $vfstype, $mntops: the first four fstab fields
    Returns:
        1 if the file changed, 0 if not, undef on an error

=cut

#-------------------------------------------------------------------------------
sub update_file {
    my ($path, @fields) = @_;
    my @lines;
    if (-e $path) {
        open(my $in, '<', $path) or return undef;
        @lines = <$in>;
        close($in);
    }
    my ($out, $changed) = set_entry(\@lines, @fields);
    return 0 unless $changed;

    my $tmp = "$path.xcattmp";
    open(my $fh, '>', $tmp) or return undef;
    print $fh @$out;
    close($fh) or return undef;
    rename($tmp, $path) or return undef;
    return 1;
}

1;
