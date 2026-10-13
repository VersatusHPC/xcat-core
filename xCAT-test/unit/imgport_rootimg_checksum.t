#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use Digest::SHA qw(sha256_hex);
use Errno qw(EIO);
use POSIX ();
use File::Copy ();
use File::Basename qw(dirname);
use File::Find qw(find);
use File::Path qw(make_path rmtree);
use File::Slurper qw(read_binary write_text);
use File::Temp qw(tempdir);
use Sys::Hostname qw(hostname);
use Test::More;
use XCAT::Test::File qw(repo_path);

# The first rename into a path of %FAIL fails, as when the file system refuses it.
our %FAIL;
BEGIN {
    *CORE::GLOBAL::rename = sub {
        my ($from, $to) = @_;
        if ($FAIL{$to}) {
            delete $FAIL{$to};
            $! = EIO;
            return 0;
        }
        return CORE::rename($from, $to);
    };
}

my $fixture = tempdir(CLEANUP => 1);
make_path("$fixture/db", "$fixture/install");
$ENV{XCATCFG} = "SQLite:$fixture/db";
require xCAT::Table;
require(repo_path('xCAT-server/lib/xcat/plugins/imgport.pm'));
xCAT::Table->new('site', -create => 1)->setAttribs({ key => 'installdir' }, { value => "$fixture/install" });

# noderange keeps the node list for a few seconds, so the nodes are defined before the first import.
xCAT::Table->new('nodelist', -create => 1)->setAttribs({ node => $_ }, { groups => 'compute' }) for qw(psnode psnode2);

# The image lock lives in /var/lock/xcat, so the test records the request and decides whether another operation holds it.
our ($HELD, @LOCKED);
{
    no warnings qw(redefine once);
    *xCAT::Utils::acquire_lock_imageop = sub {
        my (undef, $dir) = @_;
        push @LOCKED, $dir;
        return $HELD ? (1, "failed to acquire lock, seems there is another genimage/packimage/rmimage process 4242 running on root image dir \"$dir\"") : (0, {});
    };
    *xCAT::Utils::acquire_lock = sub {
        my (undef, $name) = @_;
        push @LOCKED, $name;
        return {};
    };
}

(my $host = hostname()) =~ s/[^A-Za-z0-9.-]/_/g;
my $published = "image that packimage published\n";
my $imported  = "image from the bundle\n";
my $sequence  = 0;

# imgimport places the files of an extracted bundle over an image that packimage published before.
sub import_image {
    my ($archive_name, $prepare, %manifest) = @_;
    my $dest   = "$fixture/install/netboot/import-" . ++$sequence;
    my $bundle = "$fixture/bundle-$sequence";
    make_path($dest, $bundle, "$dest/.packimage-$host+INTERRUP");
    write_text("$dest/$archive_name", $published);
    write_text("$dest/$archive_name.sha256", sha256_hex($published) . "  $archive_name\n");
    write_text("$dest/$archive_name.metainfo", "metainfo of the published image\n");
    write_text("$dest/rootimg.other", "another format\n");
    write_text("$dest/.packimage-other.host+ACTIVE00", "archive that another host is writing\n");
    write_text("$bundle/$archive_name", $imported);
    write_text("$dest/kernel", "published kernel\n");
    write_text("$dest/initrd-stateless.gz", "published ramdisk\n");
    write_text("$bundle/kernel", "kernel from the bundle\n");
    write_text("$bundle/initrd-stateless.gz", "ramdisk from the bundle\n");
    $prepare->($dest, $bundle) if $prepare;
    @LOCKED = ();
    my @errors;
    my $checksum  = delete $manifest{rootimgchecksum};
    my $extra     = delete $manifest{extra};
    my $extradest = delete $manifest{extradest} // 'DEST/extra';
    my $kit       = delete $manifest{kit};
    my $kitdir    = delete $manifest{kitdir};
    my $kitdescription = delete $manifest{kitdescription} // 'kit of this import';
    my $nodes     = delete $manifest{nodes};
    my $omit      = delete $manifest{omit} || [];
    my $provmethod = delete $manifest{provmethod} // 'netboot';
    my $name = "import-$sequence";
    xCAT::Table->new('osimage', -create => 1)->setAttribs({ imagename => $name }, { osvers => 'rhels9.5', provmethod => 'netboot' });
    my $data = {
        rootimg => "$dest/$archive_name",
        kernel  => "$dest/kernel",
        ramdisk => "$dest/initrd-stateless.gz",
        (map { ($_ => $manifest{$_} =~ s/DEST/$dest/r) } keys %manifest),
        (defined $checksum ? (linuximage => { rootimgchecksum => $checksum }) : ()),
        (defined $extra ? (extra => ref($extra) ? [ map { { src => $_->[0], dest => $_->[1] =~ s/DEST/$dest/r } } @$extra ]
            : { src => $extra, dest => $extradest =~ s/DEST/$dest/r }) : ()),
        (defined $kit ? (kit => { $kit => { kitname => $kit, description => $kitdescription,
            (defined $kitdir ? (kitdir => $kitdir =~ s/DEST/$dest/r) : ()) } }) : ()),
        osimage => { imagename => $name, osvers => 'rhels9.6', osarch => 'x86_64', profile => 'compute', provmethod => $provmethod },
    };
    delete @{$data}{@$omit};
    my $placed = xCAT_plugin::imgport::place_image($data, $bundle, sub { push @errors, @{ $_[0]{error} || [] } }, $nodes);
    return ($placed, join("\n", @errors), $dest, "$dest/$archive_name");
}

# Lists what is under $path, with the target of each symlink and the content of each file.
sub tree {
    my ($path) = @_;
    my @entries;
    find({ no_chdir => 1, wanted => sub {
        push @entries, substr($_, length($path)) . ' ' . (-l $_ ? '-> ' . readlink($_) : -d $_ ? 'directory' : read_binary($_));
    } }, $path) if -e $path || -l $path;
    return join("\n", sort @entries);
}

# The osvers of the image definition, which a failed import must not change.
sub definition {
    my ($dest) = @_;
    my ($name) = $dest =~ m{/(import-\d+)$};
    my ($row) = xCAT::Table->new('osimage')->getAttribs({ imagename => $name }, 'osvers');
    return $row ? $row->{osvers} : undef;
}

for my $archive_name (qw(rootimg.cpio.gz rootimg.tar.xz rootimg.sfs)) {
    my ($placed, $errors, $dest, $archive) = import_image($archive_name);
    is_deeply(\@LOCKED, [ 'imgimport', "$dest/rootimg" ], "$archive_name: the import holds the import lock and the image lock that packimage takes");
    ok($placed, "$archive_name: the bundle is placed");
    is($errors, '', "$archive_name: no error is reported");
    is(read_binary($archive), $imported, "$archive_name: the imported image replaces the previous one");
    is(read_binary("$dest/kernel"), "kernel from the bundle\n", "$archive_name: the imported kernel is placed");
    is(read_binary("$dest/initrd-stateless.gz"), "ramdisk from the bundle\n", "$archive_name: the imported ramdisk is placed");
    is(read_binary("$archive.sha256"), sha256_hex($imported) . "  $archive_name\n", "$archive_name: the checksum describes the imported image");
    is((stat($archive))[2] & 07777, 0644, "$archive_name: nodes can read the image");
    is((stat("$archive.sha256"))[2] & 07777, 0644, "$archive_name: nodes can read the checksum");
    ok(!-e "$archive.metainfo", "$archive_name: the metainfo of the previous image is removed");
    is(read_binary("$archive.ORIG"), $published, "$archive_name: the previous image is kept as .ORIG");
    is(read_binary("$dest/rootimg.other"), "another format\n", "$archive_name: other formats stay");
    ok(!-e "$dest/.packimage-publish", "$archive_name: the publication lock is released");
    is_deeply([ glob("$dest/.packimage-$host+*") ], [], "$archive_name: no temporary directory is left, including an abandoned one");
    ok(-e "$dest/.packimage-other.host+ACTIVE00", "$archive_name: the archive that another host is writing stays");
    is(definition($dest), 'rhels9.6', "$archive_name: the image definition of the bundle is imported");
    is_deeply([ glob("$fixture/install/.imgimport-*"), glob("$dest/.rootimg-previous-*") ], [], "$archive_name: no kept file is left");
}

{
    local $HELD = 1;
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz');
    ok(!$placed, 'an import fails while another image operation holds the image lock');
    like($errors, qr/failed to acquire lock/, 'the held image lock is reported');
    is(read_binary($archive), $published, 'the published image stays while the image lock is held');
    is(read_binary("$archive.sha256"), sha256_hex($published) . "  rootimg.cpio.gz\n", 'the published checksum stays while the image lock is held');
    is(read_binary("$dest/kernel"), "published kernel\n", 'the published kernel stays while the image lock is held');
    is(definition($dest), 'rhels9.5', 'the image definition stays while the image lock is held');
}

{
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', sub {
        my ($dest) = @_;
        mkdir("$dest/.packimage-publish") or die $!;
        write_text("$dest/.packimage-publish/owner", "other.host 4242\n");
        utime(time() - 120, time() - 120, "$dest/.packimage-publish") or die $!;
    });
    ok(!$placed, 'an import fails while another host holds the publication lock');
    like($errors, qr/\Q$dest\E\/\.packimage-publish is held by other\.host 4242\./, 'an import reports a publication lock that another host holds');
    is(read_binary("$dest/kernel"), "published kernel\n", 'the published kernel stays with the published image');
    is(read_binary("$dest/initrd-stateless.gz"), "published ramdisk\n", 'the published ramdisk stays with the published image');
    is(read_binary($archive), $published, 'the published image stays while another host publishes');
    is(read_binary("$archive.sha256"), sha256_hex($published) . "  rootimg.cpio.gz\n", 'the published checksum stays while another host publishes');
    ok(-d "$dest/.packimage-publish", 'the publication lock of the other host is not taken over');
    is_deeply([ glob("$dest/.packimage-$host+*") ], [], 'no temporary directory is left when the import cannot publish');
}

for my $failed (qw(rootimg.cpio.gz.sha256 rootimg.cpio.gz)) {
    local %FAIL;
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', sub {
        my ($dest) = @_;
        $FAIL{"$dest/$failed"} = 1;
    });
    ok(!$placed, "$failed: an import fails when the imported image cannot be published");
    like($errors, qr/Cannot publish \Q$archive\E: /, "$failed: the failed publication is reported");
    is(read_binary($archive), $published, "$failed: the published image stays");
    is(read_binary("$archive.sha256"), sha256_hex($published) . "  rootimg.cpio.gz\n", "$failed: the published checksum stays");
    is(read_binary("$archive.metainfo"), "metainfo of the published image\n", "$failed: the published metainfo stays");
    is(read_binary("$dest/kernel"), "published kernel\n", "$failed: the published kernel stays with the published image");
    is(read_binary("$dest/initrd-stateless.gz"), "published ramdisk\n", "$failed: the published ramdisk stays with the published image");
    is(definition($dest), 'rhels9.5', "$failed: the image definition stays with the published image");
}

{
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', undef, rootimgchecksum => 'no');
    is($errors, '', 'an image with the check turned off is placed');
    is(read_binary($archive), $imported, 'the imported image replaces the previous one');
    is(read_binary("$archive.sha256"), sha256_hex($imported) . "  rootimg.cpio.gz\n", 'the checksum is written also when the check is turned off');
}

{
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', sub {
        write_text("$fixture/bundle-$sequence/initrd-stateless.gz.rootimgcheck", "sha256=marker of the bundled ramdisk\n");
    }, ramdiskcheck => 'DEST/initrd-stateless.gz.rootimgcheck');
    is($errors, '', 'a bundle with the initial ramdisk marker is placed');
    is(read_binary("$dest/initrd-stateless.gz.rootimgcheck"), "sha256=marker of the bundled ramdisk\n",
        'the marker of the bundled initial ramdisk is placed next to it');
}

# A step after the publication fails, so the import puts back everything that it changed.
for my $case ([ 'an extra file that cannot be copied', extra => 'missing.file' ], [ 'nodes that are not defined', nodes => 'undefined-node' ]) {
    my ($label, @manifest) = @$case;
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', sub {
        my ($dest) = @_;
        write_text("$dest/kernel.ORIG", "kernel before the published one\n");
    }, @manifest);
    ok(!$placed, "$label: the import fails");
    is(read_binary($archive), $published, "$label: the published image is put back");
    is(read_binary("$archive.sha256"), sha256_hex($published) . "  rootimg.cpio.gz\n", "$label: the published checksum is put back");
    is(read_binary("$archive.metainfo"), "metainfo of the published image\n", "$label: the published metainfo is put back");
    ok(!-e "$archive.ORIG", "$label: no .ORIG of the published image is left");
    is(read_binary("$dest/kernel"), "published kernel\n", "$label: the published kernel is put back");
    is(read_binary("$dest/kernel.ORIG"), "kernel before the published one\n", "$label: the previous .ORIG of the kernel is put back");
    is(read_binary("$dest/initrd-stateless.gz"), "published ramdisk\n", "$label: the published ramdisk is put back");
    is(definition($dest), 'rhels9.5', "$label: the image definition is put back");
    is_deeply([ glob("$fixture/install/.imgimport-*"), glob("$dest/.rootimg-previous-*") ], [], "$label: no kept file is left");
}

{
    no warnings 'redefine';
    local *xCAT_plugin::imgport::set_config = sub { die "the osimage table is gone\n" };
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz');
    ok(!$placed, 'an import fails when a later step dies');
    like($errors, qr/the osimage table is gone/, 'the error of the step that died is reported');
    is(read_binary($archive), $published, 'the published image is put back after a step dies');
    is(read_binary("$dest/kernel"), "published kernel\n", 'the published kernel is put back after a step dies');
}

{
    # Another host publishes the image while the import runs, and the import then fails.
    no warnings 'redefine';
    local *xCAT_plugin::imgport::moveExtra = sub {
        my $archive = dirname($_[2]) . '/rootimg.cpio.gz';
        write_text("$archive.other", "image of another host\n");
        rename("$archive.other", $archive) or die $!;
        return 0;
    };
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', undef, extra => 'anything');
    ok(!$placed, 'an import fails after another host published the image');
    is(read_binary($archive), "image of another host\n", 'the image of the other host stays');
    like($errors, qr/another publication replaced it.*The previous image is kept in \Q$dest\E\/\.rootimg-previous-/s,
        'the conflict is reported with the directory that keeps the previous image');
}

{
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/extra/conf/secret", "$bundle/extra/conf/shared", "$dest/extra/shared");
        write_text("$bundle/extra/conf/secret/key", "key\n");
        chmod(0700, "$bundle/extra/conf/secret") or die $!;
        chmod(0750, "$bundle/extra/conf/shared") or die $!;
        chmod(0755, "$dest/extra/shared") or die $!;
    }, extra => 'conf');
    is($errors, '', 'an import with an extra directory reports no error');
    is((stat("$dest/extra/secret"))[2] & 07777, 0700, 'a new extra directory keeps its mode');
    is((stat("$dest/extra/shared"))[2] & 07777, 0750, 'an existing extra directory takes the mode of the bundle, as with cp -a');
}

{
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/extra/conf/shared", "$dest/extra/shared");
        chmod(0750, "$bundle/extra/conf/shared") or die $!;
        chmod(0755, "$dest/extra/shared") or die $!;
    }, extra => 'conf', nodes => 'undefined-node');
    ok(!$placed, 'an import with an extra directory fails on a later step');
    is((stat("$dest/extra/shared"))[2] & 07777, 0755, 'the existing extra directory gets its own mode back');
}

for my $nodes (undef, 'undefined-node') {
    # An existing extra directory takes the attributes of the bundle as cp -a gives them on this host, ACLs too.
    my $reference = "$fixture/reference-" . ($sequence + 1);
    my ($acl, @before);
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        for my $pair ([ "$bundle/extra/conf", "$dest/extra" ], [ "$reference/bundle", "$reference/dest" ]) {
            my ($from, $to) = @$pair;
            make_path("$from/shared", "$to/shared");
            write_text("$from/shared/new.conf", "file of the bundle\n");
            write_text("$to/shared/admin.conf", "file of the administrator\n");
            chmod(0750, "$from/shared") or die $!;
            chmod(0755, "$to/shared")   or die $!;
            $acl = system('setfacl', '-m', 'u:nobody:r-x,d:u:nobody:r-x', "$to/shared") == 0;
            utime(1000000000, 1000000000, "$to/shared") or die $!;
        }
        @before = (scalar(`getfacl -cp '$dest/extra/shared' 2>/dev/null`), (stat("$dest/extra/shared"))[ 2, 9 ]);
        system('cp', '-a', '-f', "$reference/bundle/shared", "$reference/dest") == 0 or die 'cannot copy the reference';
    }, extra => 'conf', (defined $nodes ? (nodes => $nodes) : ()));
    my $shared = "$dest/extra/shared";
    if (!defined $nodes) {
        is($errors, '', 'an import over an existing extra directory with an ACL reports no error');
        is((stat($shared))[2] & 07777, 0750, 'the existing extra directory takes the mode of the bundle');
      SKIP: {
            skip 'setfacl cannot set an ACL here', 1 if !$acl;
            is(`getfacl -cp '$shared'`, `getfacl -cp '$reference/dest/shared'`,
                'the existing extra directory gets the ACL that cp -a gives it on this host');
        }
    } else {
        ok(!$placed, 'an import over an existing extra directory with an ACL fails on a later step');
        ok(!-e "$shared/new.conf", 'the rollback removes the file of the bundle from the existing extra directory');
        is_deeply([ (stat($shared))[ 2, 9 ] ], [ @before[ 1, 2 ] ], 'the existing extra directory gets its own mode and time back');
      SKIP: {
            skip 'setfacl cannot set an ACL here', 1 if !$acl;
            is(`getfacl -cp '$shared'`, $before[0], 'the existing extra directory gets its own ACL back');
        }
    }
    is(read_binary("$shared/admin.conf"), "file of the administrator\n", 'the file of the administrator stays');
}

{
    # Another host publishes the image right after this import released the publication lock.
    no warnings 'redefine';
    my $publish = \&xCAT::SvrUtils::publish_rootimg;
    local *xCAT::SvrUtils::publish_rootimg = sub {
        my ($class, $staged, $target) = @_;
        my $error = $publish->(@_);
        if (!$error && $staged =~ m{/\.packimage-}) {
            write_text("$target.other", "image of another host\n");
            rename("$target.other", $target) or die $!;
        }
        return $error;
    };
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', undef, nodes => 'undefined-node');
    ok(!$placed, 'an import fails after another host published right after it');
    is(read_binary($archive), "image of another host\n", 'the image that the other host published right after the import stays');
    like($errors, qr/another publication replaced it/, 'the publication of the other host is reported as a conflict');
}

{
    # The kernel cannot move back, so the rollback must stop before it touches the older kernel.
    no warnings 'redefine';
    my $move = \&File::Copy::move;
    local *xCAT_plugin::imgport::move = sub {
        my ($from, $to) = @_;
        if ($from =~ m{/kernel\.ORIG$} && $to =~ m{/kernel$}) {
            $! = EIO;
            return 0;
        }
        return $move->(@_);
    };
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest) = @_;
        write_text("$dest/kernel.ORIG", "kernel before the published one\n");
    }, nodes => 'undefined-node');
    ok(!$placed, 'an import fails when a rollback step fails');
    like($errors, qr/Cannot move \Q$dest\E\/kernel\.ORIG back to \Q$dest\E\/kernel: .*The replaced files are kept in (\S+)\./s,
        'the step that cannot be put back is reported with the directory that keeps the replaced files');
    is(read_binary("$dest/kernel.ORIG"), "published kernel\n", 'the kernel that nodes booted before the import stays');
    my ($kept) = $errors =~ /The replaced files are kept in (\S+)\./;
    ok($kept && grep({ read_binary($_) eq "kernel before the published one\n" } glob("$kept/*")), 'the older kernel is kept');
    rmtree($kept) if $kept;
}

{
    # Another host publishes its image before this import publishes, so the rollback must put back that image.
    no warnings 'redefine';
    my $publish = \&xCAT::SvrUtils::publish_rootimg;
    local *xCAT::SvrUtils::publish_rootimg = sub {
        my ($class, $staged, $target) = @_;
        if ($staged =~ m{/\.packimage-}) {
            write_text("$target.other", "image of another host\n");
            rename("$target.other", $target) or die $!;
            write_text("$target.sha256", sha256_hex("image of another host\n") . "  rootimg.cpio.gz\n");
        }
        return $publish->(@_);
    };
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', undef, nodes => 'undefined-node');
    ok(!$placed, 'an import fails after another host published before it');
    is(read_binary($archive), "image of another host\n", 'the rollback puts back the image that was published before this import');
    is(read_binary("$archive.sha256"), sha256_hex("image of another host\n") . "  rootimg.cpio.gz\n", 'the rollback puts back the checksum of that image');
}

{
    # Another writer changes a shared kit row while the import runs, so the rollback must leave that row.
    xCAT::Table->new('kit', -create => 1)->setAttribs({ kitname => 'sharedkit' }, { description => 'kit before the import' });
    no warnings 'redefine';
    local *xCAT_plugin::imgport::set_postscripts = sub {
        xCAT::Table->new('kit')->setAttribs({ kitname => 'sharedkit' }, { description => 'kit of another import' });
        return 0;
    };
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', undef, kit => 'sharedkit', nodes => 'n1');
    ok(!$placed, 'an import fails after another writer changed its kit row');
    my ($row) = xCAT::Table->new('kit')->getAttribs({ kitname => 'sharedkit' }, 'description');
    is($row->{description}, 'kit of another import', 'the kit row of the other writer stays');
    like($errors, qr/Cannot put back the kit row kitname=sharedkit, which was description=kit before the import: another change replaced it/,
        'the kit row that cannot be put back is reported with its previous values');
    is(definition($dest), 'rhels9.5', 'the rollback goes on and puts back the image definition');
    is(read_binary($archive), $published, 'the rollback goes on and puts back the published image');
}

{
    # The database refuses the write that puts back the image definition.
    our $ROLLING;
    no warnings 'redefine';
    my $update = \&xCAT::Table::setAttribsWhere;
    local *xCAT::Table::setAttribsWhere = sub {
        return (undef, 'database is read-only') if $ROLLING && $_[0]->{tabname} eq 'osimage';
        return $update->(@_);
    };
    local *xCAT_plugin::imgport::set_postscripts = sub { $ROLLING = 1; return 0 };
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', undef, nodes => 'n1');
    $ROLLING = 0;
    ok(!$placed, 'an import fails when its image definition cannot be put back');
    like($errors, qr/Cannot put back the osimage row imagename=import-\d+, which was .*osvers=rhels9\.5.*: database is read-only/,
        'the row that cannot be put back is reported with its previous values');
    is(definition($dest), 'rhels9.6', 'the image definition is not lost when the database refuses to put it back');
    is(read_binary($archive), $published, 'the rollback goes on and puts back the published image');
}

for my $method (qw(new setAttribsWhere)) {
    # The database throws while the rollback puts back the image definition.
    our $THROWING;
    no warnings 'redefine';
    no strict 'refs';
    my $original = \&{"xCAT::Table::$method"};
    local *{"xCAT::Table::$method"} = sub {
        die "lost the database connection\n" if $THROWING && ($method eq 'new' ? $_[1] : $_[0]->{tabname}) eq 'osimage';
        return $original->(@_);
    };
    local *xCAT_plugin::imgport::set_postscripts = sub { $THROWING = 1; return 0 };
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', undef, nodes => 'n1');
    $THROWING = 0;
    ok(!$placed, "$method throws during the rollback: the import fails");
    like($errors, qr/Cannot put back the osimage row imagename=import-\d+, which was .*osvers=rhels9\.5.*: lost the database connection/,
        "$method throws during the rollback: the row is reported with its previous values");
    is(read_binary($archive), $published, "$method throws during the rollback: the published image comes back");
    is(read_binary("$dest/kernel"), "published kernel\n", "$method throws during the rollback: the published kernel comes back");
}

{
    # publish_rootimg dies while the rollback publishes the previous image again.
    our $THROWING;
    no warnings 'redefine';
    my $publish = \&xCAT::SvrUtils::publish_rootimg;
    local *xCAT::SvrUtils::publish_rootimg = sub { die "the disk is gone\n" if $THROWING; return $publish->(@_) };
    local *xCAT_plugin::imgport::set_postscripts = sub { $THROWING = 1; return 0 };
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', undef, nodes => 'n1');
    $THROWING = 0;
    ok(!$placed, 'an import fails when the rollback cannot publish the previous image');
    like($errors, qr/Cannot put back \Q$archive\E: the disk is gone\. The previous image is kept in \Q$dest\E\/\.rootimg-previous-/,
        'the rollback reports the directory that keeps the previous image');
    my ($kept) = $errors =~ /The replaced files are kept in (\S+)\./;
    rmtree($kept) if $kept;
}

{
    # A step of the rollback dies, so the rollback stops and reports where the replaced files are.
    our $THROWING;
    no warnings 'redefine';
    my $move = \&xCAT_plugin::imgport::move;
    local *xCAT_plugin::imgport::move = sub { die "the disk is gone\n" if $THROWING; return $move->(@_) };
    local *xCAT_plugin::imgport::set_postscripts = sub { $THROWING = 1; return 0 };
    my ($placed, $errors) = import_image('rootimg.cpio.gz', undef, nodes => 'n1');
    $THROWING = 0;
    ok(!$placed, 'an import fails when a step of its rollback dies');
    like($errors, qr/The rollback failed: the disk is gone.*The replaced files are kept in /s, 'the step that died is reported');
    my ($kept) = $errors =~ /The replaced files are kept in (\S+)\./;
    rmtree($kept) if $kept;
}

for my $column (qw(version description)) {
    # Another writer changes a kit row that the import created, right before the rollback deletes it.
    my $kit = "racing$column";
    my $changed;
    my $change = sub {
        my ($table) = @_;
        return if $changed || $table->{tabname} ne 'kit';
        $changed = 1;
        xCAT::Table->new('kit')->setAttribs({ kitname => $kit }, { $column => 'changed by another writer' });
    };
    no warnings 'redefine';
    my $delete       = \&xCAT::Table::delEntries;
    my $delete_where = \&xCAT::Table::delEntriesWhere;
    local *xCAT::Table::delEntries      = sub { $change->(@_); return $delete->(@_) };
    local *xCAT::Table::delEntriesWhere = sub { $change->(@_); return $delete_where->(@_) };
    my ($placed, $errors) = import_image('rootimg.cpio.gz', undef, kit => $kit, nodes => 'undefined-node');
    ok($changed, "$column: another writer changes the kit row before the rollback deletes it");
    my ($row) = xCAT::Table->new('kit')->getAttribs({ kitname => $kit }, $column);
    is($row && $row->{$column}, 'changed by another writer', "$column: the change of the other writer stays");
    like($errors, qr/Cannot put back the kit row kitname=\Q$kit\E, which was none: another change replaced it/,
        "$column: the kit row is reported");
}

{
    # A read of the kit table fails before the import writes a kit row that existed before.
    xCAT::Table->new('kit', -create => 1)->setAttribs({ kitname => 'readkit' }, { description => 'kit before the import' });
    my $failed;
    no warnings 'redefine';
    my $read     = \&xCAT::Table::getEntriesWhere;
    my $read_all = \&xCAT::Table::getAllEntries;
    local *xCAT::Table::getEntriesWhere = sub {
        return (undef, 'database is busy') if $_[0]->{tabname} eq 'kit' && !$failed++;
        return $read->(@_);
    };
    local *xCAT::Table::getAllEntries = sub {
        return undef if $_[0]->{tabname} eq 'kit' && !$failed++;
        return $read_all->(@_);
    };
    my ($placed, $errors) = import_image('rootimg.cpio.gz', undef, kit => 'readkit', nodes => 'undefined-node');
    ok(!$placed, 'an import fails when it cannot read a row before it writes it');
    like($errors, qr/Cannot write the kit row kitname=readkit: Cannot read the kit table: database is busy/, 'the failed read is reported');
    my ($row) = xCAT::Table->new('kit')->getAttribs({ kitname => 'readkit' }, 'description');
    is($row && $row->{description}, 'kit before the import', 'the kit row that existed before stays');
}

{
    # The database refuses the commit that puts back the image definition.
    our $ROLLING;
    no warnings 'redefine';
    my $commit = \&xCAT::Table::commit;
    local *xCAT::Table::commit = sub {
        return (undef, 'database or disk is full') if $ROLLING && $_[0]->{tabname} eq 'osimage';
        return $commit->(@_);
    };
    local *xCAT_plugin::imgport::set_postscripts = sub { $ROLLING = 1; return 0 };
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', undef, nodes => 'n1');
    $ROLLING = 0;
    ok(!$placed, 'an import fails when the database refuses the commit of its rollback');
    like($errors, qr/Cannot put back the osimage row imagename=import-\d+, which was .*: the database refuses the commit: database or disk is full/,
        'the refused commit of the rollback is reported with the previous values');
    is(read_binary($archive), $published, 'the rollback goes on and puts back the published image after a refused commit');
}

{
    # MySQL takes a backslash in a literal as an escape, so the rollback binds the values that the import wrote.
    my $odd = q{kit \' OR 1=1 -- with a backslash \\};
    xCAT::Table->new('kit', -create => 1)->setAttribs({ kitname => 'unrelatedkit' }, { description => 'kit of another import' });
    my $dbh = xCAT::Table->new('kit', -create => 1)->{dbh};
    my @statements;
    my $callbacks = $dbh->{Callbacks};
    $dbh->{Callbacks} = { prepare => sub { push @statements, $_[1]; return } };
    my ($placed, $errors) = import_image('rootimg.cpio.gz', undef, kit => 'boundkit', kitdescription => $odd, nodes => 'undefined-node');
    $dbh->{Callbacks} = $callbacks;
    ok(!$placed, 'an import of a kit with a quote and a backslash fails on a later step');
    unlike($errors, qr/Cannot put back/, 'the rollback removes the kit row with a quote and a backslash');
    my ($row) = xCAT::Table->new('kit')->getAttribs({ kitname => 'boundkit' }, 'description');
    ok(!$row, 'the kit row of the import goes away');
    ($row) = xCAT::Table->new('kit')->getAttribs({ kitname => 'unrelatedkit' }, 'description');
    is($row && $row->{description}, 'kit of another import', 'an unrelated kit row stays');
    is_deeply([ grep { index($_, 'OR 1=1') >= 0 } @statements ], [], 'no statement carries the imported value as a literal');
}

for my $case ([ osimage => 'changes the image definition' ], [ kit => 'creates the kit row' ]) {
    # Another request writes a row right after the import read it, and before the import writes it.
    my ($tabname, $how) = @$case;
    my ($armed, $raced);
    no warnings 'redefine';
    my $read = \&xCAT::Table::getEntriesWhere;
    local *xCAT::Table::getEntriesWhere = sub {
        my @result = $read->(@_);
        if ($armed && !$raced && $_[0]->{tabname} eq $tabname) {
            $raced = 1;
            my ($name) = $tabname eq 'osimage' ? ($_[2]) : ('racekit');
            xCAT::Table->new($tabname, -create => 1)->setAttribs($tabname eq 'osimage' ? ({ imagename => $name }, { osvers => 'changed by another request' })
                                                                                     : ({ kitname => 'racekit' }, { description => 'kit of another request' }));
        }
        return @result;
    };
    my $make_files = \&xCAT_plugin::imgport::make_files;
    local *xCAT_plugin::imgport::make_files = sub { my $made = $make_files->(@_); $armed = 1; return $made };
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', undef, kit => 'racekit', nodes => 'undefined-node');
    ok($raced, "another request $how between the read and the write of the import");
    ok(!$placed, "an import fails when another request $how during the import");
    if ($tabname eq 'osimage') {
        like($errors, qr/another request changed the row during the import/, 'the change of the other request is reported');
        is(definition($dest), 'changed by another request', 'the image definition of the other request stays');
    } else {
        like($errors, qr/another request created the row during the import/, 'the row of the other request is reported');
        my ($row) = xCAT::Table->new('kit')->getAttribs({ kitname => 'racekit' }, 'description');
        is($row && $row->{description}, 'kit of another request', 'the kit row of the other request stays');
        xCAT::Table->new('kit')->delEntries({ kitname => 'racekit' });
    }
}

for my $nodes (undef, 'undefined-node') {
    # The published archive is a relative symlink to a release, and a rollback must put the symlink back.
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', sub {
        my ($dest) = @_;
        make_path("$dest/releases");
        rename("$dest/rootimg.cpio.gz", "$dest/releases/v1.gz") or die $!;
        symlink('releases/v1.gz', "$dest/rootimg.cpio.gz") or die $!;
    }, (defined $nodes ? (nodes => $nodes) : ()));
    is(read_binary("$dest/releases/v1.gz"), $published, 'the release that the symlink pointed to stays');
    if (!defined $nodes) {
        is($errors, '', 'an import over a symlinked archive reports no error');
        ok(!-l $archive, 'the import publishes its archive in place of the symlink');
    } else {
        ok(!$placed, 'an import over a symlinked archive fails on a later step');
        unlike($errors, qr/Cannot put back/, 'the rollback puts back the symlinked archive');
        is(readlink($archive), 'releases/v1.gz', 'the symlink comes back with its relative target');
        is(read_binary($archive), $published, 'the symlink resolves to the release again');
        is(read_binary("$archive.sha256"), sha256_hex($published) . "  rootimg.cpio.gz\n", 'the checksum of the release comes back');
    }
}

{
    # Another request writes a postscripts row between those of two nodes, and the import then fails. On SQLite
    # the write of the other request joins the transaction of the import.
    my $dbh = xCAT::Table->new('postscripts', -create => 1)->{dbh};
    $dbh->do("CREATE TRIGGER refuse_$_ BEFORE $_ ON postscripts WHEN NEW.node = 'psnode2' BEGIN SELECT RAISE(ABORT, 'database or disk is full'); END")
      or die $dbh->errstr foreach qw(INSERT UPDATE);
    my $interleaved;
    no warnings 'redefine';
    my %original = (insertEntry => \&xCAT::Table::insertEntry, setAttribsWhere => \&xCAT::Table::setAttribsWhere);
    my $interleave = sub {
        my ($method, @args) = @_;
        my @result = $original{$method}->(@args);
        if (!$interleaved && $args[0]->{tabname} eq 'postscripts') {
            $interleaved = 1;
            xCAT::Table->new('postscripts')->setAttribs({ node => 'othernode' }, { postscripts => 'written by another request' });
        }
        return @result;
    };
    local *xCAT::Table::insertEntry     = sub { return $interleave->('insertEntry', @_) };
    local *xCAT::Table::setAttribsWhere = sub { return $interleave->('setAttribsWhere', @_) };
    my ($placed, $errors) = import_image('rootimg.cpio.gz', undef, postscripts => 'interleaved-script', nodes => 'psnode,psnode2');
    $dbh->do("DROP TRIGGER refuse_$_") or die $dbh->errstr foreach qw(INSERT UPDATE);
    ok($interleaved, 'another request writes between the postscripts rows of two nodes');
    ok(!$placed, 'the import fails on the postscripts row of the second node');
    my ($row) = xCAT::Table->new('postscripts')->getAttribs({ node => 'othernode' }, 'postscripts');
    is($row && $row->{postscripts}, 'written by another request', 'the write of the other request stays');
    ($row) = xCAT::Table->new('postscripts')->getAttribs({ node => 'psnode' }, 'postscripts');
    unlike($row ? $row->{postscripts} // '' : '', qr/interleaved-script/, 'the postscripts row of the first node goes back');
}

{
    # Reading the previous kernel fails right after the import moved it to kernel.ORIG.
    my $failed;
    no warnings 'redefine';
    my $identity = \&xCAT_plugin::imgport::txn_identity;
    local *xCAT_plugin::imgport::txn_identity = sub {
        die "cannot read $_[0]\n" if $_[0] =~ /\/kernel\.ORIG\z/ && !$failed++;
        return $identity->(@_);
    };
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest) = @_;
        write_text("$dest/kernel.ORIG", "kernel before the published one\n");
    });
    ok($failed, 'reading the moved kernel fails');
    ok(!$placed, 'an import fails when it cannot read a file that it moved');
    unlike($errors, qr/Cannot put back/, 'the rollback puts back the moved file');
    is(read_binary("$dest/kernel"), "published kernel\n", 'the published kernel comes back from kernel.ORIG');
    is(read_binary("$dest/kernel.ORIG"), "kernel before the published one\n", 'the previous kernel.ORIG comes back');
}

for my $case ([ setAttribsWhere => 'osimage' ], [ insertEntry => 'linuximage' ], [ insertEntry => 'postscripts' ]) {
    # The database applies a write, and the notification that follows it dies.
    my ($method, $tabname) = @$case;
    my ($armed, $died);
    no warnings 'redefine';
    no strict 'refs';
    my $original = \&{"xCAT::Table::$method"};
    local *{"xCAT::Table::$method"} = sub {
        my @result = $original->(@_);
        if ($armed && !$died && $_[0]->{tabname} eq $tabname) {
            $died = 1;
            die "the notification of the write failed\n";
        }
        return @result;
    };
    my $make_files = \&xCAT_plugin::imgport::make_files;
    local *xCAT_plugin::imgport::make_files = sub { my $made = $make_files->(@_); $armed = 1; return $made };
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', undef, rootimgchecksum => 'no', postscripts => 'notified-script',
        ($tabname eq 'postscripts' ? (nodes => 'psnode2') : ()));
    my ($name) = $dest =~ m{/(import-\d+)$};
    ok($died, "$method of $tabname dies after the write");
    ok(!$placed, "$method of $tabname: the import fails");
    unlike($errors, qr/Cannot put back/, "$method of $tabname: the rollback puts back the write that applied");
    is(definition($dest), 'rhels9.5', "$method of $tabname: the image definition comes back");
    my ($row) = xCAT::Table->new('linuximage', -create => 1)->getAttribs({ imagename => $name }, 'rootimgchecksum');
    ok(!$row, "$method of $tabname: the linuximage row of the import goes away");
    ($row) = xCAT::Table->new('postscripts', -create => 1)->getAttribs({ node => 'psnode2' }, 'postscripts');
    unlike($row ? $row->{postscripts} // '' : '', qr/notified-script/, "$method of $tabname: the postscripts of the node go back");
}

{
    # The database applies the insert of the linuximage row, and its answer is lost.
    my ($armed, $lost);
    no warnings 'redefine';
    my $insert = \&xCAT::Table::insertEntry;
    local *xCAT::Table::insertEntry = sub {
        my @result = $insert->(@_);
        return @result if !$armed || $lost || $_[0]->{tabname} ne 'linuximage';
        $lost = 1;
        return;
    };
    my $make_files = \&xCAT_plugin::imgport::make_files;
    local *xCAT_plugin::imgport::make_files = sub { my $made = $make_files->(@_); $armed = 1; return $made };
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', undef, rootimgchecksum => 'no');
    my ($name) = $dest =~ m{/(import-\d+)$};
    ok($lost, 'the answer of an applied insert is lost');
    ok(!$placed, 'an import fails when the answer of an insert is lost');
    like($errors, qr/Cannot write the linuximage row imagename=import-\d+: the database did not answer/, 'the lost answer is reported');
    my ($row) = xCAT::Table->new('linuximage', -create => 1)->getAttribs({ imagename => $name }, 'rootimgchecksum');
    ok(!$row, 'the rollback removes the row that the insert applied');
    is(definition($dest), 'rhels9.5', 'the image definition comes back after a lost answer');
}

for my $held (0, 1) {
    # The image directory is missing, so the import creates it, and a rollback removes it again.
    local $HELD = $held;
    my $dir    = "$fixture/install/netboot/missing-$held/x86_64/compute";
    my $bundle = "$fixture/bundle-missing-$held";
    make_path($bundle);
    write_text("$bundle/rootimg.cpio.gz", $imported);
    my $data = {
        rootimg => "$dir/rootimg.cpio.gz",
        osimage => { imagename => "missing-$held", osvers => 'rhels9.6', osarch => 'x86_64', profile => 'compute', provmethod => 'netboot' },
    };
    my @errors;
    my $placed = xCAT_plugin::imgport::place_image($data, $bundle, sub { push @errors, @{ $_[0]{error} || [] } }, 'undefined-node');
    my $label = $held ? 'while another command holds the image lock' : 'that fails on a later step';
    ok(!$placed, "an import into a missing image directory $label fails");
    ok(!-e "$fixture/install/netboot/missing-$held", "the rollback of an import $label removes the directories that it created");
}

{
    # The file system refuses the metainfo while the rollback publishes the kept image again.
    no warnings 'redefine';
    my $fail_kept;
    local *xCAT_plugin::imgport::set_postscripts = sub {
        my ($data) = @_;
        $fail_kept = $data->{rootimg} . '.metainfo';
        $FAIL{$fail_kept} = 1;
        return 0;
    };
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', undef, nodes => 'n1');
    delete $FAIL{$fail_kept} if $fail_kept;
    ok(!$placed, 'an import fails when its rollback cannot publish the kept image again');
    my ($kept) = $errors =~ /The previous image is kept in (\S+?)\.?(?:\s|$)/;
    ok($kept, 'the rollback names the directory that keeps the previous image');
    is($kept && read_binary("$kept/rootimg.cpio.gz"), $published, 'the kept directory still holds the previous image');
    is($kept && read_binary("$kept/rootimg.cpio.gz.metainfo"), "metainfo of the published image\n", 'the kept directory still holds its metainfo');
    my ($files) = $errors =~ /The replaced files are kept in (\S+)\./;
    rmtree($files) if $files;
}

for my $kind (qw(symlink file)) {
    # The archive turns an empty directory of the tree into a $kind, and the import then fails.
    my ($acl, $xattr);
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$dest/rootimg/var/lock", "$dest/rootimg/run/target", "$bundle/tree/var");
        my $set = system('setfacl', '-m', 'u:nobody:r-x', "$dest/rootimg/var/lock") == 0;
        $xattr = system("setfattr -n user.xcat -v kept '$dest/rootimg/var/lock' 2>/dev/null") == 0;
        chmod(0700, "$dest/rootimg/var/lock") or die $!;
        $acl = `getfacl -cp '$dest/rootimg/var/lock'` if $set;
        chmod(0750, "$dest/rootimg/run/target") or die $!;
        if ($kind eq 'symlink') {
            symlink('../run/target', "$bundle/tree/var/lock") or die $!;
        } else {
            write_text("$bundle/tree/var/lock", "a file in place of a directory\n");
        }
        system("cd '$bundle/tree' && find . | cpio -H newc -o 2>/dev/null | gzip > '$bundle/rootimgtree.gz'") == 0 or die 'cannot pack the tree';
    }, rootimgtree => 'DEST/rootimg/rootimgtree.gz', nodes => 'undefined-node');
    ok(!$placed, "a statelite import that turns a directory into a $kind fails on a later step");
    unlike($errors, qr/cannot put back/i, "the rollback puts back the directory that became a $kind");
    ok(-d "$dest/rootimg/var/lock" && !-l "$dest/rootimg/var/lock", "the $kind goes, and the directory comes back");
    is((stat("$dest/rootimg/var/lock"))[2] & 07777, 0700, "the directory that became a $kind gets its own mode back");
  SKIP: {
        skip 'setfacl cannot set an ACL here', 1 if !defined $acl;
        is(`getfacl -cp '$dest/rootimg/var/lock'`, $acl, "the directory that became a $kind gets its own ACL back");
    }
  SKIP: {
        skip 'setfattr cannot set an extended attribute here', 1 if !$xattr;
        is(`getfattr --only-values -n user.xcat '$dest/rootimg/var/lock' 2>/dev/null`, 'kept',
            "the directory that became a $kind gets its own extended attribute back");
    }
    is((stat("$dest/rootimg/run/target"))[2] & 07777, 0750, 'the rollback leaves the target of the symlink as it was');
}

for my $writer (0, 1) {
    # The archive turns a file of the tree into a directory with an entry, and the import then fails. Another
    # writer can add a file to that directory first.
    my $foreign;
    no warnings 'redefine';
    local *xCAT_plugin::imgport::set_postscripts = sub {
        write_text($foreign, "file of another writer\n") if $writer;
        return 0;
    };
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        $foreign = "$dest/rootimg/etc/motd/another";
        make_path("$dest/rootimg/etc", "$bundle/tree/etc/motd");
        write_text("$dest/rootimg/etc/motd", "file of the image\n");
        write_text("$bundle/tree/etc/motd/entry", "entry of the bundle\n");
        system("cd '$bundle/tree' && find . | cpio -H newc -o 2>/dev/null | gzip > '$bundle/rootimgtree.gz'") == 0 or die 'cannot pack the tree';
    }, rootimgtree => 'DEST/rootimg/rootimgtree.gz', nodes => 'n1');
    my $motd = "$dest/rootimg/etc/motd";
    ok(!$placed, 'a statelite import that turns a file into a directory fails on a later step');
    ok(!-e "$motd/entry", 'the rollback removes the entry of the bundle');
    if (!$writer) {
        unlike($errors, qr/cannot put back/i, 'the rollback puts back the file that became a directory');
        is(-f $motd ? read_binary($motd) : undef, "file of the image\n", 'the file comes back in place of the directory');
        next;
    }
    like($errors, qr{Cannot put back \Q$motd\E: }, 'the rollback reports the directory that has a file of another writer');
    is(-e $foreign ? read_binary($foreign) : undef, "file of another writer\n", 'the file of the other writer stays');
    my ($files) = $errors =~ /The replaced files are kept in (\S+)\./;
    ok($files && grep({ -f $_ && read_binary($_) eq "file of the image\n" } glob("$files/*")), 'the replaced file stays kept');
    rmtree($files) if $files;
}

{
    # The archive lists the entries of a new directory before the directory, as find -depth does.
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$dest/rootimg", "$bundle/tree/opt/new/sub");
        write_text("$bundle/tree/opt/new/sub/file", "entry of the bundle\n");
        system("cd '$bundle/tree' && find . -depth | cpio -H newc -o 2>/dev/null | gzip > '$bundle/rootimgtree.gz'") == 0 or die 'cannot pack the tree';
    }, rootimgtree => 'DEST/rootimg/rootimgtree.gz', nodes => 'undefined-node');
    ok(!$placed, 'a statelite import of a tree that lists entries before their directory fails on a later step');
    unlike($errors, qr/cannot (?:put back|remove)/i, 'the rollback removes the entries before their directory');
    ok(!-e "$dest/rootimg/opt", 'the rollback removes the directories that the import made');
}

{
    # A bundle with a kit takes the lock of the kit commands, which write the same kit files and postscripts.
    import_image('rootimg.cpio.gz', undef, kit => 'lockkit');
    ok(scalar(grep { $_ eq 'kit' } @LOCKED), 'an import of a kit takes the lock of the kit commands');
    import_image('rootimg.cpio.gz');
    ok(!grep({ $_ eq 'kit' } @LOCKED), 'an import without a kit leaves the lock of the kit commands');
}

for my $nodes (undef, 'undefined-node') {
    # Files of an extra tree are hard links of each other, across entries that merge into an existing directory.
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/extra/conf/sub", "$dest/extra");
        write_text("$bundle/extra/conf/one", "linked content\n");
        link("$bundle/extra/conf/one", "$bundle/extra/conf/two") or die $!;
        link("$bundle/extra/conf/one", "$bundle/extra/conf/sub/three") or die $!;
    }, extra => 'conf', (defined $nodes ? (nodes => $nodes) : ()));
    if (!defined $nodes) {
        is($errors, '', 'an import of hard-linked extra files reports no error');
        my @inodes = map { (stat("$dest/extra/$_"))[1] } qw(one two sub/three);
        is($inodes[1], $inodes[0], 'hard-linked sibling files stay one file');
        is($inodes[2], $inodes[0], 'a hard link in a new subdirectory stays the same file');
    } else {
        ok(!$placed, 'an import of hard-linked extra files fails on a later step');
        unlike($errors, qr/cannot put back/i, 'the rollback removes the hard-linked extra files');
        is_deeply([ grep { -e "$dest/extra/$_" } qw(one two sub) ], [], 'no hard-linked extra file stays');
    }
}

{
    # Another writer replaces a file that the import installed, so the rollback must leave it and stop.
    no warnings 'redefine';
    local *xCAT_plugin::imgport::set_postscripts = sub {
        my ($data) = @_;
        my $shared = "$data->{extra}{dest}/shared.conf";
        write_text("$shared.other", "file of another writer\n");
        rename("$shared.other", $shared) or die $!;
        return 0;
    };
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/extra", "$dest/extra");
        write_text("$bundle/extra/shared.conf", "file of this import\n");
        write_text("$dest/extra/shared.conf", "file before the import\n");
    }, extra => 'shared.conf', nodes => 'n1');
    ok(!$placed, 'an import fails after another writer replaced a file that it installed');
    is(read_binary("$dest/extra/shared.conf"), "file of another writer\n", 'the file of the other writer stays');
    like($errors, qr/Cannot put back \Q$dest\E\/extra\/shared\.conf: another change replaced it.*kept in (\S+)\./s,
        'the conflict is reported with the directory that keeps the replaced files');
    my ($kept) = $errors =~ /kept in (\S+)\./;
    rmtree($kept) if $kept;
}

{
    # Another writer changes a file that the import installed in place, with the same size and time.
    no warnings 'redefine';
    local *xCAT_plugin::imgport::set_postscripts = sub {
        my ($data) = @_;
        my $shared = "$data->{extra}{dest}/shared.conf";
        my @stat = stat($shared);
        open(my $file, '+<', $shared) or die $!;
        print $file 'F';
        close($file);
        utime($stat[8], $stat[9], $shared) or die $!;
        return 0;
    };
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/extra", "$dest/extra");
        write_text("$bundle/extra/shared.conf", "file of this import\n");
        write_text("$dest/extra/shared.conf", "file before the import\n");
    }, extra => 'shared.conf', nodes => 'n1');
    ok(!$placed, 'an import fails after another writer changed a file that it installed in place');
    is(read_binary("$dest/extra/shared.conf"), "File of this import\n", 'the change of the other writer stays');
    like($errors, qr/Cannot put back \Q$dest\E\/extra\/shared\.conf: another change replaced it/, 'the change in place is reported');
    my ($kept) = $errors =~ /kept in (\S+)\./;
    rmtree($kept) if $kept;
}

{
    # The administrator changes a field that the import does not write, so the rollback must keep it.
    no warnings 'redefine';
    local *xCAT_plugin::imgport::set_postscripts = sub {
        my ($data) = @_;
        xCAT::Table->new('osimage')->setAttribs({ imagename => $data->{osimage}{imagename} }, { description => 'set by the administrator' });
        return 0;
    };
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', undef, nodes => 'n1');
    ok(!$placed, 'an import fails after the administrator changed another field of its image definition');
    is(definition($dest), 'rhels9.5', 'the field that the import wrote goes back');
    my ($name) = $dest =~ m{/(import-\d+)$};
    my ($row) = xCAT::Table->new('osimage')->getAttribs({ imagename => $name }, 'description');
    is($row->{description}, 'set by the administrator', 'the field that the administrator changed stays');
}

{
    # The import creates a kit row, and another writer adds to it, so the rollback must leave the row.
    xCAT::Table->new('kit', -create => 1)->delEntries({ kitname => 'newkit' });
    no warnings 'redefine';
    local *xCAT_plugin::imgport::set_postscripts = sub {
        xCAT::Table->new('kit')->setAttribs({ kitname => 'newkit' }, { version => '2' });
        return 0;
    };
    my ($placed, $errors) = import_image('rootimg.cpio.gz', undef, kit => 'newkit', nodes => 'n1');
    ok(!$placed, 'an import fails after another writer added to a kit row that it created');
    my ($row) = xCAT::Table->new('kit')->getAttribs({ kitname => 'newkit' }, 'version');
    is($row && $row->{version}, '2', 'the kit row with the addition stays');
    like($errors, qr/Cannot put back the kit row kitname=newkit, which was none: another change replaced it/, 'the kit row is reported');
}

{
    # A statelite import extracts its rootimgtree, then fails, so the tree and the boot files come back.
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$dest/rootimg/etc", "$bundle/tree/etc");
        write_text("$dest/rootimg/etc/hostname", "old\n");
        write_text("$dest/rootimg/etc/old-only", "only in the old tree\n");
        write_text("$bundle/tree/etc/hostname", "new\n");
        write_text("$bundle/tree/etc/new-only", "only in the new tree\n");
        make_path("$bundle/tree/opt/new/sub");
        write_text("$bundle/tree/opt/new/sub/file", "in a new subtree\n");
        system("cd '$bundle/tree' && find . | cpio -H newc -o 2>/dev/null | gzip > '$bundle/rootimgtree.gz'") == 0 or die 'cannot pack the tree';
    }, rootimgtree => 'DEST/rootimg/rootimgtree.gz', nodes => 'undefined-node');
    ok(!$placed, 'a statelite import fails after it extracted its rootimgtree');
    unlike($errors, qr/cannot put back/i, 'the rollback puts back everything');
    is(read_binary("$dest/rootimg/etc/hostname"), "old\n", 'a file that the extraction replaced comes back');
    ok(!-e "$dest/rootimg/etc/new-only", 'a file that the extraction created goes away');
    ok(!-e "$dest/rootimg/opt", 'a subtree that the extraction created goes away');
    is(read_binary("$dest/rootimg/etc/old-only"), "only in the old tree\n", 'a file outside the archive stays');
    ok(!-e "$dest/rootimg/rootimgtree.gz", 'the archive of the tree goes back to the bundle');
    is(read_binary("$dest/kernel"), "published kernel\n", 'the kernel comes back with the tree');
}

{
    # cpio gives existing directories the mode and times of the archive, so a rollback puts back their own.
    my $before = 978307200;
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$dest/rootimg/etc", "$bundle/tree/etc");
        write_text("$dest/rootimg/etc/hostname", "old\n");
        write_text("$bundle/tree/etc/hostname", "new\n");
        chmod(0755, "$bundle/tree", "$bundle/tree/etc") or die $!;
        system("cd '$bundle/tree' && find . | cpio -H newc -o 2>/dev/null | gzip > '$bundle/rootimgtree.gz'") == 0 or die 'cannot pack the tree';
        chmod(0700, "$dest/rootimg/etc") or die $!;
        chmod(0750, "$dest/rootimg") or die $!;
        utime($before, $before, "$dest/rootimg/etc") or die $!;
    }, rootimgtree => 'DEST/rootimg/rootimgtree.gz', nodes => 'undefined-node');
    ok(!$placed, 'a statelite import fails after it extracted over existing directories');
    unlike($errors, qr/cannot put back/i, 'the rollback puts back the existing directories');
    is((stat("$dest/rootimg/etc"))[2] & 07777, 0700, 'an existing directory of the tree gets its own mode back');
    is((stat("$dest/rootimg/etc"))[9], $before, 'an existing directory of the tree gets its own time back');
    is((stat("$dest/rootimg"))[2] & 07777, 0750, 'the directory of the tree gets its own mode back');
}

for my $case ([ setAttribsWhere => 'returns an error', 'osimage' ], [ setAttribsWhere => 'does not answer', 'osimage' ],
    [ insertEntry => 'does not answer', 'linuximage' ], [ commit => 'dies', 'osimage' ], [ commit => 'returns an error', 'osimage' ])
{
    # The database refuses a write of the image definition, so the import fails and puts back the files.
    my ($method, $how, $tabname) = @$case;
    my $armed;
    no warnings 'redefine';
    no strict 'refs';
    my $original = \&{"xCAT::Table::$method"};
    local *{"xCAT::Table::$method"} = sub {
        my ($table) = @_;
        return $original->(@_) if !$armed || $table->{tabname} ne $tabname;
        $armed = 0;
        return (undef, 'database or disk is full') if $how eq 'returns an error';
        return if $how eq 'does not answer';
        die "database or disk is full\n";
    };
    my $make_files = \&xCAT_plugin::imgport::make_files;
    local *xCAT_plugin::imgport::make_files = sub { my $made = $make_files->(@_); $armed = 1; return $made };
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', undef, rootimgchecksum => 'no');
    my $label = "$method $how";
    my $refusal = $how eq 'does not answer' ? 'the database did not answer' : 'database or disk is full';
    ok(!$placed, "$label: the import fails");
    like($errors, qr/Cannot write the $tabname row imagename=import-\d+: .*\Q$refusal\E/, "$label: the refused write is reported");
    unlike($errors, qr/Cannot put back/, "$label: the rollback puts back everything");
    is(definition($dest), 'rhels9.5', "$label: the image definition stays as it was");
    is(read_binary($archive), $published, "$label: the published image comes back");
    is(read_binary("$dest/kernel"), "published kernel\n", "$label: the published kernel comes back");
}

{
    # The database refuses the postscripts row of the second node, so the import fails and writes none of them.
    my $dbh = xCAT::Table->new('postscripts', -create => 1)->{dbh};
    $dbh->do("CREATE TRIGGER refuse_$_ BEFORE $_ ON postscripts WHEN NEW.node = 'psnode2' BEGIN SELECT RAISE(ABORT, 'database or disk is full'); END")
      or die $dbh->errstr foreach qw(INSERT UPDATE);
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', undef, postscripts => 'imported-script', nodes => 'psnode,psnode2');
    $dbh->do("DROP TRIGGER refuse_$_") or die $dbh->errstr foreach qw(INSERT UPDATE);
    ok(!$placed, 'an import fails when the database refuses the postscripts of a node');
    like($errors, qr/Cannot write the postscripts of psnode,psnode2: .*database or disk is full/, 'the refused postscripts are reported');
    my ($row) = xCAT::Table->new('postscripts', -create => 1)->getAttribs({ node => 'psnode' }, 'postscripts');
    unlike($row ? $row->{postscripts} // '' : '', qr/imported-script/, 'the postscripts of the node that the database accepted are not kept');
    is(definition($dest), 'rhels9.5', 'the image definition comes back after the refused postscripts');
    is(read_binary($archive), $published, 'the published image comes back after the refused postscripts');
}

{
    my ($placed, $errors) = import_image('rootimg.cpio.gz', undef, postscripts => 'imported-script', nodes => 'psnode');
    is($errors, '', 'an import writes the postscripts of its nodes');
    my ($row) = xCAT::Table->new('postscripts', -create => 1)->getAttribs({ node => 'psnode' }, 'postscripts');
    is($row && $row->{postscripts}, 'imported-script', 'the node gets the postscripts of the image');
}

{
    # Another writer adds a file to a directory that the import created, so the rollback must leave both.
    no warnings 'redefine';
    local *xCAT_plugin::imgport::set_postscripts = sub {
        my ($data) = @_;
        write_text("$data->{extra}{dest}/added-by-the-administrator", "kept\n");
        return 0;
    };
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/extra/conf");
        write_text("$bundle/extra/conf/imported", "imported\n");
    }, extra => 'conf', nodes => 'n1');
    ok(!$placed, 'an import fails after another writer added to a directory that it created');
    is(read_binary("$dest/extra/added-by-the-administrator"), "kept\n", 'the file of the other writer stays');
    ok(!-e "$dest/extra/imported", 'the file of the import goes away');
    like($errors, qr/Cannot remove \Q$dest\E\/extra: /, 'the directory that cannot be removed is reported');
    my ($kept) = $errors =~ /kept in (\S+)\./;
    rmtree($kept) if $kept;
}

{
    # A disabled kit row exists before the import, which getAttribs does not show.
    xCAT::Table->new('kit', -create => 1)->setAttribs({ kitname => 'disabledkit' }, { description => 'kit before the import', disable => '1' });
    my ($placed) = import_image('rootimg.cpio.gz', undef, kit => 'disabledkit', nodes => 'undefined-node');
    ok(!$placed, 'an import fails after it changed a disabled kit row');
    my ($row) = grep { $_->{kitname} eq 'disabledkit' } @{ xCAT::Table->new('kit')->getAllEntries('all') };
    is($row && $row->{description}, 'kit before the import', 'the disabled kit row comes back');
    is($row && $row->{disable}, '1', 'the kit row stays disabled');
}

for my $nodes (undef, 'undefined-node') {
    # An extra tree with two new directory levels and hard-linked files.
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/extra/conf/deep/er", "$dest/extra");
        write_text("$bundle/extra/conf/deep/er/one", "linked content\n");
        link("$bundle/extra/conf/deep/er/one", "$bundle/extra/conf/deep/er/two") or die $!;
        chmod(0700, "$bundle/extra/conf/deep/er") or die $!;
    }, extra => 'conf', (defined $nodes ? (nodes => $nodes) : ()));
    if (!defined $nodes) {
        is($errors, '', 'an import with a new extra tree reports no error');
        is(read_binary("$dest/extra/deep/er/$_"), "linked content\n", "the hard-linked file $_ keeps its content") for qw(one two);
        is((stat("$dest/extra/deep/er"))[2] & 07777, 0700, 'a new nested directory keeps its mode');
    } else {
        ok(!$placed, 'an import with a new extra tree fails on a later step');
        ok(!-e "$dest/extra/deep", 'the new extra tree goes away');
        ok(-d "$dest/extra", 'the extra directory that was there stays');
    }
}

{
    # cp stops at a file that it cannot read, after it copied others, so the rollback removes what it copied.
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/extra/conf/tree", "$dest/extra");
        write_text("$bundle/extra/conf/tree/$_", "$_\n") for qw(a b unreadable);
        chmod(0, "$bundle/extra/conf/tree/unreadable") or die $!;
    }, extra => 'conf');
    ok(!$placed, 'an import fails when an extra tree is copied partway');
    unlike($errors, qr/cannot put back/i, 'the rollback puts back everything after a partial copy');
    ok(!-e "$dest/extra/tree", 'the partial extra tree goes away');
    is(read_binary($archive), $published, 'the published image comes back after a partial copy');
    is(read_binary("$dest/kernel"), "published kernel\n", 'the published kernel comes back after a partial copy');
    is(definition($dest), 'rhels9.5', 'the image definition stays after a partial copy');
}

for my $nodes (undef, 'undefined-node') {
    # The extra destination is a symlink to a shared directory, which the import must keep.
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/extra/conf", "$dest/shared");
        write_text("$bundle/extra/conf/imported", "imported\n");
        write_text("$dest/shared/unrelated", "unrelated\n");
        chmod(0750, "$dest/shared") or die $!;
        symlink("$dest/shared", "$dest/extra") or die $!;
    }, extra => 'conf', (defined $nodes ? (nodes => $nodes) : ()));
    my $label = defined $nodes ? 'after a rollback' : 'after an import';
    ok(-l "$dest/extra", "$label: the symlinked extra destination stays a symlink");
    is(read_binary("$dest/shared/unrelated"), "unrelated\n", "$label: the unrelated file of the shared directory stays");
    is((stat("$dest/shared"))[2] & 07777, 0750, "$label: the shared directory keeps its mode");
    if (!defined $nodes) {
        is($errors, '', 'an import into a symlinked extra destination reports no error');
        is(read_binary("$dest/shared/imported"), "imported\n", 'the imported file reaches the shared directory');
    } else {
        ok(!$placed, 'an import into a symlinked extra destination fails on a later step');
        ok(!-e "$dest/shared/imported", 'the imported file goes away from the shared directory');
    }
}

# cp refuses these collisions, so the import fails and leaves what is at the destination.
for my $case (
    [ 'a file over a directory', qr/Cannot overwrite directory \S+\/extra\/item with non-directory/, sub {
        my ($dest, $bundle) = @_;
        write_text("$bundle/extra/conf/item", "imported\n");
        make_path("$dest/extra/item");
        write_text("$dest/extra/item/kept", "kept\n");
    } ],
    [ 'a file over a symlink to a directory', qr/Cannot overwrite directory \S+\/extra\/item with non-directory/, sub {
        my ($dest, $bundle) = @_;
        write_text("$bundle/extra/conf/item", "imported\n");
        symlink("$dest/elsewhere", "$dest/extra/item") or die $!;
    } ],
    [ 'a file over a dangling symlink', qr/Cannot write through dangling symlink \S+\/extra\/item/, sub {
        my ($dest, $bundle) = @_;
        write_text("$bundle/extra/conf/item", "imported\n");
        symlink("$dest/missing", "$dest/extra/item") or die $!;
    } ],
    [ 'a directory over a file', qr/Cannot overwrite non-directory \S+\/extra\/item with directory/, sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/extra/conf/item");
        write_text("$bundle/extra/conf/item/imported", "imported\n");
        write_text("$dest/extra/item", "kept\n");
    } ],
    [ 'a directory over a symlink to a directory', qr/Cannot overwrite non-directory \S+\/extra\/item with directory/, sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/extra/conf/item");
        write_text("$bundle/extra/conf/item/imported", "imported\n");
        symlink("$dest/elsewhere", "$dest/extra/item") or die $!;
    } ],
    [ 'a symlink over a directory', qr/Cannot overwrite directory \S+\/extra\/item with non-directory/, sub {
        my ($dest, $bundle) = @_;
        symlink('anywhere', "$bundle/extra/conf/item") or die $!;
        make_path("$dest/extra/item");
        write_text("$dest/extra/item/kept", "kept\n");
    } ],
) {
    my ($label, $refusal, $collide) = @$case;
    my $before;
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/extra/conf", "$dest/extra", "$dest/elsewhere");
        write_text("$dest/elsewhere/kept", "kept\n");
        $collide->($dest, $bundle);
        $before = tree("$dest/extra") . tree("$dest/elsewhere");
    }, extra => 'conf');
    ok(!$placed, "$label: the import fails");
    like($errors, $refusal, "$label: the import reports what cp refuses");
    is(tree("$dest/extra") . tree("$dest/elsewhere"), $before, "$label: the destination stays as it was");
    is(read_binary($archive), $published, "$label: the published image is put back");
}

for my $nodes (undef, 'undefined-node') {
    # cp writes a file through a symlink to a file, so the symlink stays.
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/extra/conf", "$dest/extra");
        write_text("$bundle/extra/conf/linked", "imported\n");
        write_text("$dest/target", "target before the import\n");
        chmod(0640, "$dest/target") or die $!;
        symlink("$dest/target", "$dest/extra/linked") or die $!;
    }, extra => 'conf', (defined $nodes ? (nodes => $nodes) : ()));
    my $label = defined $nodes ? 'after a rollback' : 'after an import';
    ok(-l "$dest/extra/linked", "$label: a symlink to a file stays a symlink");
    if (!defined $nodes) {
        is($errors, '', 'an import over a symlink to a file reports no error');
        is(read_binary("$dest/target"), "imported\n", 'the import writes the file through the symlink');
    } else {
        ok(!$placed, 'an import over a symlink to a file fails on a later step');
        is(read_binary("$dest/target"), "target before the import\n", 'the file that the symlink points to comes back');
        is((stat("$dest/target"))[2] & 07777, 0640, 'the file that the symlink points to keeps its mode');
    }
}

my $other = -d '/dev/shm' && -w _ ? tempdir(DIR => '/dev/shm', CLEANUP => 1) : undef;
for my $second ('DEST/second', $other) {
    # A bundle copies one extra directory with hard-linked files to two destinations, which stay independent.
  SKIP: {
        skip 'no second file system for an extra destination', 4 if !defined $second;
        my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
            my ($dest, $bundle) = @_;
            make_path("$bundle/extra/linked");
            write_text("$bundle/extra/linked/one", "linked file\n");
            link("$bundle/extra/linked/one", "$bundle/extra/linked/two") or die $!;
        }, extra => [ [ 'linked', 'DEST/first' ], [ 'linked', $second ] ]);
        my $label = $second eq 'DEST/second' ? 'on one file system' : 'on two file systems';
        (my $other_dest = $second) =~ s/DEST/$dest/;
        my %inode = map { ($_ => (stat($_))[1]) } map { ("$_/one", "$_/two") } ("$dest/first", $other_dest);
        is($errors, '', "$label: an import that copies one extra directory to two destinations reports no error");
        is($inode{"$dest/first/two"}, $inode{"$dest/first/one"}, "$label: the hard link stays in the first destination");
        is($inode{"$other_dest/two"}, $inode{"$other_dest/one"}, "$label: the hard link stays in the second destination");
        isnt($inode{"$other_dest/one"}, $inode{"$dest/first/one"}, "$label: the two destinations are independent copies");
    }
}

for my $foreign (0, 1) {
    # Two extra directories write the same file, and cp fails the second copy after it wrote part of the file.
    my $target = "$fixture/install/netboot/import-" . ($sequence + 1) . '/merged/conf';
    my $count  = "$fixture/cp-count-" . ($sequence + 1);
    my ($cp) = grep { -x $_ } map { "$_/cp" } split(/:/, $ENV{PATH});
    make_path("$fixture/partial-bin");
    write_text("$fixture/partial-bin/cp", qq{#!/bin/sh\nfor last; do :; done\nif [ "\$last" = "$target" ]; then\n}
          . qq{  n=\$((\$(cat '$count' 2>/dev/null || echo 0) + 1)); echo \$n > '$count'\n}
          . qq{  [ \$n -eq 2 ] && { printf partial > "\$last"; exit 1; }\nfi\nexec $cp "\$@"\n});
    chmod(0755, "$fixture/partial-bin/cp") or die $!;
    local $ENV{PATH} = "$fixture/partial-bin:$ENV{PATH}";

    # With $foreign, another writer changes the file between the two copies.
    no warnings 'redefine';
    my $writes_into = \&xCAT_plugin::imgport::txn_writes_into;
    my $copies      = 0;
    local *xCAT_plugin::imgport::txn_writes_into = sub {
        write_text($target, "written by another writer\n") if $foreign && $_[2] eq $target && ++$copies == 2;
        goto &$writes_into;
    };
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/extra/a", "$bundle/extra/b");
        write_text("$bundle/extra/$_/conf", "conf of $_\n") for qw(a b);
    }, extra => [ [ 'a', 'DEST/merged' ], [ 'b', 'DEST/merged' ] ]);
    ok(!$placed, 'an import fails when the second copy to one file fails partway');
    if (!$foreign) {
        unlike($errors, qr/Cannot put back/, 'the rollback puts back the file that the second copy wrote partway');
        ok(!-e "$dest/merged", 'the rollback removes the file and the directory that the import created');
        is(read_binary($archive), $published, 'the rollback goes on and puts back the published image');
    } else {
        like($errors, qr/Cannot put back \Q$target\E: another change replaced it/,
            'the rollback reports the change of another writer between the two copies');
        is(read_binary($target), "written by another writer\n", 'the change of another writer stays');
    }
}

{
    # Two extra trees write one symlink on another file system, so the journal keeps and puts it back by copy.
    my $other = -d '/dev/shm' && -w _ ? tempdir(DIR => '/dev/shm', CLEANUP => 1) : undef;
  SKIP: {
        skip 'no second file system for an extra destination', 4 if !defined($other) || (stat($other))[0] == (stat($fixture))[0];
        my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', sub {
            my ($dest, $bundle) = @_;
            make_path("$bundle/extra/a", "$bundle/extra/b");
            symlink("target-$_", "$bundle/extra/$_/link") or die $! for qw(a b);
        }, extra => [ [ 'a', $other ], [ 'b', $other ] ], nodes => 'undefined-node');
        ok(!$placed, 'an import that writes one symlink on another file system twice fails on a later step');
        unlike($errors, qr/Cannot put back/, 'the rollback puts back the symlink that it keeps on another file system');
        ok(!-e "$other/link" && !-l "$other/link", 'the rollback removes the symlink that the import created');
        is(read_binary($archive), $published, 'the rollback goes on and puts back the published image');
    }
}

{
    # imgimport copies kit postscripts and extra files with cp without -a, as before.
    my $bundled = 946684800;
    make_path("$fixture/install/postscripts");
    write_text("$fixture/install/postscripts/existing-script", "postscript before the import\n");
    chmod(0700, "$fixture/install/postscripts/existing-script") or die $!;
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/plainkit/other_files", "$bundle/extra", "$dest/extra");
        write_text("$bundle/plainkit/other_files/$_", "postscript of the kit\n") for qw(existing-script new-script);
        write_text("$bundle/extra/plain.conf", "imported\n");
        utime($bundled, $bundled, "$bundle/plainkit/other_files/new-script", "$bundle/extra/plain.conf") or die $!;
    }, extra => 'plain.conf', kit => 'plainkit', kitdir => 'DEST/kits/plainkit');
    is($errors, '', 'an import with kit postscripts and an extra file reports no error');
    is(read_binary("$fixture/install/postscripts/existing-script"), "postscript of the kit\n", 'the kit replaces an existing postscript');
    is((stat("$fixture/install/postscripts/existing-script"))[2] & 07777, 0700, 'an existing postscript keeps its mode, as cp writes into it');
    isnt((stat("$fixture/install/postscripts/new-script"))[9], $bundled, 'a new postscript does not take the time of the bundle');
    is(read_binary("$dest/extra/plain.conf"), "imported\n", 'the extra file is copied');
    isnt((stat("$dest/extra/plain.conf"))[9], $bundled, 'the extra file does not take the time of the bundle');
}

for my $nodes (undef, 'undefined-node') {
    # cp writes into an existing kit postscript, so it keeps its ACL, and another hard link sees the change.
    my $script = "$fixture/install/postscripts/linked-script";
    make_path("$fixture/install/postscripts");
    unlink($script, "$fixture/linked-script");
    write_text($script, "postscript before the import\n");
    link($script, "$fixture/linked-script") or die $!;
    my $acl   = system('setfacl', '-m', 'u:nobody:rw,g::r', $script) == 0 ? `getfacl -cp '$script'` : undef;
    my $inode = (stat($script))[1];
    my %inodes;
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/linkkit/other_files", "$bundle/extra/conf", "$dest/extra");
        write_text("$bundle/linkkit/other_files/linked-script", "postscript of the kit\n");
        write_text("$bundle/extra/conf/$_", "imported\n")                    for qw(single.conf linked.conf);
        write_text("$dest/extra/$_",        "extra file before the import\n") for qw(single.conf linked.conf);
        link("$dest/extra/linked.conf", "$dest/linked.conf") or die $!;
        %inodes = map { ($_ => (stat("$dest/extra/$_"))[1]) } qw(single.conf linked.conf);
    }, extra => 'conf', kit => 'linkkit', kitdir => 'DEST/kits/linkkit', (defined $nodes ? (nodes => $nodes) : ()));
    my $label = defined $nodes ? 'after a rollback' : 'after an import';
    if (defined $nodes) {
        ok(!$placed, 'an import over linked files fails on a later step');
        unlike($errors, qr/Cannot put back/, 'the rollback puts back the linked files');
    } else {
        is($errors, '', 'an import over linked files reports no error');
    }
    is((stat($script))[1], $inode, "$label, the existing postscript keeps its inode");
    is(read_binary("$fixture/linked-script"), defined $nodes ? "postscript before the import\n" : "postscript of the kit\n",
        "$label, another link of the existing postscript has its content");
  SKIP: {
        skip 'setfacl cannot set an ACL here', 1 if !defined $acl;
        is(`getfacl -cp '$script'`, $acl, "$label, the existing postscript keeps its ACL");
    }
    is((stat("$dest/extra/single.conf"))[1], $inodes{'single.conf'}, "$label, an existing extra file keeps its inode, as with cp -a");
    is(read_binary("$dest/linked.conf"), "extra file before the import\n",
        "$label, another link of an existing extra file keeps its content, as cp -a replaces the file");
    if (defined $nodes) {
        is((stat("$dest/extra/linked.conf"))[1], $inodes{'linked.conf'}, "$label, an existing extra file with another link comes back");
    } else {
        isnt((stat("$dest/extra/linked.conf"))[1], $inodes{'linked.conf'}, "$label, an existing extra file with another link is a new file");
    }
}

{
    # cp cannot write an existing postscript, as with an immutable file, and the rollback must go on.
    my $script = "$fixture/install/postscripts/locked-script";
    make_path("$fixture/install/postscripts", "$fixture/bin");
    write_text($script, "postscript before the import\n");
    my ($cp) = grep { -x $_ } map { "$_/cp" } split(/:/, $ENV{PATH});
    write_text("$fixture/bin/cp", qq{#!/bin/sh\nfor last; do :; done\n[ "\$last" = "$script" ] && exit 1\nexec $cp "\$@"\n});
    chmod(0755, "$fixture/bin/cp") or die $!;
    local $ENV{PATH} = "$fixture/bin:$ENV{PATH}";
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/lockedkit/other_files");
        write_text("$bundle/lockedkit/other_files/locked-script", "postscript of the kit\n");
    }, kit => 'lockedkit', kitdir => 'DEST/kits/lockedkit');
    ok(!$placed, 'an import fails when cp cannot write an existing postscript');
    unlike($errors, qr/Cannot put back/, 'the rollback needs nothing back from the postscript that cp could not write');
    is(read_binary($script), "postscript before the import\n", 'the postscript that cp could not write keeps its content');
    is(read_binary($archive), $published, 'the rollback goes on and puts back the published image');
}

for my $case ([ 'DEST/extra', undef ], [ 'DEST/extra/etc/conf.d', undef ], [ 'DEST/extra/etc/conf.d', 'undefined-node' ]) {
    # The destination directory of an extra file is missing, and the file goes into it.
    my ($extradest, $nodes) = @$case;
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/extra");
        write_text("$bundle/extra/plain.conf", "imported\n");
    }, extra => 'plain.conf', extradest => $extradest, (defined $nodes ? (nodes => $nodes) : ()));
    (my $dir = $extradest) =~ s/DEST/$dest/;
    my $label = $extradest =~ s/DEST/<image>/r;
    if (!defined $nodes) {
        is($errors, '', "$label: an import into a missing directory reports no error");
        ok(-d $dir, "$label: the missing destination directory is created");
        is(read_binary("$dir/plain.conf"), "imported\n", "$label: the extra file goes into the directory");
    } else {
        ok(!$placed, "$label: an import into a missing directory fails on a later step");
        ok(!-e "$dest/extra", "$label: the rollback removes the directories that the import created");
    }
}

for my $extradest (qw(DEST/extra DEST/extra/sub)) {
    # A file is where the destination directory of an extra file goes.
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/extra");
        write_text("$bundle/extra/plain.conf", "imported\n");
        write_text("$dest/extra", "a file where a directory goes\n");
    }, extra => 'plain.conf', extradest => $extradest);
    my $label = $extradest =~ s/DEST/<image>/r;
    ok(!$placed, "$label: an import fails when a file is where the destination directory goes");
    like($errors, qr/\Q$dest\E\/extra is not a directory/, "$label: the path that is not a directory is reported");
    is(read_binary("$dest/extra"), "a file where a directory goes\n", "$label: the file at that path stays");
}

{
    # A statelite bundle has a rootimgtree and no rootimg, and its import needs the image lock too.
    local $HELD = 1;
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$dest/rootimg/etc", "$bundle/tree/rootimg/etc");
        write_text("$dest/rootimg/etc/hostname", "old\n");
        write_text("$bundle/tree/rootimg/etc/hostname", "new\n");
        system("cd '$bundle/tree' && find rootimg | cpio -H newc -o 2>/dev/null | gzip > '$bundle/rootimgtree.gz'") == 0 or die 'cannot pack the tree';
    }, rootimgtree => 'DEST/rootimgtree.gz', omit => [qw(rootimg kernel ramdisk)]);
    ok(!$placed, 'a statelite import fails while another command holds the image lock');
    like($errors, qr/failed to acquire lock/, 'the held image lock is reported');
    is_deeply([ grep { m{/rootimg\z} } @LOCKED ], ["$dest/rootimg"], 'a statelite import asks for the lock of its image directory');
    is(read_binary("$dest/rootimg/etc/hostname"), "old\n", 'the tree stays as it was while the lock is held');
}

{
    # The litefile lookup of an import quotes its column the way the database needs it, here as for MySQL.
    my @where;
    no warnings 'redefine';
    my $lookup = \&xCAT::Table::getAllAttribsWhere;
    local *xCAT::Table::getAllAttribsWhere = sub {
        my ($table, $where) = @_;
        push @where, $where if $table->{tabname} eq 'litefile';
        return $lookup->(@_);
    };
    local *xCAT::Table::delimitcol = sub { return "`$_[0]`" };
    my ($placed, $errors) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        write_text("$bundle/litefile.csv", qq{"img","/etc/hosts","tmpfs",,\n});
    }, litefile => 'DEST/litefile.csv', provmethod => 'statelite');
    is($errors, '', 'a statelite import with a litefile reports no error');
    is_deeply(\@where, ["`image` = 'ALL'"], 'the litefile lookup quotes the image column like the database');
}

# Runs $code in a child process, and returns whether it finished within $seconds and its exit code.
sub finishes {
    my ($seconds, $code) = @_;
    my $pid = fork() // die "cannot fork: $!";
    if (!$pid) {

        # The child opens its own database handles, and leaves those of the parent to the parent.
        $_->{InactiveDestroy} = 1 foreach grep { $_ } values %{ $::XCAT_DBHS || {} };
        $::XCAT_DBHS = {};
        POSIX::_exit($code->() ? 0 : 1);
    }
    for (1 .. $seconds) {
        return (1, $? >> 8) if waitpid($pid, POSIX::WNOHANG()) == $pid;
        sleep 1;
    }
    kill('KILL', $pid);
    waitpid($pid, 0);
    return (0, undef);
}

for my $nodes (undef, 'undefined-node') {
    # A statelite tree holds a FIFO, which the import must not open.
    my $dest = "$fixture/install/netboot/import-" . ($sequence + 1);
    my ($finished, $exit) = finishes(120, sub {
        my ($placed) = import_image('rootimg.cpio.gz', sub {
            my ($dest, $bundle) = @_;
            make_path("$dest/rootimg/etc", "$bundle/tree/dev");
            write_text("$dest/rootimg/etc/hostname", "old\n");
            system('mkfifo', "$bundle/tree/dev/initctl") == 0 or die 'cannot make the FIFO';
            system("cd '$bundle/tree' && find . | cpio -H newc -o 2>/dev/null | gzip > '$bundle/rootimgtree.gz'") == 0 or die 'cannot pack the tree';
        }, rootimgtree => 'DEST/rootimg/rootimgtree.gz', (defined $nodes ? (nodes => $nodes) : ()));
        return $placed;
    });
    $sequence++;
    my $label = defined $nodes ? 'a statelite import with a FIFO that fails' : 'a statelite import with a FIFO';
    ok($finished, "$label finishes");
    if (!defined $nodes) {
        is($exit, 0, "$label succeeds");
        ok(-p "$dest/rootimg/dev/initctl", 'the FIFO of the tree is extracted');
    } else {
        is($exit, 1, "$label fails on the later step");
        ok(!-e "$dest/rootimg/dev/initctl", 'the rollback removes the FIFO of the tree');
    }
}

{
    # The bundled kit has a postscript that is not executable, and the import fails after it installed the kit.
    make_path("$fixture/install/postscripts");
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$bundle/modekit/other_files");
        write_text("$bundle/modekit/other_files/mode-script", "postscript of the kit\n");
        chmod(0644, "$bundle/modekit/other_files/mode-script") or die $!;
    }, kit => 'modekit', kitdir => 'DEST/kits/modekit', nodes => 'undefined-node');
    ok(!$placed, 'an import with a kit fails on a later step');
    unlike($errors, qr/Cannot put back/, 'the rollback takes the executable postscript of the kit for a change of the import');
    ok(!-e "$dest/kits/modekit", 'the kit goes back to the bundle');
    ok(!-e "$fixture/install/postscripts/mode-script", 'the postscript of the kit goes away');
    is(read_binary($archive), $published, 'the published image comes back after the kit import fails');
}

{
    # The rollback quotes column names the way the database needs them, and binds the values.
    local $ENV{XCATCFG} = 'mysql:dbname=xcatdb;host=localhost';
    is_deeply(xCAT_plugin::imgport::txn_condition('imagename', "it's"), [ '`imagename` = ?', "it's" ], 'MySQL gets backticks and a bound value');
    is_deeply(xCAT_plugin::imgport::txn_value_condition('description', 'Setup '), [ 'CAST(`description` AS BINARY) = ?', 'Setup ' ],
        'MySQL compares a value that the rollback guards as bytes, so case and trailing spaces count');
    local $ENV{XCATCFG} = 'Pg:dbname=xcatdb';
    is_deeply(xCAT_plugin::imgport::txn_condition('comments', undef), ['"comments" IS NULL'], 'PostgreSQL gets double quotes');
    is_deeply(xCAT_plugin::imgport::txn_value_condition('description', 'Setup'), [ '"description" = ?', 'Setup' ],
        'PostgreSQL compares a value exactly already');
}

{
    # The published checksum is a relative symlink, which a failed import puts back.
    my ($placed, $errors, $dest, $archive) = import_image('rootimg.cpio.gz', sub {
        my ($dest, $bundle) = @_;
        make_path("$dest/releases");
        rename("$dest/rootimg.cpio.gz.sha256", "$dest/releases/v1.sha256") or die $!;
        symlink('releases/v1.sha256', "$dest/rootimg.cpio.gz.sha256") or die $!;
    }, nodes => 'undefined-node');
    ok(!$placed, 'an import over a checksum symlink fails on a later step');
    unlike($errors, qr/cannot put back/i, 'the rollback puts back the image with its checksum symlink');
    is(read_binary($archive), $published, 'the published archive comes back');
    is(readlink("$archive.sha256") // 'not a symlink', 'releases/v1.sha256', 'the checksum symlink comes back');
    is(-e "$archive.sha256" ? read_binary("$archive.sha256") : 'missing', sha256_hex($published) . "  rootimg.cpio.gz\n",
        'the checksum symlink lists the published archive');
}

{
    # The image directory has a space, and the first word of its path names another directory, which stays.
    my $spaced = "$fixture/install/netboot/custom images/node";
    make_path("$fixture/install/netboot/custom/keep");
    my ($placed, $errors) = import_image('rootimg.cpio.gz', undef, rootimg => "$spaced/rootimg.cpio.gz");
    is($errors, '', 'an import into an image directory with a space reports no error');
    is(-e "$spaced/rootimg.cpio.gz" ? read_binary("$spaced/rootimg.cpio.gz") : 'missing', $imported,
        'the import publishes the archive in the image directory with a space');
    ok(-d "$fixture/install/netboot/custom/keep", 'the directory that the first word of the image directory names stays');
}

for my $case ([ osimage => 'UPDATE', "NEW.osvers = 'rhels9.6'" ], [ linuximage => 'INSERT', '1' ]) {
    # The database applies a write of the import and then reports an error, as a trigger that fails after the change.
    my ($tabname, $statement, $condition) = @$case;
    my $name = 'import-' . ($sequence + 1);
    my $dbh  = xCAT::Table->new($tabname, -create => 1)->{dbh};
    $dbh->do("CREATE TRIGGER fail_after_$tabname AFTER $statement ON $tabname WHEN NEW.imagename = '$name' AND $condition "
          . "BEGIN SELECT RAISE(FAIL, 'disk I/O error'); END") or die $dbh->errstr;
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', undef, rootimgchecksum => 'no');
    $dbh->do("DROP TRIGGER fail_after_$tabname") or die $dbh->errstr;
    ok(!$placed, "$tabname: an import fails when the database reports an error after it applied the write");
    like($errors, qr/disk I\/O error/, "$tabname: the error of the database is reported");
    is(definition($dest), 'rhels9.5', "$tabname: the rollback puts back the image definition");
    my ($row) = xCAT::Table->new('linuximage')->getAttribs({ imagename => $name }, 'rootimgchecksum');
    ok(!$row, "$tabname: the rollback removes the linuximage row that the import created");
}

for my $tabname (qw(osimage kit)) {
    # Another request writes the values of the import right after the import read the row. The update of the import
    # then selects no row, or its insert finds the key taken, and the row of the other request must stay.
    my ($armed, $raced);
    no warnings 'redefine';
    my $read = \&xCAT::Table::getEntriesWhere;
    local *xCAT::Table::getEntriesWhere = sub {
        my @result = $read->(@_);
        if ($armed && !$raced && $_[0]->{tabname} eq $tabname) {
            $raced = 1;
            xCAT::Table->new($tabname, -create => 1)->setAttribs($tabname eq 'osimage'
                ? ({ imagename => $_[2] }, { osvers => 'rhels9.6', osarch => 'x86_64', profile => 'compute', provmethod => 'netboot' })
                : ({ kitname => 'samekit' }, { description => 'kit of this import' }));
        }
        return @result;
    };
    my $make_files = \&xCAT_plugin::imgport::make_files;
    local *xCAT_plugin::imgport::make_files = sub { my $made = $make_files->(@_); $armed = 1; return $made };
    my ($placed, $errors, $dest) = import_image('rootimg.cpio.gz', undef, kit => 'samekit', nodes => 'undefined-node');
    ok($raced, "$tabname: another request writes the values of the import between the read and the write");
    ok(!$placed, "$tabname: the import fails");
    if ($tabname eq 'osimage') {
        is(definition($dest), 'rhels9.6', 'osimage: the image definition that the other request wrote stays');
    } else {
        my ($row) = xCAT::Table->new('kit')->getAttribs({ kitname => 'samekit' }, 'description');
        is($row && $row->{description}, 'kit of this import', 'kit: the kit row that the other request created stays');
        xCAT::Table->new('kit')->delEntries({ kitname => 'samekit' });
    }
}

for my $nodes (undef, 'undefined-node') {
    # An extra file on another file system has another hard link, which a rollback keeps.
    my $other = -d '/dev/shm' && -w _ ? tempdir(DIR => '/dev/shm', CLEANUP => 1) : undef;
  SKIP: {
        skip 'no second file system for an extra destination', 4 if !defined($other) || (stat($other))[0] == (stat($fixture))[0];
        write_text("$other/linked.conf", "extra file before the import\n");
        link("$other/linked.conf", "$other/linked-elsewhere") or die $!;
        my $inode = (stat("$other/linked.conf"))[1];
        my ($placed, $errors) = import_image('rootimg.cpio.gz', sub {
            my ($dest, $bundle) = @_;
            make_path("$bundle/extra/conf");
            write_text("$bundle/extra/conf/linked.conf", "imported\n");
        }, extra => [ [ 'conf', $other ] ], (defined $nodes ? (nodes => $nodes) : ()));
        my $label = defined $nodes ? 'after a rollback' : 'after an import';
        is($errors =~ /Cannot put back/ ? $errors : '', '', "$label, the import puts back what it changed on another file system");
        opendir(my $dir, $other) or die $!;
        is_deeply([ grep { /^\.imgimport-/x } readdir($dir) ], [], "$label, no directory of the import is left on the other file system");
        closedir($dir);
        if (defined $nodes) {
            is((stat("$other/linked.conf"))[1], $inode, "$label, the extra file gets its own inode back");
            is((stat("$other/linked-elsewhere"))[3], 2, "$label, the other hard link of the extra file stays a link of it");
        } else {
            is(read_binary("$other/linked.conf"), "imported\n", "$label, cp -a replaces the extra file with other hard links");
            is(read_binary("$other/linked-elsewhere"), "extra file before the import\n", "$label, the other hard link keeps its content");
        }
    }
}

done_testing();
