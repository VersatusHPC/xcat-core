#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use Cwd qw(realpath);
use File::Path qw(make_path);
use File::Slurper qw(read_binary write_text);
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use Test::More;
use XCAT::Test::File qw(repo_path);

my $fixture = realpath(tempdir(CLEANUP => 1));
make_path("$fixture/db", "$fixture/run", "$fixture/install");
$ENV{XCATCFG} = "SQLite:$fixture/db";
require xCAT::Table;
require(repo_path('xCAT-server/lib/xcat/plugins/imgport.pm'));
xCAT::Table->new('site', -create => 1)->setAttribs({ key => 'installdir' }, { value => "$fixture/install" });
xCAT::Table->new('osimage', -create => 1)->setAttribs({ imagename => 'image' }, { osvers => 'rhels9.5', provmethod => 'netboot' });

my $parent = $$;
{
    no strict 'refs';
    no warnings qw(redefine once);

    # The DB worker listens in /var/run/xcat, so its socket goes to the fixture.
    my $socket = \&IO::Socket::UNIX::new;
    *IO::Socket::UNIX::new = sub {
        my ($class, %args) = @_;
        $args{$_} =~ s{^/var/run/xcat/}{$fixture/run/} foreach grep { defined $args{$_} } qw(Local Peer);
        return $socket->($class, %args);
    };
    *xCAT::Table::mkpath = sub { };

    # A method dies in the DB worker while the fixture has a file of its name, which the worker removes.
    foreach my $method (qw(commit setAttribsWhere insertEntry getEntriesWhere)) {
        my $call = \&{"xCAT::Table::$method"};
        *{"xCAT::Table::$method"} = sub {
            die "$method failed in the DB worker\n" if $$ != $parent && unlink("$fixture/fail-$method");
            goto &$call;
        };
    }

    # The import locks live in /var/lock/xcat.
    *xCAT::Utils::acquire_lock_imageop = sub { return (0, {}) };
    *xCAT::Utils::acquire_lock         = sub { return {} };
}

my $worker = xCAT::Table::init_dbworker();
END { kill('TERM', $worker) && waitpid($worker, 0) if $worker && $$ == $parent }
ok($worker > 0, 'the DB worker starts');

my $kit    = xCAT::Table->new('kit', -create => 1, -autocommit => 0);
my $column = xCAT::Table::delimitcol('kitname');
$kit->setAttribs({ kitname => 'one' }, { description => 'first' });
is(scalar($kit->commit), 1, 'a commit through the DB worker succeeds');

for my $case ([ commit => sub { $kit->commit } ],
    [ setAttribsWhere => sub { $kit->setAttribsWhere("$column = ?", { description => 'changed' }, 'one') } ],
    [ insertEntry     => sub { $kit->insertEntry({ kitname => 'two' }) } ],
    [ getEntriesWhere => sub { $kit->getEntriesWhere("$column = ?", 'one') } ])
{
    my ($method, $call) = @$case;
    write_text("$fixture/fail-$method", '');
    my @result = eval { $call->() };
    ok(!-e "$fixture/fail-$method", "the DB worker runs $method");
    is($@, "$method failed in the DB worker\n", "$method dies with the exception of the DB worker");
}
is(scalar($kit->commit), 1, 'the DB worker serves the next request');
is_deeply([ map { $_->{description} } @{ $kit->getEntriesWhere("$column = ?", 'one') } ], ['first'],
    'the requests that died change no row');

{
    # The first commit of an import dies in the DB worker, and the import puts back what it changed.
    my $dest   = "$fixture/install/netboot/image";
    my $bundle = "$fixture/bundle";
    make_path($dest, $bundle);
    for my $file (qw(rootimg.cpio.gz kernel initrd-stateless.gz)) {
        write_text("$dest/$file",   "published $file\n");
        write_text("$bundle/$file", "$file from the bundle\n");
    }
    write_text("$fixture/fail-commit", '');
    my @errors;
    my $placed = xCAT_plugin::imgport::place_image({
            rootimg => "$dest/rootimg.cpio.gz",
            kernel  => "$dest/kernel",
            ramdisk => "$dest/initrd-stateless.gz",
            osimage => { imagename => 'image', osvers => 'rhels9.6', osarch => 'x86_64', profile => 'compute', provmethod => 'netboot' },
        },
        $bundle, sub { push @errors, @{ $_[0]{error} || [] } });
    ok(!-e "$fixture/fail-commit", 'the import commits through the DB worker');
    ok(!$placed, 'an import fails when its commit dies in the DB worker');
    like(join("\n", @errors), qr/commit failed in the DB worker/, 'the import reports the exception of the DB worker');
    unlike(join("\n", @errors), qr/cannot put back/i, 'the rollback puts back everything');
    is(read_binary("$dest/$_"), "published $_\n", "the published $_ comes back") for qw(rootimg.cpio.gz kernel initrd-stateless.gz);
    my ($row) = xCAT::Table->new('osimage')->getAttribs({ imagename => 'image' }, 'osvers');
    is($row && $row->{osvers}, 'rhels9.5', 'the image definition comes back');
}

done_testing();
