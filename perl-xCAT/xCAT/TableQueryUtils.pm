#!/usr/bin/env perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT::TableQueryUtils;

use strict;
use warnings;

#---
# =head3 unknown_keys
# Descriptions: The keys of a table query that are not columns of the table. A key that is not
#               a column becomes an SQL error in xCAT::Table, and the caller gets a Perl error
#               instead of a message that names the key.
# Arguments: $cols -- array ref of the table columns, $keys -- hash ref of key => value
# Returns: the unknown keys, sorted
# =cut
#---
sub unknown_keys
{
    my ($cols, $keys) = @_;
    my %known = map { $_ => 1 } @{ $cols || [] };
    return sort grep { !$known{$_} } keys %{ $keys || {} };
}

#---
# =head3 unknown_keys_error
# Descriptions: The error text for a query that names keys the table does not have.
# Arguments: $table -- the table name, @keys -- the unknown keys
# Returns: the message, or undef when @keys is empty
# =cut
#---
sub unknown_keys_error
{
    my ($table, @keys) = @_;
    return undef unless @keys;
    my $noun = @keys == 1 ? 'attribute' : 'attributes';
    return "Table $table has no $noun " . join(', ', @keys) . '.';
}

#---
# =head3 attribs_reply
# Descriptions: The reply of the getAttribs xcatd command. Other clients read the one-row form,
#               so the reply keeps it unless the request asks for every matching row. The
#               every-row form is the one getTablesAllRowAttribs uses.
# Arguments: $table -- the table name, $rows -- array ref of row hashes, $allmatches -- boolean
# Returns: the reply hash
# =cut
#---
sub attribs_reply
{
    my ($table, $rows, $allmatches) = @_;
    my @rows = grep { defined } @{ $rows || [] };
    my %rsp;
    if ($allmatches) {
        return \%rsp unless @rows;
        my @out = map { my %r = %$_; \%r } @rows;
        $rsp{table} = [ { tablename => [$table], row => \@out } ];
        return \%rsp;
    }
    if (@rows) {
        foreach my $k (keys %{ $rows[0] }) {
            push @{ $rsp{$k} }, $rows[0]->{$k};
        }
    }
    return \%rsp;
}

1;
