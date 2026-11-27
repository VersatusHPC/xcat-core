#!/usr/bin/env perl
# The scalar installation sequence of xcat-install-lib.sh in a chroot, as root: the resolved disk
# reaches the destructive caller only when it is unchanged after begin. The preflight cases that
# need no chroot are in xCAT-test/bats/freebsd_storage_preflight.bats.
use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../xCAT-server/lib/perl";
use File::Copy qw(copy);
use Test::More;
use xCAT::FreeBSDPkg;
use XCAT::Test::Chroot qw(stage_binary);
use lib "$FindBin::Bin/../lib";
use XCAT::Test::File qw(read_file write_file);

my $directory = $ENV{XCAT_FREEBSD_INSTALLER_DIR} || "$FindBin::Bin/../../xCAT-server/share/xcat/install/freebsd";
my $library = "$directory/xcat-install-lib.sh";

sub fixture {
    my ($count) = @_;
    $count ||= 3;
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/bin", "$root/work", "$root/labels");
    my (@members, @expected, @disks, @graph);
    for my $index (0 .. $count) {
        my $name = "ada$index";
        push @disks, $name;
        push @members, "$name\@SERIAL$index" if $index < $count;
        push @expected, join("\t", $name, "SERIAL$index", 1, 8589934592, 512, 'r0w0e0', 100 + $index) . "\n"
            if $index < $count;
        write_file("$root/$name.geom", "Geom name: $name\nProviders:\n1. Name: $name\n" .
            "   Mediasize: 8589934592 (8G)\n   Sectorsize: 512\n   Mode: r0w0e0\n   ident: SERIAL$index\n\n");
        write_file("$root/$name.stat", 'Character Device:' . (100 + $index) . "\n");
        write_file("$root/$name.size", "8589934592\n");
        write_file("$root/$name.head", "\0" x 1048576);
        write_file("$root/$name.tail", "\0" x 1048576);
        push @graph, "0 DISK $name 8589934592 512 hd 16 sc 63\n" .
            "1 LABEL diskid/DISK-SERIAL$index 8589934592 512 i 0 o 0\n";
    }
    write_file("$root/disks", join(' ', @disks) . "\n");
    write_file("$root/graph", join('', @graph));
    write_file("$root/members", join(',', @members));
    write_file("$root/expected", join('', @expected));
    write_file("$root/pools", '');
    write_file("$root/geli", '');
    write_file("$root/partitions", '');
    my %commands = (
        geom => 'test "$1 $2" = "disk list" || exit 90
            count=0; test ! -f "$FIXTURE_DIR/geom-count" || count=$(cat "$FIXTURE_DIR/geom-count")
            count=$((count+1)); printf "%s\n" "$count" > "$FIXTURE_DIR/geom-count"
            for f in "$FIXTURE_DIR"/ada*.geom; do
                test -z "${3:-}" || test "$f" = "$FIXTURE_DIR/$3.geom" || continue
                if [ "$count" -gt 1 ] && [ -f "$f.changed" ]; then cat "$f.changed"; else cat "$f"; fi
            done',
        sysctl => 'case "$*" in
            "-n kern.disks") cat "$FIXTURE_DIR/disks" ;;
            "-n kern.geom.conftxt") cat "$FIXTURE_DIR/graph" ;;
            "-n vm.swap_total") printf "0\n" ;;
            "-n hw.physmem") printf "8589934592\n" ;;
            *) exit 90 ;;
            esac',
        stat => 'test "$1" = -f && test "$2" = "%HT:%r" || exit 90
            cat "$FIXTURE_DIR/${3##*/}.stat"',
        zpool => 'test "$*" = "list -H -o name" || exit 90; cat "$FIXTURE_DIR/pools"',
        geli => 'test "$*" = "status -s" || exit 90; cat "$FIXTURE_DIR/geli"',
        gpart => 'test "$*" = list || exit 90; cat "$FIXTURE_DIR/partitions"',
        zdb => 'case "$1" in -l|-ll) ;; *) exit 90 ;; esac
            name=${2##*/}; test ! -f "$FIXTURE_DIR/zdb-status-$name" || exit "$(cat "$FIXTURE_DIR/zdb-status-$name")"
            test -f "$FIXTURE_DIR/labels/$name" || exit 2; cat "$FIXTURE_DIR/labels/$name"',
        sha256 => 'test "$*" = -q || exit 90; openssl dgst -sha256 | awk \'{print $NF}\'',
        fstyp => 'test "$1" = -u || exit 90
            name=${2##*/}
            if [ -f "$FIXTURE_DIR/fstyp-$name" ]; then
                cat "$FIXTURE_DIR/fstyp-$name"; exit "$(cat "$FIXTURE_DIR/fstyp-status-$name")"
            fi
            printf "fstyp: /dev/%s: filesystem not recognized\n" "$name" >&2; exit 1',
        dd => 'src= dst= block= skip=0 count=
            for arg do
                case "$arg" in if=*) src=${arg#if=} ;; of=*) dst=${arg#of=} ;; bs=*) block=${arg#bs=} ;;
                    skip=*) skip=${arg#skip=} ;; count=*) count=${arg#count=} ;; *) exit 90 ;; esac
            done
            case "$dst" in "$FIXTURE_DIR"/work/storage.*/zero|"$FIXTURE_DIR"/work/storage.*/window|\
                "$FIXTURE_DIR"/work/pkgbase-work/storage.*/zero|"$FIXTURE_DIR"/work/pkgbase-work/storage.*/window) ;; *) exit 90 ;; esac
            if [ "$src" = /dev/zero ]; then
                test "$block" = 1048576 && test "$count" = 1 || exit 90
                cp "$FIXTURE_DIR/ada0.head.zero" "$dst"; exit
            fi
            name=${src#/dev/}; region=tail; test "$skip" != 0 || region=head
            test "$((block*count))" -eq 1048576 || exit 90
            if [ "$region" = tail ]; then
                size=$(cat "$FIXTURE_DIR/$name.size") || exit 90
                test "$((block*skip))" -eq "$((size-1048576))" || exit 90
            fi
            test ! -f "$FIXTURE_DIR/dd-fail-$name-$region" || exit 1
            cp "$FIXTURE_DIR/$name.$region" "$dst"',
    );
    write_file("$root/ada0.head.zero", "\0" x 1048576);
    for my $name (keys %commands) {
        write_file("$root/bin/$name", "#!/bin/sh\nprintf '%s %s\\n' '$name' \"\$*\" >> \"\$FIXTURE_DIR/events\"\n" .
            "test ! -f \"\$FIXTURE_DIR/fail-$name\" || exit 1\n$commands{$name}\n");
        chmod 0755, "$root/bin/$name" or die $!;
    }
    return $root;
}

sub automatic_config {
    my ($root, %changes) = @_;
    my %config = (format => 'xcat-freebsd-install-5', release => '15.1-RELEASE',
        node => 'node1', hostname => 'node1', generation => 'a' x 32,
        master => '192.0.2.1', port => 3002, ipv4 => '192.0.2.2', netmask => '255.255.255.0',
        gateway => '', nameservers => '', mac => '52:54:00:12:34:56',
        filesystem => 'zfs', swap_size => '0', swap_mode => 'none',
        zfs_topology => 'mirror', zfs_vdevs => 'auto:2', zfs_compression => 'lz4', zfs_ashift => 12,
        disk_action => 'empty', disk_selection => 'empty', preserve_disks => '-',
        install_url => 'http://192.0.2.1/install', package_plan_sha256 => 'b' x 64,
        boot_media_sha256 => 'c' x 64, runtime_sha256 => 'd' x 64, authorized_key_base64 => 'AAAA',
        bootstrap => 'dhcp', console_port => 'none', console_speed => 0, console_flow => 'none',
        install_boot_options_base64 => '', target_boot_options_base64 => '', %changes);
    delete $config{$_} for grep { !defined($config{$_}) } keys %config;
    write_file("$root/work/config", join('', map { "$_=$config{$_}\n" } sort keys %config));
}

subtest 'scalar installation resolves before staging and rechecks after begin' => sub {
    plan(skip_all => 'Installer command fixtures require a Linux lab root') unless $^O eq 'linux' && $> == 0;
    my $jail = tempdir(CLEANUP => 1);
    make_path(map { "$jail/$_" } qw(runtime xcat dev usr/libexec/bsdinstall));
    stage_binary($jail, $_) for ('/bin/sh', '/bin/timeout', map { "/usr/bin/$_" }
        qw(awk cat cut sort mktemp tr wc cmp rm cp mv chmod mkdir dirname basename openssl env grep base64 date sleep));
    copy($library, "$jail/runtime/library") or die $!;
    copy("$directory/installerconfig.tmpl", "$jail/runtime/template") or die $!;
    write_file("$jail/xcat/runtime.tsv", "fixture runtime\n");
    write_file("$jail/dev/null", '');
    write_file("$jail/usr/libexec/bsdinstall/pkgbase", <<'PKGBASE');
#!/bin/sh
test "$1" = --xcat-prepare-1 || exit 90
grep -q '^target_disk=ada0$' "$2" || exit 91
root=${3%/work/pkgbase-work}
printf 'prepared\n' >> "$root/events"
PKGBASE
    chmod(oct('0755'), "$jail/usr/libexec/bsdinstall/pkgbase") or die $!;
    for my $case (qw(unchanged changed unavailable)) {
        my $root = fixture(1);
        write_file("$root/events", '');
        automatic_config($root, format => 'xcat-freebsd-install-3', filesystem => 'ufs', target_disk => 'auto',
            map { $_ => undef } qw(zfs_topology zfs_vdevs swap_mode zfs_compression zfs_ashift disk_action));
        write_file("$root/change-on-begin", '') if $case eq 'changed';
        if ($case eq 'unavailable') {
            write_file("$root/ada0.head", 'USED');
            write_file("$root/ada1.head", 'USED');
        }
        my %commands = (
            kldload => 'exit 0',
            mount => 'grep -q "^target_disk=ada0$" "$FIXTURE_DIR/work/config" || exit 91
                printf "workspace\n" >> "$FIXTURE_DIR/events"',
            nc => 'read -r protocol generation attempt phase members
                printf "phase %s\n" "$phase" >> "$FIXTURE_DIR/events"
                if [ "$phase" = begin ] && [ -f "$FIXTURE_DIR/change-on-begin" ]; then
                    printf USED > "$FIXTURE_DIR/ada0.head"
                fi
                printf "ready\n%s %s %s ok\n" "$protocol" "$generation" "$phase"',
            bsdinstall => "printf 'bsdinstall boundary\\n' >> '$root/events'\ncp \"\$2\" '$root/invoked-installer'\nexit 19",
        );
        for my $command (keys %commands) {
            write_file("$root/bin/$command", "#!/bin/sh\n$commands{$command}\n");
            chmod(oct('0755'), "$root/bin/$command") or die $!;
        }
        make_path("$jail$root");
        system('cp', '-a', "$root/.", "$jail$root") == 0 or die 'Cannot stage installer fixture';
        my $result = xCAT::FreeBSDPkg::run_command(['/usr/sbin/chroot', $jail, '/bin/sh', '-c',
            '. "$1"; xcat_read_config "$XCAT_WORK/config" && xcat_install_system "$2" "$1"',
            'sh', '/runtime/library', '/runtime/template'], cwd => $jail,
            environment => {PATH => "$root/bin:/usr/bin:/bin", LC_ALL => 'C', FIXTURE_DIR => $root,
                XCAT_WORK => "$root/work", XCAT_ATTEMPT => 'b' x 32, XCAT_PROVISIONING_IF => 'em0'}, timeout => 20);
        is($result->{signal}, 0, "$case exits without a signal");
        ok(!$result->{failure}, "$case finishes within the fixture deadline") or diag($result->{stderr});
        my $events = read_file("$jail$root/events");
        if ($case eq 'unchanged') {
            like($events, qr/workspace.*prepared.*phase[ ]begin.*bsdinstall[ ]boundary/sx,
                'a resolved unchanged disk reaches the installer after preparation and authorization') or diag($result->{stderr});
            my $invoked = -f "$jail$root/invoked-installer" ? read_file("$jail$root/invoked-installer") : '';
            like($invoked, qr/^PARTITIONS="ada0[ ]GPT/mx,
                'the actual destructive caller receives the resolved disk');
        } elsif ($case eq 'changed') {
            like($events, qr/phase[ ]begin/x, 'disk content changes after the real begin handshake');
            unlike($events, qr/bsdinstall[ ]boundary/x, 'changed disk content cannot reach the destructive caller');
        } else {
            unlike($events, qr/workspace|prepared|phase[ ]begin|bsdinstall[ ]boundary/x,
                'failed selection cannot stage packages or request destructive authorization');
        }
    }
};
done_testing();
