package XCAT::Test::Spec;

# Which packages a spec depends on is decided by its %if conditionals, so a test that greps for a
# package name cannot tell a dependency one family takes from one it does not. This evaluates the
# conditionals for a given macro set and returns the tag values that set actually produces.
#
# It handles only the constructs the xCAT specs use, and dies on anything else. A guess would
# report a dependency set no rpm would build, which is worse than no answer.

use strict;
use warnings;

use Exporter qw(import);

our @EXPORT_OK = qw(spec_tag_values);

#---
# =head3 spec_tag_values
# Descriptions: The values of one spec tag (BuildRequires, Requires, Recommends, ...) under one
#               set of macros, in the order the spec lists them, deduplicated. One value per
#               name: a tag line naming several packages yields one value each.
# Arguments: $text  - the spec
#            $tag   - the tag name, without the colon
#            $macro - hash reference of macro name => value; an absent macro is false
# Returns: the list of values
#---
sub spec_tag_values {
    my ($text, $tag, $macro) = @_;
    my (@value, @stack);
    for my $line (split /\n/, $text) {
        # %ifarch gates the %define ladder at the top of a spec. It carries no dependency, but
        # its %endif has to be paired or the walker loses its place.
        if ($line =~ /^%ifarch\s+(.*)$/) {
            my @arch = split(/\s+/, $1);
            push(@stack, (grep { $_ eq ($macro->{target_cpu} // '') } @arch) ? 1 : 0);
            next;
        }
        # %ifos / %ifnos gate the AIX and Linux halves of the xCAT specs.
        if ($line =~ /^%ifn?os\s+(.*)$/) {
            my @os = split(/\s+/, $1);
            my $match = (grep { $_ eq ($macro->{os} // 'linux') } @os) ? 1 : 0;
            push(@stack, $line =~ /^%ifnos/ ? ($match ? 0 : 1) : $match);
            next;
        }
        if ($line =~ /^%if\s+(.*)$/) { push(@stack, _evaluate($1, $macro)); next }
        if ($line =~ /^%else\b/) {
            die "%else with no %if\n" unless @stack;
            $stack[-1] = $stack[-1] ? 0 : 1;
            next;
        }
        if ($line =~ /^%endif\b/) {
            @stack or die "%endif with no %if\n";
            pop(@stack);
            next;
        }
        # The tag block ends at the first %-section. Nothing after it is a dependency.
        last if $line =~ /^%(prep|build|install|files|changelog)\b/;
        next if grep { !$_ } @stack;
        next unless $line =~ /^\Q$tag\E:\s*(.+?)\s*$/;
        # A rich dependency is one value however many spaces it carries.
        my $rest = $1;
        push(@value, $rest =~ /^\(/ ? $rest : split(/\s+/, $rest));
    }
    die "unbalanced %if in the spec\n" if @stack;
    my %seen;
    return grep { !$seen{$_}++ } @value;
}

# One %if expression. Dies on anything it was not written to read.
sub _evaluate {
    my ($expr, $macro) = @_;
    $expr =~ s/^\s+|\s+$//g;
    if ($expr =~ /^"%\{(\w+)\}"\s*==\s*"([^"]*)"$/) {
        return (($macro->{$1} // '') eq $2) ? 1 : 0;
    }
    my $negate = ($expr =~ s/^!\s*//) ? 1 : 0;
    my $flip = sub { my $v = shift; return $negate ? ($v ? 0 : 1) : $v };
    return $flip->(defined($macro->{$1}) ? 1 : 0) if $expr =~ /^%\{defined\s+(\w+)\}$/;
    # A bare %macro, which the xCAT specs use for their own %define'd flags (%s390x, %notpcm).
    return $flip->(($macro->{$1} // 0) ? 1 : 0) if $expr =~ /^%(\w+)$/;
    return $flip->(($macro->{$1} // 0) >= $2 ? 1 : 0) if $expr =~ /^0%\{\?(\w+)\}\s*>=\s*(\d+)$/;
    if ($expr =~ /^0%\{\?(\w+)\}\s*\|\|\s*0%\{\?(\w+)\}$/) {
        return $flip->(($macro->{$1} || $macro->{$2}) ? 1 : 0);
    }
    if ($expr =~ /^0%\{\?(\w+)\}\s*>=\s*(\d+)\s*\|\|\s*0%\{\?(\w+)\}$/) {
        return $flip->((($macro->{$1} // 0) >= $2 || $macro->{$3}) ? 1 : 0);
    }
    if ($expr =~ /^0%\{\?(\w+)\}\s*\|\|\s*\(0%\{\?(\w+)\}\s*&&\s*0%\{\?\2\}\s*<\s*(\d+)\)$/) {
        my ($a, $b, $limit) = ($1, $2, $3);
        return $flip->(($macro->{$a} || ($macro->{$b} && $macro->{$b} < $limit)) ? 1 : 0);
    }
    if ($expr =~ /^0%\{\?(\w+)\}\s*&&\s*0%\{\?\1\}\s*(<|<=|>|>=)\s*(\d+)$/) {
        my ($name, $op, $limit) = ($1, $2, $3);
        my $v = $macro->{$name} // 0;
        return $flip->(0) unless $v;
        my %cmp = ('<' => sub { $_[0] < $_[1] }, '<=' => sub { $_[0] <= $_[1] },
                   '>' => sub { $_[0] > $_[1] }, '>=' => sub { $_[0] >= $_[1] });
        return $flip->($cmp{$op}->($v, $limit) ? 1 : 0);
    }
    return $flip->(($macro->{$1} // 0) ? 1 : 0) if $expr =~ /^0%\{\?(\w+)\}$/;
    die "cannot evaluate '%if $expr'\n";
}

1;
