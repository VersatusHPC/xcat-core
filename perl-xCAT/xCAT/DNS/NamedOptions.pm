package xCAT::DNS::NamedOptions;

use strict;
use warnings;

#-------------------------------------------------------------------------------

=head3 dnssec_options

    Descriptions:
        The DNSSEC lines for the options block of a forwarding named.conf.
        xCAT turns DNSSEC validation off for bind 9.16.6 and later.
    Arguments:
        $bind_version: the version that "named -v" reports, for example 9.16.23
    Returns:
        A list of option lines, each with a leading tab and a newline.
        The list is empty for an older or an unknown version.

=cut

#-------------------------------------------------------------------------------
sub dnssec_options {
    my ($bind_version) = @_;

    return () unless defined($bind_version) && $bind_version =~ /^\d+(\.\d+)*$/;
    return () if _version_cmp($bind_version, "9.16.6") < 0;

    my @lines;
    # dnssec-enable was removed in bind 9.18
    push @lines, "\tdnssec-enable no;\n" if _version_cmp($bind_version, "9.18.0") < 0;
    push @lines, "\tdnssec-validation no;\n";
    return @lines;
}

sub _version_cmp {
    my ($a, $b) = @_;
    my @a = split(/\./, $a);
    my @b = split(/\./, $b);
    while (@a || @b) {
        my $cmp = (shift(@a) // 0) <=> (shift(@b) // 0);
        return $cmp if $cmp;
    }
    return 0;
}

1;
