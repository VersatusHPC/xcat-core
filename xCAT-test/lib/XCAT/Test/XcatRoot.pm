package XCAT::Test::XcatRoot;

use strict;
use warnings;

use Exporter ();
use File::Path qw(make_path);
use File::Spec;
use File::Temp ();
use XCAT::Test::File qw(repo_path);

our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(xcatroot);

# Every xCAT module runs "use lib $::XCATROOT/lib/perl" while it compiles, and $::XCATROOT is
# $ENV{XCATROOT} or /opt/xcat. The first xCAT module a test loads therefore puts the installed
# product in front of the checkout in @INC, and every module loaded after it comes from
# /opt/xcat. Tests that read $ENV{XCATROOT}/share/... read the installed file for the same
# reason. Both make the test measure the installed product instead of the tree it lives in.
#
# xcatroot() builds a scratch directory with the installed layout, filled with symlinks into
# the checkout, and the import below points XCATROOT at it. The rule above then resolves to
# the tree.

# The installed path, then the checkout paths that supply it, in precedence order.
my @LAYOUT = (
    [ 'lib/perl/xCAT'            => 'perl-xCAT/xCAT', 'xCAT-server/lib/perl/xCAT' ],
    [ 'lib/perl/xCAT_plugin'     => 'xCAT-server/lib/xcat/plugins' ],
    [ 'lib/perl/xCAT_schema'     => 'xCAT-server/lib/xcat/schema' ],
    [ 'lib/perl/xCAT_monitoring' => 'xCAT-server/lib/xcat/monitoring' ],
    [ 'lib/perl/Confluent'       => 'xCAT-server/lib/xcat/Confluent' ],
    [ 'share/xcat'               => 'xCAT-server/share/xcat', 'xCAT-client/share/xcat' ],
    [ 'bin'                      => 'xCAT-client/bin' ],
    [ 'sbin'                     => 'xCAT-server/sbin' ],
    [ 'postscripts'              => 'xCAT/postscripts' ],
);

# File::Temp removes the directory when this goes out of scope, so it is held for the life of
# the process.
my $scratch;
my $root;

#-------------------------------------------------------------------------------

=head3 _link

    Descriptions: Links one destination to the checkout paths that supply it.
    Arguments:
        $destination - the path to create under the scratch root
        @sources     - the checkout paths, in precedence order
    Returns: nothing

=cut

#-------------------------------------------------------------------------------
sub _link {
    my ( $destination, @sources ) = @_;

    @sources = grep { -e $_ } @sources;
    return unless @sources;

    # One source, or a file: link it whole. Recursion below is only for the few directories
    # the installed layout merges.
    if ( @sources == 1 || !-d $sources[0] ) {
        symlink( $sources[0], $destination ) or die "Unable to link $destination: $!";
        return;
    }

    mkdir($destination) or die "Unable to create $destination: $!";

    my ( @order, %supplied_by );
    foreach my $source (@sources) {
        opendir( my $dh, $source ) or die "Unable to read $source: $!";
        foreach my $entry ( readdir($dh) ) {
            next if $entry eq File::Spec->curdir() || $entry eq File::Spec->updir();
            push @order, $entry unless $supplied_by{$entry};
            push @{ $supplied_by{$entry} }, File::Spec->catfile( $source, $entry );
        }
        closedir($dh);
    }

    foreach my $entry (@order) {
        _link( File::Spec->catfile( $destination, $entry ), @{ $supplied_by{$entry} } );
    }

    return;
}

#-------------------------------------------------------------------------------

=head3 xcatroot

    Descriptions: Returns a scratch XCATROOT that resolves to this checkout.
    Arguments: none
    Returns: the path of the scratch root

=cut

#-------------------------------------------------------------------------------
sub xcatroot {
    return $root if defined $root;

    $scratch = File::Temp->newdir( 'xcat-test-root-XXXXXXXX', TMPDIR => 1 );
    $root    = "$scratch";

    foreach my $entry (@LAYOUT) {
        my ( $relative, @sources ) = @$entry;
        my $destination = File::Spec->catdir( $root, $relative );
        my $parent      = ( File::Spec->splitpath($destination) )[1];
        make_path($parent);
        _link( $destination, map { repo_path($_) } @sources );
    }

    return $root;
}

#-------------------------------------------------------------------------------

=head3 import

    Descriptions: Points XCATROOT at the scratch root, then exports as usual.
    Arguments: the import list
    Returns: nothing

=cut

#-------------------------------------------------------------------------------
sub import {
    my $class = shift;

    $ENV{XCATROOT} = xcatroot();
    $class->export_to_level( 1, $class, @_ );

    return;
}

1;

__END__

=head1 NAME

XCAT::Test::XcatRoot - point XCATROOT at the checkout a test lives in

=head1 SYNOPSIS

    use FindBin;
    use lib "$FindBin::Bin/../lib";
    use XCAT::Test::XcatRoot;    # before the first xCAT module

=head1 DESCRIPTION

Loading this module sets C<$ENV{XCATROOT}> to a scratch directory that holds the installed
xCAT layout, built from symlinks into the checkout. Load it before the first xCAT module, or
that module puts the installed product ahead of the checkout in C<@INC>.

The scratch directory is removed when the process ends. Its entries are symlinks, so a write
through them reaches the checkout; use it for reading only.

=cut
