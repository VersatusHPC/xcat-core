#!/usr/bin/env perl
# The genesis build root is whatever the spec build-requires, and the spec was written for
# Fedora and EL. Eight of its BuildRequires do not exist on openSUSE Leap or SLE:
#
#   No matching package to install: 'dracut-network' ... 'kernel-core' ... 'vim-minimal'
#   Not all dependencies satisfied
#
# dnf builddep then fails, mock stops, and xcat-dep-build-opensuse15-x86_64 publishes nothing --
# so the leap15.6 cell has no xCAT-genesis-base and cannot install xCAT at all.
#
# This evaluates the spec's own %if conditionals for one macro set and asserts the BuildRequires
# list that set actually produces. A grep for a package name cannot do that: every one of the
# eight names is still in the file, inside a branch SUSE does not take.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use XCAT::Test::File qw(repo_path slurp_repo_file);

my $relative = 'xCAT-genesis-base/xCAT-genesis-base.spec';
plan skip_all => "$relative not found" unless -f repo_path($relative);

#-----------------------------------------------------------------------------------------------
=head3 buildrequires_for

Descriptions:
    The BuildRequires a spec produces for one set of macros. Evaluates only the two constructs
    this spec's BuildRequires block uses: C<%if 0%{?name}> with an optional leading C<!>, and a
    string comparison of C<%{tarch}>. A construct outside that set dies rather than being
    guessed, because a guess reports a package set no rpm would build.
Arguments:
    $text  - the spec
    $macro - hash reference of macro name => value; an absent macro is 0 or empty
Returns:
    A sorted list of package names.
=cut
#-----------------------------------------------------------------------------------------------
sub buildrequires_for {
    my ($text, $macro) = @_;
    my (@want, @stack);
    my $live = sub { !grep { !$_ } @stack };
    for my $line (split /\n/, $text) {
        # %ifarch gates the %define tarch ladder at the top of the spec. It carries no
        # BuildRequires, but its %endif has to be paired or the walker loses its place.
        if ($line =~ /^%ifarch\s+(.*)$/) {
            my @arch = split(/\s+/, $1);
            push(@stack, (grep { $_ eq ($macro->{target_cpu} // '') } @arch) ? 1 : 0);
            next;
        }
        if ($line =~ /^%if\s+(.*)$/) {
            push(@stack, evaluate($1, $macro));
            next;
        }
        if ($line =~ /^%else\b/) {
            die "%else with no %if\n" unless @stack;
            $stack[-1] = $stack[-1] ? 0 : 1;
            next;
        }
        if ($line =~ /^%endif\b/) {
            pop(@stack) // die "%endif with no %if\n";
            next;
        }
        # The BuildRequires block ends at the first %-section. Nothing after it is a build input.
        last if $line =~ /^%(prep|build|install|files|description|package|changelog)\b/;
        push(@want, $1) if $live->() && $line =~ /^BuildRequires:\s*(\S+)\s*$/;
    }
    die "unbalanced %if in the spec\n" if @stack;
    my %seen;
    return sort grep { !$seen{$_}++ } @want;
}

# One %if expression. Dies on anything it was not written to read.
sub evaluate {
    my ($expr, $macro) = @_;
    $expr =~ s/^\s+|\s+$//g;
    if ($expr =~ /^"%\{(\w+)\}"\s*==\s*"([^"]*)"$/) {
        return (($macro->{$1} // '') eq $2) ? 1 : 0;
    }
    # 0%{?a} || (0%{?b} && 0%{?b} < N), %{defined a}, and the plain and negated single-macro forms.
    my $negate = ($expr =~ s/^!\s*//) ? 1 : 0;
    if ($expr =~ /^%\{defined\s+(\w+)\}$/) {
        my $value = defined($macro->{$1}) ? 1 : 0;
        return $negate ? ($value ? 0 : 1) : $value;
    }
    my @terms = $expr =~ /0%\{\?(\w+)\}/g;
    die "cannot evaluate '%if $expr'\n" unless @terms;
    my $value;
    if ($expr =~ /\|\|/) {
        # The only || in this spec is openEuler || (rhel && rhel < 10).
        die "cannot evaluate '%if $expr'\n"
            unless $expr =~ /^0%\{\?(\w+)\}\s*\|\|\s*\(0%\{\?(\w+)\}\s*&&\s*0%\{\?\2\}\s*<\s*(\d+)\)$/;
        my ($a, $b, $limit) = ($1, $2, $3);
        $value = ($macro->{$a} || ($macro->{$b} && $macro->{$b} < $limit)) ? 1 : 0;
    }
    elsif ($expr =~ /^0%\{\?(\w+)\}\s*>=\s*(\d+)$/) {
        $value = (($macro->{$1} // 0) >= $2) ? 1 : 0;
    }
    elsif ($expr =~ /^0%\{\?(\w+)\}$/) {
        $value = ($macro->{$1} ? 1 : 0);
    }
    else { die "cannot evaluate '%if $expr'\n" }
    return $negate ? ($value ? 0 : 1) : $value;
}

my $spec = slurp_repo_file($relative);

# Leap 15.6 and EL 9, both x86_64. suse_version is what rpm defines on Leap and SLE.
my @suse = buildrequires_for($spec, { suse_version => 1500, tarch => 'x86_64', target_cpu => 'x86_64' });
my @el9  = buildrequires_for($spec, { rhel => 9, tarch => 'x86_64', target_cpu => 'x86_64' });

# Control: the evaluator must produce a real list, and the two must differ. Without this a
# function that returns nothing makes every "is not required" assertion below pass.
cmp_ok(scalar(@suse), '>', 30, 'control: the evaluator produces a build-requires list for SUSE');
ok(grep({ $_ eq 'openssl' } @suse), 'control: openssl is required on SUSE as on every release');
ok(grep({ $_ eq 'kernel-core' } @el9),
    'control: the EL branch is unchanged -- EL 9 still requires kernel-core');

# The eight names Leap and SLE do not package. Each is still in the spec, in an EL branch.
my %suse = map { $_ => 1 } @suse;
for my $pkg (qw(dracut-network kernel-core kernel-modules kernel-modules-extra
                nmap-ncat perl-interpreter procps-ng vim-minimal)) {
    ok(!$suse{$pkg}, "SUSE does not build-require $pkg, which Leap and SLE do not package");
}

# What SUSE needs instead. kernel-default carries the modules EL splits into three packages.
for my $pkg (qw(dracut kernel-default ncat perl procps vim-small)) {
    ok($suse{$pkg}, "SUSE build-requires $pkg");
}

done_testing();
