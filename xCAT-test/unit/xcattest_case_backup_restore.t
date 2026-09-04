#!/usr/bin/env perl
# A case file is the artifact: xcattest runs its "cmd:" lines verbatim on the management node,
# in order, and every case shares one /etc. A case that restores a file from a backup path it
# never wrote reads whatever an earlier, unrelated case left there.
use strict;
use warnings;

use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use XCAT::Test::File qw(repo_path);

my $casedir = repo_path('xCAT-test/autotest/testcase');
plan skip_all => 'xcattest case tree not found' unless -d $casedir;

my @files;
find(sub { push @files, $File::Find::name if -f && !m{^\.} }, $casedir);
@files = sort @files;
plan tests => 3;

cmp_ok(scalar @files, '>', 50, 'the case tree was read');

#-------------------------------------------------------------------------------

=head3 is_backup_path

Descriptions: Reports whether a path names a backup copy of another file.

Arguments: $path - one word from a case command.

Returns: 1 when the extension carries bak, orig, save or backup; 0 otherwise.

=cut

#-------------------------------------------------------------------------------
sub is_backup_path {
    my ($path) = @_;
    my ($base) = $path =~ m{([^/]+)$};
    return 0 unless defined $base && $base =~ /\./;
    my $extension = $base;
    $extension =~ s/^[^.]*//;
    return $extension =~ /(?:bak|orig|save|backup)/i ? 1 : 0;
}

#-------------------------------------------------------------------------------

=head3 classify_command

Descriptions: Reads one simple shell command and reports the paths it copies from
and the paths it writes.

Arguments: $command - one simple command, already split on ; | && ||.

Returns: Two array references: the source paths and the written paths.

=cut

#-------------------------------------------------------------------------------
sub classify_command {
    my ($command) = @_;
    my (@sources, @written);
    my @words = grep { length } split /\s+/, $command;

    for my $i (0 .. $#words) {
        push @written, $words[ $i + 1 ] if $words[$i] =~ /^>>?$/  && $i < $#words;
        push @written, $1               if $words[$i] =~ /^>>?(\S+)$/;
    }

    my $verb_index;
    for my $i (0 .. $#words) {
        next unless $words[$i] =~ m{^(?:\S*/)?(cp|mv|install|rsync|tee|touch)$};
        $verb_index = $i;
        last;
    }
    return (\@sources, \@written) unless defined $verb_index;

    my $verb = $words[$verb_index];
    $verb =~ s{.*/}{};
    my @arguments;
    for my $word (@words[ $verb_index + 1 .. $#words ]) {
        last if $word =~ /^(?:then|else|fi|done|&)$/;
        next if $word =~ /^[-<>]/;
        push @arguments, $word;
    }

    if ($verb eq 'tee' || $verb eq 'touch') {
        push @written, @arguments;
    } elsif (@arguments >= 2) {
        push @written, $arguments[-1];
        push @sources, @arguments[ 0 .. $#arguments - 1 ];
    }
    return (\@sources, \@written);
}

#-------------------------------------------------------------------------------

=head3 read_cases

Descriptions: Splits one case file into cases and returns each case's command blocks
in the order xcattest runs them.

Arguments: $file - path of a case file.

Returns: A list of [ name, [ command blocks ] ] pairs.

=cut

#-------------------------------------------------------------------------------
sub read_cases {
    my ($file) = @_;
    open(my $fh, '<', $file) or return ();
    my (@cases, @blocks, $name, $block);
    while (my $line = <$fh>) {
        chomp $line;
        if ($line =~ /^start:\s*(\S+)/) {
            ($name, @blocks, $block) = ($1);
            next;
        }
        next unless defined $name;
        if ($line =~ /^end\s*$/) {
            push @blocks, $block if defined $block;
            push @cases, [ $name, [@blocks] ];
            ($name, $block) = (undef, undef);
            next;
        }
        if ($line =~ /^cmd:(.*)$/) {
            push @blocks, $block if defined $block;
            $block = $1;
            next;
        }
        if ($line =~ /^[a-z]+:/) {
            push @blocks, $block if defined $block;
            $block = undef;
            next;
        }
        $block .= "\n$line" if defined $block;
    }
    close($fh);
    return @cases;
}

#-------------------------------------------------------------------------------

=head3 orphan_restores

Descriptions: Finds every command in one case that copies from a backup path the same
case has not written. A command that first tests the path with [ -f ], [ -e ] or [ -d ]
is left out: it does nothing when the path is absent.

Arguments: $blocks - the case command blocks, in order.

Returns: An array reference of "path :: command" strings.

=cut

#-------------------------------------------------------------------------------
sub orphan_restores {
    my ($blocks) = @_;
    my (%written, @orphans);
    for my $raw (@$blocks) {
        my $text = $raw;
        $text =~ s/["'`]/ /g;
        for my $command (split /(?:\|\||&&|[;|\n])/, $text) {
            next unless $command =~ /\S/;
            my ($sources, $written) = classify_command($command);
            for my $path (@$sources) {
                next unless is_backup_path($path);
                next if $written{$path};
                next if $raw =~ /\[+\s*-[fed]\s+\Q$path\E/;
                push @orphans, "$path :: $command";
            }
            $written{$_} = 1 for @$written;
        }
    }
    return \@orphans;
}

my @findings;
for my $file (@files) {
    for my $case (read_cases($file)) {
        my ($name, $blocks) = @$case;
        my $relative = $file;
        $relative =~ s{^\Q$casedir\E/}{};
        push @findings, "$relative :: $name :: $_" for @{ orphan_restores($blocks) };
    }
}

is_deeply(\@findings, [], 'no case restores a file from a backup path it never wrote')
    or diag("orphan restores:\n" . join("\n", @findings));

# The analyzer must still see the shape it exists to find.
my $planted = orphan_restores([ 'cp -f /etc/hosts.bak /etc/hosts' ]);
is(scalar @$planted, 1, 'a blind restore from a foreign backup is reported');
