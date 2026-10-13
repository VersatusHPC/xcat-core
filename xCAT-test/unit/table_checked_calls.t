#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../perl-xCAT";
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;

my $fixture = tempdir(CLEANUP => 1);
make_path("$fixture/db");
$ENV{XCATCFG} = "SQLite:$fixture/db";
require xCAT::Table;

my $kit = xCAT::Table->new('kit', -create => 1, -autocommit => 0);
$kit->setAttribs({ kitname => $_->[0] }, { version => $_->[1], description => $_->[2] })
  for ([ 'one', '1', 'first' ], [ 'two', undef, 'second' ], [ 'three', '3', 'third' ]);
$kit->commit;

sub column { return xCAT::Table::delimitcol($_[0]) }

sub kits {
    return join(',', sort map { $_->{kitname} } @{ xCAT::Table->new('kit')->getAllEntries('all') });
}

my ($deleted, $error) = $kit->delEntriesWhere(column('version') . ' IS NULL');
$kit->commit;
is($deleted, 1, 'a where clause that tests for NULL deletes the row that it selects');
is($error, undef, 'the delete reports no error');
is(kits(), 'one,three', 'the rows that the where clause does not select stay');

($deleted, $error) = $kit->delEntriesWhere(column('kitname') . " = 'one' AND " . column('version') . " = '2'");
$kit->commit;
is($deleted, 0, 'a where clause that selects nothing deletes nothing');
is(kits(), 'one,three', 'all rows stay when the where clause selects nothing');

($deleted, $error) = $kit->delEntriesWhere(column('nosuchcolumn') . " = 'x'");
$kit->rollback;
ok(!defined($deleted), 'an invalid where clause deletes nothing');
like($error // '', qr/nosuchcolumn/, 'an invalid where clause returns the error of the database');

# A bound value needs no quoting, also with a quote and a backslash.
my $odd = q{it's \' OR 1=1 -- };
$kit->setAttribs({ kitname => $odd }, { version => '4' });
$kit->commit;
($deleted, $error) = $kit->delEntriesWhere(column('kitname') . ' = ?', $odd);
$kit->commit;
is($deleted, 1, 'a bound value with a quote and a backslash selects only its row');
is(kits(), 'one,three', 'the other rows stay when the value is bound');

# The DB worker of xcatd runs the requests that the table objects of other processes send it.
my %request = (tablename => 'kit', autocommit => 0);
xCAT::Table::handle_dbc_request({ %request, function => 'new', args => [ 'xCAT::Table', 'kit', -create => 1, -autocommit => 0 ] });
($deleted) = xCAT::Table::handle_dbc_request({ %request, function => 'delEntriesWhere', args => [ column('kitname') . " = 'three'" ] });
xCAT::Table::handle_dbc_request({ %request, function => 'commit', args => [] });
is($deleted, 1, 'the DB worker deletes the rows that a where clause selects');
is(kits(), 'one', 'the DB worker leaves the other rows');

{
    my $tab = xCAT::Table->new('kit', -create => 1, -autocommit => 0);
    $tab->setAttribs({ kitname => $_->[0] }, { description => $_->[1], version => $_->[2], disable => $_->[3] })
      for ([ 'five', 'fifth', undef, undef ], [ 'six', 'sixth', '6', '1' ]);
    $tab->commit;
    my ($rows, $error) = $tab->getEntriesWhere(column('version') . ' IS NULL');
    is_deeply([ map { $_->{kitname} } @{ $rows || [] } ], ['five'], 'getEntriesWhere returns the rows that a where clause selects, also with a NULL test');
    is($error, undef, 'a read that succeeds reports no error');
    ($rows) = $tab->getEntriesWhere(column('kitname') . ' = ?', 'six');
    is($rows && $rows->[0]{version}, '6', 'getEntriesWhere binds the values of its where clause');
    ($rows) = $tab->getEntriesWhere(column('kitname') . " = 'six'");
    is($rows && $rows->[0]{disable}, '1', 'getEntriesWhere returns a disabled row too');
    ($rows) = $tab->getEntriesWhere();
    is(join(',', sort map { $_->{kitname} } @{ $rows || [] }), 'five,one,six', 'getEntriesWhere without a where clause returns all rows');
    ($rows, $error) = $tab->getEntriesWhere(column('nosuchcolumn') . " = 'x'");
    ok(!defined($rows), 'a read that fails returns no rows, not an empty list');
    like($error // '', qr/nosuchcolumn/, 'a read that fails returns the error of the database');
    ($rows) = xCAT::Table::handle_dbc_request({ %request, function => 'getEntriesWhere', args => [ column('kitname') . " = 'five'" ] });
    is($rows && $rows->[0]{kitname}, 'five', 'the DB worker runs getEntriesWhere');
}

done_testing();
