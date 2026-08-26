#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $repo_root  = File::Spec->catdir( $FindBin::Bin, '..', '..' );
my $script_dir = File::Spec->catdir( $repo_root, 'xCAT-server', 'share', 'xcat', 'install', 'scripts' );

my $script = File::Spec->catfile( $script_dir, 'getinstdisk' );
plan skip_all => 'getinstdisk not found' unless -r $script;

sub slurp {
    open( my $fh, '<', $_[0] ) or die "Unable to read $_[0]: $!";
    my $c = do { local $/; <$fh> };
    close($fh);
    return $c;
}

# Each scenario runs the shipped script through its explicit path overrides,
# while a stub udevadm serves device properties from fixture files.
sub run_scenario {
    my (%disk) = @_;
    my $vroc0 = delete $disk{_vroc0};
    my $vroc  = delete $disk{_vroc};
    my $xen   = delete $disk{_xen};
    my $sandbox = tempdir( CLEANUP => 1 );
    my $fixdir  = "$sandbox/fix";
    my $bindir  = "$sandbox/bin";
    mkdir $fixdir;
    mkdir $bindir;

    open( my $parts, '>', "$sandbox/partitions" ) or die $!;
    print $parts "major minor  #blocks  name\n\n";
    my $minor = 0;
    for my $name ( sort keys %disk ) {
        printf $parts "   8 %5d  524288000 %s\n", $minor++, $name;
    }
    close($parts);

    for my $name ( sort keys %disk ) {
        my %attr = %{ $disk{$name} };
        open( my $props, '>', "$fixdir/$name.props" ) or die $!;
        print $props "ID_WWN=$attr{wwn}\n" if $attr{wwn};
        print $props "DEVPATH=$attr{path}\n" if $attr{path};
        print $props "DEVTYPE=disk\n";
        close($props);
        open( my $attrs, '>', "$fixdir/$name.attrs" ) or die $!;
        print $attrs qq{    ATTRS{size}=="1024000000"\n};
        print $attrs qq{    DRIVERS=="$attr{driver}"\n} if $attr{driver};
        my @models = $attr{models} ? @{ $attr{models} } : ( $attr{model} ? $attr{model} : () );
        print $attrs qq{    ATTRS{model}=="$_"\n} for @models;
        close($attrs);
    }

    open( my $udev, '>', "$bindir/udevadm" ) or die $!;
    print $udev <<'UDEV';
#!/bin/sh
for a in "$@"; do
    case "$a" in
    --name=*) name=${a#--name=} ;;
    esac
done
name=${name#/dev/}
case "$*" in
*--query=property*) cat "$FIXDIR/$name.props" 2>/dev/null ;;
*--attribute-walk*) cat "$FIXDIR/$name.attrs" 2>/dev/null ;;
esac
exit 0
UDEV
    close($udev);
    chmod 0755, "$bindir/udevadm";

    local $ENV{FIXDIR} = $fixdir;
    local $ENV{PATH} = "$bindir:$ENV{PATH}";
    local $ENV{MASTER_IP} = '';
    local $ENV{XCAT_GETINSTDISK_PARTITIONS} = "$sandbox/partitions";
    local $ENV{XCAT_GETINSTDISK_RESULT} = "$sandbox/xcat.install_disk";
    local $ENV{XCAT_GETINSTDISK_TMPDIR} = "$sandbox/xcat.getinstalldisk";
    local $ENV{XCAT_GETINSTDISK_VROC_VOLUME0_0} = $vroc0 ? '/dev/loop0' : "$sandbox/no-vroc0";
    local $ENV{XCAT_GETINSTDISK_VROC_VOLUME0} = $vroc ? '/dev/loop0' : "$sandbox/no-vroc";
    local $ENV{XCAT_GETINSTDISK_XEN_XVDA} = $xen ? '/dev/loop0' : "$sandbox/no-xen";
    system("sh '$script' >'$sandbox/log' 2>&1");
    my $status = $? >> 8;
    my $chosen = -r "$sandbox/xcat.install_disk" ? slurp("$sandbox/xcat.install_disk") : '';
    chomp $chosen;
    my $log = slurp("$sandbox/log");
    return wantarray ? ( $chosen, $status, $log ) : $chosen;
}

sub selects {
    my ( $expected, $name, %disk ) = @_;
    is( run_scenario(%disk), $expected, $name );
    return;
}

# A direct attached disk wins over a RAID volume when both are present. The
# RAID volume sorts first by name, so the choice comes from the driver group.
selects( '/dev/sdb', 'the direct attached disk wins over the RAID volume',
    sda => { driver => 'megaraid_sas' },
    sdb => { driver => 'ahci' } );

# A server with only RAID volumes still selects one.
selects( '/dev/sda', 'a RAID volume is selected when nothing better exists',
    sda => { driver => 'megaraid_sas' } );

# A SAS host adapter loses to a direct attached disk, and still wins over a
# driver with no group of its own.
selects( '/dev/sdb', 'the direct attached disk wins over the host adapter',
    sda => { driver => 'mpt3sas' },
    sdb => { driver => 'ahci' } );

selects( '/dev/sda', 'the host adapter wins over an unknown driver',
    sda => { driver => 'mpt3sas' },
    sdb => { driver => 'virtio_blk' } );

# A driverless NVMe device still gets selected from the last group.
selects( '/dev/nvme0n1', 'an NVMe device is selected from the last group',
    nvme0n1 => {} );

# No usable disk falls back to the documented default.
selects( '/dev/sda', 'no disks fall back to the default' );

# The driver group decides before the identifier. A disk that reports no WWN
# used to be dropped when another disk reported one, or to be ignored because
# the readback only opened the files of the last identifier class seen.
selects( '/dev/sdb', 'the direct attached disk wins when only the RAID volume reports a WWN',
    sda => { driver => 'megaraid_sas', wwn => '0x5000cca0aaaa0001' },
    sdb => { driver => 'ahci' } );

selects( '/dev/sda', 'the direct attached disk wins when it is scanned first without a WWN',
    sda => { driver => 'ahci' },
    sdb => { driver => 'megaraid_sas', wwn => '0x5000cca0aaaa0002' } );

# Within one driver group the identifier decides, and a disk that reports one
# is preferred, because that name is stable across reboots.
selects( '/dev/sdb', 'the disk with a WWN wins inside the group',
    sda => { driver => 'ahci' },
    sdb => { driver => 'ahci', wwn => '0x5000cca0bbbb0001' } );

selects( '/dev/sdb', 'the lower WWN wins inside the group',
    sda => { driver => 'ahci', wwn => '0x5000cca0bbbb0002' },
    sdb => { driver => 'ahci', wwn => '0x5000cca0bbbb0001' } );

selects( '/dev/sda', 'a path is preferred over no identifier at all',
    sda => { driver => 'ahci', path => '/devices/pci0000:00/0000:00:1f.2/ata1/host0/target0:0:0/0:0:0:0/block/sda' },
    sdb => { driver => 'ahci' } );

# A Xen guest presents xvd names. The scan has to see them, because the
# fallback below it would take the first one without looking.
selects( '/dev/xvda', 'a Xen disk is scanned rather than assumed',
    xvda => { driver => 'vbd' } );

selects( '/dev/xvdb', 'the better driver group wins among Xen disks',
    xvda => { driver => 'vbd' },
    xvdb => { driver => 'ahci' } );

SKIP: {
    skip '/dev/loop0 is required for fallback behavior', 3 unless -b '/dev/loop0';
    selects( '/dev/md/Volume0_0', 'the VROC volume is preferred as the fallback',
        _vroc0 => 1 );
    selects( '/dev/md/Volume0', 'the alternate VROC name is accepted',
        _vroc => 1 );
    selects( '/dev/xvda', 'the Xen block device is used as a fallback',
        _xen => 1 );
}

my ( $fallback, $status, $log ) = run_scenario();
is($fallback, '/dev/sda', 'no disks fall back to the documented default');
is($status, 0, 'the default fallback succeeds without msgutil_r');
unlike($log, qr/msgutil_r: (?:not found|command not found)/,
    'the optional failure logger is not invoked when unavailable');

# The installer include is shipped text and remains a valid wiring contract.
ok( !-e File::Spec->catfile( $script_dir, 'getinstdisk.rhels10' ),
    'the RHEL 10 copy of the script is gone' );
like( slurp( File::Spec->catfile( $script_dir, 'pre.rhels10' ) ),
    qr{/share/xcat/install/scripts/getinstdisk#},
    'the RHEL 10 installer includes the common script' );

done_testing();
