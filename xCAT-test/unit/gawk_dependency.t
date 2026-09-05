#!/usr/bin/env perl
use strict;
use warnings;

use File::Find ();
use File::Spec;
use FindBin;
use Test::More;

# Regression: xCAT ships awk programs that open a TCP or UDP socket with the gawk network
# coprocess ("/inet/tcp/0/host/port" read with |&). mawk implements neither, and mawk is the
# default /usr/bin/awk on Debian and Ubuntu. A stock ubuntu:24.04 has no gawk at all, so every
# one of these programs dies at parse time with "unexpected character '&'", exit code 2.
#
# The Debian packages that ship them declared no dependency on gawk, so apt never installed the
# interpreter they need. updateflag.awk is the call site that already broke: the post-install
# "next" token never reached xcatd and diskful Ubuntu nodes booted the installer again.
#
# The scan below is deliberately dynamic. It finds the gawk-only programs by reading them, maps
# each one to the source component that ships it, and requires gawk in that component's
# debian/control. A script that moves to another package moves the assertion with it.

my $repo_root = File::Spec->rel2abs(
    File::Spec->catdir( $FindBin::Bin, '..', '..' )
);

sub read_file {
    my ($filename) = @_;
    open( my $fh, '<', $filename ) or die "Unable to read $filename: $!";
    my $content = do { local $/; <$fh> };
    close($fh);
    return $content;
}

#-------------------------------------------------------------------------------

=head3 gawk_only_constructs

    Descriptions: Name the gawk extensions a program uses. mawk has none of them.
    Arguments: the text of an awk program
    Returns: a list of construct names, empty when the program is portable

=cut

#-------------------------------------------------------------------------------
sub gawk_only_constructs {
    my ($text) = @_;
    my @found;
    push @found, 'network coprocess ("/inet/...")' if $text =~ m{"/inet/};
    push @found, 'two-way pipe (|&)'               if $text =~ m{\|&};
    return @found;
}

# Collect every awk program in the tree that needs gawk.
my @scripts;
File::Find::find(
    {
        no_chdir => 1,
        wanted   => sub {
            my $path = $File::Find::name;
            if ( -d $path && $path =~ m{/\.git$} ) {
                $File::Find::prune = 1;
                return;
            }
            return unless -f $path;

            my $text = eval { read_file($path) };
            return unless defined $text;

            my ($shebang) = $text =~ /\A(#!.*)/;
            return unless defined $shebang && $shebang =~ m{\bawk\b};

            my @constructs = gawk_only_constructs($text);
            return unless @constructs;

            my $relative = File::Spec->abs2rel( $path, $repo_root );
            push @scripts, { path => $relative, constructs => \@constructs };
        },
    },
    $repo_root
);

BAIL_OUT('Found no awk program using a gawk extension - the scan matches nothing')
    unless @scripts;

# Group the programs by the source component that ships them.
my %by_component;
foreach my $script (@scripts) {
    my ($component) = split m{/}, $script->{path};
    push @{ $by_component{$component} }, $script;
}

#-------------------------------------------------------------------------------

=head3 binary_stanzas

    Descriptions: Split a debian/control file into its binary package stanzas.
    Arguments: the text of a debian/control file
    Returns: a list of [package name, Depends value] pairs

=cut

#-------------------------------------------------------------------------------
sub binary_stanzas {
    my ($control) = @_;
    my @stanzas;
    foreach my $stanza ( split /\n\s*\n/, $control ) {

        # Unfold the continuation lines so a wrapped Depends reads as one field.
        ( my $flat = $stanza ) =~ s/\n[ \t]+/ /g;

        my ($name) = $flat =~ /^Package:\s*(\S+)/m;
        next unless defined $name;

        my ($depends) = $flat =~ /^Depends:\s*(.*)$/m;
        push @stanzas, [ $name, $depends ];
    }
    return @stanzas;
}

#-------------------------------------------------------------------------------

=head3 depends_on_gawk

    Descriptions: Report whether a Depends field names gawk, alone or as an alternative.
    Arguments: the value of a Depends field
    Returns: 1 when gawk is present, 0 otherwise

=cut

#-------------------------------------------------------------------------------
sub depends_on_gawk {
    my ($depends) = @_;
    return 0 unless defined $depends;

    foreach my $relation ( split /,/, $depends ) {
        foreach my $alternative ( split /\|/, $relation ) {
            $alternative =~ s/\[[^\]]*\]//g;      # architecture qualifier
            $alternative =~ s/\([^)]*\)//g;       # version relation
            $alternative =~ s/^\s+|\s+$//g;
            return 1 if $alternative eq 'gawk';
        }
    }
    return 0;
}

foreach my $component ( sort keys %by_component ) {
    my @paths = map { $_->{path} } @{ $by_component{$component} };

    my @controls = sort glob( File::Spec->catfile( $repo_root, $component, 'debian', 'control*' ) );

    BAIL_OUT("$component ships @paths but has no debian/control to carry the dependency")
        unless @controls;

    foreach my $control_file (@controls) {
        my $control = read_file($control_file);
        my @stanzas = binary_stanzas($control);

        BAIL_OUT("No binary package stanza in $control_file")
            unless @stanzas;

        foreach my $stanza (@stanzas) {
            my ( $name, $depends ) = @$stanza;
            ok( depends_on_gawk($depends),
                "$name Depends on gawk, the interpreter for " . join( ', ', @paths ) );
        }
    }
}

# Name what was measured, so a scan that stops matching is visible in the output.
foreach my $script ( sort { $a->{path} cmp $b->{path} } @scripts ) {
    note( sprintf( '%s uses %s', $script->{path}, join( ' and ', @{ $script->{constructs} } ) ) );
}

done_testing();
