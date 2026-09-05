#!/usr/bin/env perl
use strict;
use warnings;

use File::Spec;
use FindBin;
use Test::More;

my $repo_root = File::Spec->catdir($FindBin::Bin, '..', '..');

# The specs that build a man page from a pod. Every one of them wraps its build
# dependency in a suse_version conditional.
my @POD_SPECS = qw(
    xCAT-OpenStack-baremetal/xCAT-OpenStack-baremetal.spec
    xCAT-SoftLayer/xCAT-SoftLayer.spec
    xCAT-buildkit/xCAT-buildkit.spec
    xCAT-client/xCAT-client.spec
    xCAT-confluent/xCAT-confluent.spec
    xCAT-test/xCAT-test.spec
    xCAT-vlan/xCAT-vlan.spec
);

#-----------------------------------------------------------------------------

=head3 macro_value

    Descriptions: Return the value of one rpm macro.
    Arguments:
        $name    - the macro name
        $defines - hashref of the macros this evaluation defines
    Returns: the value, or undef when the macro is not defined

=cut

#-----------------------------------------------------------------------------
sub macro_value {
    my ($name, $defines) = @_;
    return $defines->{$name};
}

#-----------------------------------------------------------------------------

=head3 expand

    Descriptions: Expand the rpm macros of one %if expression.
    Arguments:
        $expr    - the expression text
        $defines - hashref of the macros this evaluation defines
    Returns: the expression with every macro replaced by its value

=cut

#-----------------------------------------------------------------------------
sub expand {
    my ($expr, $defines) = @_;

    # %(shell) runs at spec parse time. The environment-variable switches
    # (s390x, pcm, zvm, fsm) are set this way, so run the command.
    $expr =~ s/%\(([^()]*(?:\([^()]*\)[^()]*)*)\)/my $o = qx{$1}; chomp $o; $o/ge;

    # %{?name} is the value or nothing; %{name} and %name are the value or the
    # literal text, which never compares equal to a number.
    $expr =~ s/%\{\?(\w+)\}/defined macro_value($1, $defines) ? macro_value($1, $defines) : ''/ge;
    $expr =~ s/%\{(\w+)\}/defined macro_value($1, $defines) ? macro_value($1, $defines) : 0/ge;
    $expr =~ s/%(\w+)/defined macro_value($1, $defines) ? macro_value($1, $defines) : 0/ge;

    # 0%{?rhel} with rhel=10 gives 010, which perl reads as octal. Drop the
    # leading zeros so the comparison stays decimal.
    $expr =~ s/\b0+(\d)/$1/g;
    return $expr;
}

#-----------------------------------------------------------------------------

=head3 condition_holds

    Descriptions: Say whether rpmbuild keeps the branch of one conditional.
    Arguments:
        $directive - if, ifos or ifnos
        $expr      - the expression text
        $defines   - hashref of the macros this evaluation defines
    Returns: true when the branch is kept

=cut

#-----------------------------------------------------------------------------
sub condition_holds {
    my ($directive, $expr, $defines) = @_;

    return $expr =~ /\blinux\b/  ? 1 : 0 if $directive eq 'ifos';
    return $expr =~ /\blinux\b/  ? 0 : 1 if $directive eq 'ifnos';

    my $value = expand($expr, $defines);
    $value =~ s/^\s+|\s+$//g;
    return 0 if $value eq '';
    die "cannot evaluate spec condition '$expr' -> '$value'"
        unless $value =~ m{^[\s\d()!<>=&|+*/-]+$};
    my $result = eval $value;    ## no critic
    die "cannot evaluate spec condition '$expr' -> '$value': $@" if $@;
    return $result ? 1 : 0;
}

#-----------------------------------------------------------------------------

=head3 spec_tags

    Descriptions: Return the values of one spec preamble tag for one distribution.
                  The walk keeps only the conditional branches rpmbuild keeps, so
                  the answer is what the built package declares, not what the file
                  mentions.
    Arguments:
        $relative_path - the spec file, relative to the repository root
        $defines       - hashref of macros, e.g. { suse_version => 1506 }
        $tag           - the tag name, e.g. BuildRequires
    Returns: the list of tag values

=cut

#-----------------------------------------------------------------------------
sub spec_tags {
    my ($relative_path, $defines, $tag) = @_;

    my $path = File::Spec->catfile($repo_root, split('/', $relative_path));
    open(my $fh, '<', $path) or die "Unable to read $path: $!";

    my %macros = %{$defines};
    my @stack;                 # one entry per open conditional: [taken_now, taken_ever]
    my @values;

    while (my $line = <$fh>) {
        chomp $line;
        last if $line =~ /^%(prep|description)\b/;
        my $live = !grep { !$_->[0] } @stack;

        if ($line =~ /^%(if|ifos|ifnos)\s+(.*)$/) {
            my ($directive, $expr) = ($1, $2);
            my $holds = $live ? condition_holds($directive, $expr, \%macros) : 0;
            push @stack, [$holds, $holds];
            next;
        }
        if ($line =~ /^%else\b/) {
            die "%else with no %if in $relative_path" unless @stack;
            $stack[-1][0] = $stack[-1][1] ? 0 : 1;
            next;
        }
        if ($line =~ /^%endif\b/) {
            pop @stack;
            next;
        }
        next unless $live;

        if ($line =~ /^%(?:define|global)\s+(\w+)\s+(.*)$/) {
            my ($name, $value) = ($1, $2);
            $macros{$name} = expand($value, \%macros);
            next;
        }
        if ($line =~ /^%undefine\s+(\w+)/) {
            delete $macros{$1};
            next;
        }
        if ($line =~ /^\Q$tag\E\s*:\s*(.*)$/) {
            my @tokens = split /\s+/, $1;
            while (@tokens) {
                my $name = shift @tokens;
                shift @tokens, shift @tokens
                    if @tokens >= 2 && $tokens[0] =~ /^(?:[<>=]=?|=)$/;
                push @values, $name if length $name;
            }
        }
    }
    close($fh);
    die "unclosed conditional in $relative_path" if @stack;
    return @values;
}

my %LEAP = (suse_version => 1506);

for my $spec (@POD_SPECS) {
    my @suse = spec_tags($spec, \%LEAP, 'BuildRequires');
    ok(scalar(@suse) > 0, "$spec declares a build dependency on SUSE");
    ok(scalar(grep { $_ eq 'perl' } @suse),
        "$spec build-requires perl on SUSE, which carries pod2man and Pod::Html");

    my @el = spec_tags($spec, { rhel => 10 }, 'BuildRequires');
    ok(scalar(grep { $_ eq 'perl-Pod-Html' } @el),
        "$spec keeps perl-Pod-Html on EL");
}

my $server = 'xCAT-server/xCAT-server.spec';
my @suse_requires = spec_tags($server, \%LEAP, 'Requires');
ok(scalar(grep { $_ eq 'perl-core-DB_File' } @suse_requires),
    "$server requires perl-core-DB_File on SUSE, the name Leap ships DB_File under");
is(scalar(grep { $_ eq 'perl-DB_File' } @suse_requires), 0,
    "$server does not require the EL name perl-DB_File on SUSE");

my @el9_requires = spec_tags($server, { rhel => 9 }, 'Requires');
ok(scalar(grep { $_ eq 'perl-DB_File' } @el9_requires),
    "$server keeps the hard perl-DB_File requirement on EL9");

my @el10_requires = spec_tags($server, { rhel => 10 }, 'Requires');
is(scalar(grep { $_ eq 'perl-DB_File' } @el10_requires), 0,
    "$server keeps perl-DB_File weak on EL10");

done_testing();
